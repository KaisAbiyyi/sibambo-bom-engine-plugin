use std::collections::HashSet;
use std::env;
use std::ffi::{c_char, c_int, c_ulong, c_void, CString, OsStr};
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::Instant;

const PROTOCOL_VERSION: u16 = 1;
const FRAME_MAGIC: &[u8; 4] = b"SCW1";
const INPUT_MAGIC: &[u8; 4] = b"SCIP";
const OUTPUT_MAGIC: &[u8; 4] = b"SCOP";
const ENDIAN_MARKER: u16 = 0x4c45;

const MSG_REQUEST: u16 = 1;
const MSG_CANCEL: u16 = 2;
const MSG_SHUTDOWN: u16 = 3;
const MSG_CRASH_TEST: u16 = 4;
const MSG_READY: u16 = 100;
const MSG_PROGRESS: u16 = 101;
const MSG_RESULT: u16 = 102;
const MSG_ERROR: u16 = 103;
const MSG_CANCELLED: u16 = 104;

const STAGE_READ: u16 = 1;
const STAGE_NUMERIC: u16 = 2;
const STAGE_SECTIONS: u16 = 3;
const STAGE_PUBLISH: u16 = 4;

#[derive(Debug)]
struct Frame {
    message_type: u16,
    job_id: u64,
    payload: Vec<u8>,
}

enum Command {
    Request(Frame),
    ProtocolError(u64, String),
    Shutdown,
    Crash,
}

#[derive(Clone)]
struct Request {
    job_id: u64,
    engine: u8,
    profile: u8,
    operation: u8,
    input_path: PathBuf,
    output_path: PathBuf,
}

#[derive(Clone)]
struct Section {
    kind: u16,
    raw: Vec<u8>,
}

struct InputPayload {
    numeric_values: Vec<f64>,
    sections: Vec<Section>,
    input_bytes: u64,
}

struct ProcessResult {
    elapsed_ns: u64,
    input_bytes: u64,
    output_bytes: u64,
    semantic_sha: [u8; 32],
}

type CompressBound = unsafe extern "C" fn(c_ulong) -> c_ulong;
type Compress2 = unsafe extern "C" fn(*mut u8, *mut c_ulong, *const u8, c_ulong, c_int) -> c_int;
type Uncompress = unsafe extern "C" fn(*mut u8, *mut c_ulong, *const u8, c_ulong) -> c_int;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(path: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    fn FreeLibrary(module: *mut c_void) -> i32;
}

#[link(name = "bcrypt")]
unsafe extern "system" {
    fn BCryptOpenAlgorithmProvider(algorithm: *mut *mut c_void, algorithm_id: *const u16, implementation: *const u16, flags: u32) -> i32;
    fn BCryptGetProperty(object: *mut c_void, property: *const u16, output: *mut u8, output_bytes: u32, written: *mut u32, flags: u32) -> i32;
    fn BCryptCreateHash(algorithm: *mut c_void, hash: *mut *mut c_void, hash_object: *mut u8, hash_object_bytes: u32, secret: *mut u8, secret_bytes: u32, flags: u32) -> i32;
    fn BCryptHashData(hash: *mut c_void, input: *mut u8, input_bytes: u32, flags: u32) -> i32;
    fn BCryptFinishHash(hash: *mut c_void, output: *mut u8, output_bytes: u32, flags: u32) -> i32;
    fn BCryptDestroyHash(hash: *mut c_void) -> i32;
    fn BCryptCloseAlgorithmProvider(algorithm: *mut c_void, flags: u32) -> i32;
}

struct Zlib {
    module: *mut c_void,
    compress_bound: CompressBound,
    compress2: Compress2,
    uncompress: Uncompress,
}

unsafe impl Send for Zlib {}

impl Zlib {
    fn load() -> Result<Self, String> {
        let dll = env::var_os("SIBAMBO_ZLIB_DLL").unwrap_or_else(|| OsStr::new("zlib1.dll").to_os_string());
        let mut wide: Vec<u16> = dll.encode_wide().collect();
        wide.push(0);
        let module = unsafe { LoadLibraryW(wide.as_ptr()) };
        if module.is_null() {
            return Err(format!("cannot load zlib DLL {:?}; set SIBAMBO_ZLIB_DLL", dll));
        }
        unsafe fn proc<T>(module: *mut c_void, name: &str) -> Result<T, String> {
            let c_name = CString::new(name).map_err(|_| "invalid zlib symbol".to_string())?;
            let ptr = unsafe { GetProcAddress(module, c_name.as_ptr()) };
            if ptr.is_null() {
                return Err(format!("zlib symbol {name} is missing"));
            }
            Ok(unsafe { std::mem::transmute_copy::<*mut c_void, T>(&ptr) })
        }
        let result = unsafe {
            Ok(Self {
                module,
                compress_bound: proc(module, "compressBound")?,
                compress2: proc(module, "compress2")?,
                uncompress: proc(module, "uncompress")?,
            })
        };
        if result.is_err() {
            unsafe { FreeLibrary(module) };
        }
        result
    }

    fn compress(&self, raw: &[u8], level: i32) -> Result<Vec<u8>, String> {
        if raw.len() > c_ulong::MAX as usize {
            return Err("section exceeds zlib uLong limit".into());
        }
        let bound = unsafe { (self.compress_bound)(raw.len() as c_ulong) } as usize;
        let mut stored = vec![0u8; bound];
        let mut stored_len = bound as c_ulong;
        let rc = unsafe {
            (self.compress2)(stored.as_mut_ptr(), &mut stored_len, raw.as_ptr(), raw.len() as c_ulong, level)
        };
        if rc != 0 {
            return Err(format!("zlib compress2 failed with code {rc}"));
        }
        stored.truncate(stored_len as usize);
        Ok(stored)
    }

    fn inflate(&self, stored: &[u8], expected: usize) -> Result<Vec<u8>, String> {
        if stored.len() > c_ulong::MAX as usize || expected > c_ulong::MAX as usize {
            return Err("section exceeds zlib uLong limit".into());
        }
        let mut raw = vec![0u8; expected];
        let mut raw_len = expected as c_ulong;
        let rc = unsafe {
            (self.uncompress)(raw.as_mut_ptr(), &mut raw_len, stored.as_ptr(), stored.len() as c_ulong)
        };
        if rc != 0 {
            return Err(format!("zlib uncompress failed with code {rc}"));
        }
        if raw_len as usize != expected {
            return Err(format!("zlib readback length {} != {expected}", raw_len));
        }
        Ok(raw)
    }
}

impl Drop for Zlib {
    fn drop(&mut self) {
        unsafe { FreeLibrary(self.module) };
    }
}

struct Sha256Provider {
    algorithm: *mut c_void,
    object_bytes: u32,
}

unsafe impl Send for Sha256Provider {}

impl Sha256Provider {
    fn new() -> Result<Self, String> {
        let algorithm_id = wide("SHA256");
        let mut algorithm = std::ptr::null_mut();
        let status = unsafe { BCryptOpenAlgorithmProvider(&mut algorithm, algorithm_id.as_ptr(), std::ptr::null(), 0) };
        if status < 0 || algorithm.is_null() { return Err(format!("BCryptOpenAlgorithmProvider failed: 0x{:08x}", status as u32)); }
        let property = wide("ObjectLength");
        let mut object_bytes = 0u32;
        let mut written = 0u32;
        let status = unsafe {
            BCryptGetProperty(
                algorithm,
                property.as_ptr(),
                (&mut object_bytes as *mut u32).cast::<u8>(),
                std::mem::size_of::<u32>() as u32,
                &mut written,
                0,
            )
        };
        if status < 0 || written != 4 || object_bytes == 0 {
            unsafe { BCryptCloseAlgorithmProvider(algorithm, 0); }
            return Err(format!("BCrypt ObjectLength failed: 0x{:08x}", status as u32));
        }
        Ok(Self { algorithm, object_bytes })
    }

    fn hash(&self, data: &[u8]) -> Result<[u8; 32], String> {
        if data.len() > u32::MAX as usize { return Err("SHA input exceeds BCrypt single-call limit".into()); }
        let mut object = vec![0u8; self.object_bytes as usize];
        let mut handle = std::ptr::null_mut();
        let status = unsafe {
            BCryptCreateHash(
                self.algorithm,
                &mut handle,
                object.as_mut_ptr(),
                self.object_bytes,
                std::ptr::null_mut(),
                0,
                0,
            )
        };
        if status < 0 || handle.is_null() { return Err(format!("BCryptCreateHash failed: 0x{:08x}", status as u32)); }
        let result = (|| {
            let status = unsafe { BCryptHashData(handle, data.as_ptr() as *mut u8, data.len() as u32, 0) };
            if status < 0 { return Err(format!("BCryptHashData failed: 0x{:08x}", status as u32)); }
            let mut output = [0u8; 32];
            let status = unsafe { BCryptFinishHash(handle, output.as_mut_ptr(), output.len() as u32, 0) };
            if status < 0 { return Err(format!("BCryptFinishHash failed: 0x{:08x}", status as u32)); }
            Ok(output)
        })();
        unsafe { BCryptDestroyHash(handle); }
        result
    }
}

impl Drop for Sha256Provider {
    fn drop(&mut self) {
        unsafe { BCryptCloseAlgorithmProvider(self.algorithm, 0); }
    }
}

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(std::iter::once(0)).collect()
}

fn main() {
    if let Err(error) = run() {
        let _ = writeln!(io::stderr(), "{error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let zlib = Zlib::load()?;
    let sha256 = Sha256Provider::new()?;
    let cancelled = Arc::new(Mutex::new(HashSet::<u64>::new()));
    let (tx, rx) = mpsc::channel::<Command>();
    let reader_cancelled = Arc::clone(&cancelled);
    thread::spawn(move || {
        let mut input = BufReader::new(io::stdin());
        loop {
            match read_frame(&mut input) {
                Ok(Some(frame)) => match frame.message_type {
                    MSG_REQUEST => {
                        if tx.send(Command::Request(frame)).is_err() { break; }
                    }
                    MSG_CANCEL => {
                        if let Ok(mut set) = reader_cancelled.lock() { set.insert(frame.job_id); }
                    }
                    MSG_SHUTDOWN => { let _ = tx.send(Command::Shutdown); break; }
                    MSG_CRASH_TEST => { let _ = tx.send(Command::Crash); break; }
                    other => { let _ = tx.send(Command::ProtocolError(frame.job_id, format!("unsupported message type {other}"))); }
                },
                Ok(None) => { let _ = tx.send(Command::Shutdown); break; }
                Err((job_id, message)) => {
                    let _ = tx.send(Command::ProtocolError(job_id, message));
                }
            }
        }
    });

    let stdout = io::stdout();
    let mut output = BufWriter::new(stdout.lock());
    write_frame(&mut output, MSG_READY, 0, &[]).map_err(|e| e.to_string())?;

    while let Ok(command) = rx.recv() {
        match command {
            Command::Shutdown => break,
            Command::Crash => std::process::exit(97),
            Command::ProtocolError(job_id, message) => {
                write_frame(&mut output, MSG_ERROR, job_id, message.as_bytes()).map_err(|e| e.to_string())?;
            }
            Command::Request(frame) => {
                let job_id = frame.job_id;
                match parse_request(frame) {
                    Ok(request) => match process_request(&request, &zlib, &sha256, &cancelled, &mut output) {
                        Ok(Some(result)) => {
                            let mut payload = Vec::with_capacity(56);
                            push_u64(&mut payload, result.elapsed_ns);
                            push_u64(&mut payload, result.input_bytes);
                            push_u64(&mut payload, result.output_bytes);
                            payload.extend_from_slice(&result.semantic_sha);
                            write_frame(&mut output, MSG_RESULT, job_id, &payload).map_err(|e| e.to_string())?;
                        }
                        Ok(None) => {
                            write_frame(&mut output, MSG_CANCELLED, job_id, &[]).map_err(|e| e.to_string())?;
                        }
                        Err(message) => {
                            let _ = fs::remove_file(format!("{}.part", request.output_path.display()));
                            write_frame(&mut output, MSG_ERROR, job_id, message.as_bytes()).map_err(|e| e.to_string())?;
                        }
                    },
                    Err(message) => {
                        write_frame(&mut output, MSG_ERROR, job_id, message.as_bytes()).map_err(|e| e.to_string())?;
                    }
                }
                if let Ok(mut set) = cancelled.lock() { set.remove(&job_id); }
            }
        }
    }
    Ok(())
}

fn parse_request(frame: Frame) -> Result<Request, String> {
    let bytes = frame.payload;
    if bytes.len() < 8 { return Err("request payload is truncated".into()); }
    let engine = bytes[0];
    let profile = bytes[1];
    let operation = bytes[2];
    if engine != 4 { return Err(format!("unsupported engine code {engine}")); }
    if !(1..=3).contains(&profile) { return Err(format!("unsupported profile code {profile}")); }
    if operation != 1 { return Err(format!("unsupported operation code {operation}")); }
    let input_len = u16::from_le_bytes([bytes[4], bytes[5]]) as usize;
    let output_len = u16::from_le_bytes([bytes[6], bytes[7]]) as usize;
    if bytes.len() != 8 + input_len + output_len { return Err("request path lengths do not match payload".into()); }
    let input = std::str::from_utf8(&bytes[8..8 + input_len]).map_err(|_| "input path is not UTF-8")?;
    let output = std::str::from_utf8(&bytes[8 + input_len..]).map_err(|_| "output path is not UTF-8")?;
    Ok(Request { job_id: frame.job_id, engine, profile, operation, input_path: PathBuf::from(input), output_path: PathBuf::from(output) })
}

fn process_request(
    request: &Request,
    zlib: &Zlib,
    sha256: &Sha256Provider,
    cancelled: &Arc<Mutex<HashSet<u64>>>,
    output: &mut BufWriter<impl Write>,
) -> Result<Option<ProcessResult>, String> {
    let started = Instant::now();
    if request.engine != 4 || request.operation != 1 || !(1..=3).contains(&request.profile) {
        return Err("request contract changed after validation".into());
    }
    progress(output, request.job_id, STAGE_READ, 0, 1)?;
    let payload = read_payload(&request.input_path, request.job_id)?;
    progress(output, request.job_id, STAGE_READ, 1, 1)?;
    if is_cancelled(cancelled, request.job_id) { return Ok(None); }

    progress(output, request.job_id, STAGE_NUMERIC, 0, 1)?;
    let mut numeric_bytes = Vec::with_capacity(payload.numeric_values.len() * 4);
    for value in &payload.numeric_values { numeric_bytes.extend_from_slice(&(*value as f32).to_le_bytes()); }
    progress(output, request.job_id, STAGE_NUMERIC, 1, 1)?;
    if is_cancelled(cancelled, request.job_id) { return Ok(None); }

    let mut semantic_input = Vec::with_capacity(numeric_bytes.len() + payload.sections.len() * 38);
    semantic_input.extend_from_slice(&numeric_bytes);
    let mut encoded_sections: Vec<(u16, Vec<u8>, u32, [u8; 32], usize)> = Vec::with_capacity(payload.sections.len());
    let total = payload.sections.len() as u32;
    for (index, section) in payload.sections.iter().enumerate() {
        if is_cancelled(cancelled, request.job_id) { return Ok(None); }
        let crc = crc32(&section.raw);
        let raw_sha = sha256.hash(&section.raw)?;
        let stored = zlib.compress(&section.raw, 6)?;
        let readback = zlib.inflate(&stored, section.raw.len())?;
        if readback != section.raw || crc32(&readback) != crc || sha256.hash(&readback)? != raw_sha {
            return Err(format!("section {} failed internal readback integrity", section.kind));
        }
        semantic_input.extend_from_slice(&section.kind.to_le_bytes());
        semantic_input.extend_from_slice(&raw_sha);
        semantic_input.extend_from_slice(&crc.to_le_bytes());
        encoded_sections.push((section.kind, stored, crc, raw_sha, section.raw.len()));
        progress(output, request.job_id, STAGE_SECTIONS, (index + 1) as u32, total)?;
    }
    let semantic_sha = sha256.hash(&semantic_input)?;
    if is_cancelled(cancelled, request.job_id) { return Ok(None); }

    progress(output, request.job_id, STAGE_PUBLISH, 0, 1)?;
    let output_bytes = write_output_atomic(&request.output_path, request.job_id, &numeric_bytes, &encoded_sections, &semantic_sha)?;
    progress(output, request.job_id, STAGE_PUBLISH, 1, 1)?;
    Ok(Some(ProcessResult {
        elapsed_ns: started.elapsed().as_nanos().min(u64::MAX as u128) as u64,
        input_bytes: payload.input_bytes,
        output_bytes,
        semantic_sha,
    }))
}

fn progress(output: &mut BufWriter<impl Write>, job_id: u64, stage: u16, completed: u32, total: u32) -> Result<(), String> {
    let mut payload = Vec::with_capacity(10);
    push_u16(&mut payload, stage);
    push_u32(&mut payload, completed);
    push_u32(&mut payload, total);
    write_frame(output, MSG_PROGRESS, job_id, &payload).map_err(|e| e.to_string())
}

fn is_cancelled(cancelled: &Arc<Mutex<HashSet<u64>>>, job_id: u64) -> bool {
    cancelled.lock().map(|set| set.contains(&job_id)).unwrap_or(true)
}

fn read_payload(path: &Path, expected_job: u64) -> Result<InputPayload, String> {
    let input_bytes = fs::metadata(path).map_err(|e| format!("cannot stat input payload: {e}"))?.len();
    let file = File::open(path).map_err(|e| format!("cannot open input payload: {e}"))?;
    let mut input = BufReader::new(file);
    let mut magic = [0u8; 4];
    input.read_exact(&mut magic).map_err(|e| format!("input header: {e}"))?;
    if &magic != INPUT_MAGIC { return Err("input payload magic mismatch".into()); }
    let version = read_u16(&mut input)?;
    if version != PROTOCOL_VERSION { return Err(format!("input payload version {version} is unsupported")); }
    let endian = read_u16(&mut input)?;
    if endian != ENDIAN_MARKER { return Err("input payload endian marker mismatch".into()); }
    let job_id = read_u64(&mut input)?;
    if job_id != expected_job { return Err(format!("input payload job {job_id} != request {expected_job}")); }
    let numeric_count = read_u32(&mut input)? as usize;
    let section_count = read_u32(&mut input)? as usize;
    if numeric_count > 32_000_000 || section_count > 65_536 { return Err("input payload count exceeds spike budget".into()); }
    let mut numeric_values = Vec::with_capacity(numeric_count);
    for _ in 0..numeric_count {
        let mut bytes = [0u8; 8];
        input.read_exact(&mut bytes).map_err(|e| format!("numeric payload: {e}"))?;
        let value = f64::from_le_bytes(bytes);
        if !value.is_finite() { return Err("numeric payload contains non-finite value".into()); }
        numeric_values.push(value);
    }
    let mut sections = Vec::with_capacity(section_count);
    for _ in 0..section_count {
        let kind = read_u16(&mut input)?;
        let flags = read_u16(&mut input)?;
        if flags != 0 { return Err(format!("section {kind} uses unsupported flags {flags}")); }
        let len = read_u64(&mut input)? as usize;
        if len > 512 * 1024 * 1024 { return Err("section exceeds 512 MiB spike budget".into()); }
        let mut raw = vec![0u8; len];
        input.read_exact(&mut raw).map_err(|e| format!("section {kind}: {e}"))?;
        sections.push(Section { kind, raw });
    }
    let mut trailing = [0u8; 1];
    if input.read(&mut trailing).map_err(|e| e.to_string())? != 0 { return Err("input payload has trailing bytes".into()); }
    Ok(InputPayload { numeric_values, sections, input_bytes })
}

fn write_output_atomic(
    path: &Path,
    job_id: u64,
    numeric_bytes: &[u8],
    sections: &[(u16, Vec<u8>, u32, [u8; 32], usize)],
    semantic_sha: &[u8; 32],
) -> Result<u64, String> {
    if let Some(parent) = path.parent() { fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
    let part = PathBuf::from(format!("{}.part", path.display()));
    let result = (|| {
        let file = File::create(&part).map_err(|e| format!("cannot create output part: {e}"))?;
        let mut out = BufWriter::new(file);
        out.write_all(OUTPUT_MAGIC).map_err(|e| e.to_string())?;
        write_u16(&mut out, PROTOCOL_VERSION)?;
        write_u16(&mut out, ENDIAN_MARKER)?;
        write_u64(&mut out, job_id)?;
        write_u32(&mut out, (numeric_bytes.len() / 4) as u32)?;
        write_u32(&mut out, sections.len() as u32)?;
        out.write_all(semantic_sha).map_err(|e| e.to_string())?;
        write_u64(&mut out, numeric_bytes.len() as u64)?;
        out.write_all(numeric_bytes).map_err(|e| e.to_string())?;
        for (kind, stored, crc, raw_sha, raw_len) in sections {
            write_u16(&mut out, *kind)?;
            write_u16(&mut out, 1)?;
            write_u64(&mut out, *raw_len as u64)?;
            write_u64(&mut out, stored.len() as u64)?;
            write_u32(&mut out, *crc)?;
            out.write_all(raw_sha).map_err(|e| e.to_string())?;
            out.write_all(stored).map_err(|e| e.to_string())?;
        }
        out.flush().map_err(|e| e.to_string())?;
        out.get_ref().sync_all().map_err(|e| e.to_string())?;
        drop(out);
        if path.exists() { fs::remove_file(path).map_err(|e| e.to_string())?; }
        fs::rename(&part, path).map_err(|e| format!("cannot publish output: {e}"))?;
        fs::metadata(path).map(|m| m.len()).map_err(|e| e.to_string())
    })();
    if result.is_err() { let _ = fs::remove_file(&part); }
    result
}

fn read_frame(input: &mut impl Read) -> Result<Option<Frame>, (u64, String)> {
    let mut magic = [0u8; 4];
    match input.read_exact(&mut magic) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err((0, error.to_string())),
    }
    let version = read_u16_io(input).map_err(|e| (0, e.to_string()))?;
    let message_type = read_u16_io(input).map_err(|e| (0, e.to_string()))?;
    let job_id = read_u64_io(input).map_err(|e| (0, e.to_string()))?;
    let length = read_u32_io(input).map_err(|e| (job_id, e.to_string()))? as usize;
    let expected_crc = read_u32_io(input).map_err(|e| (job_id, e.to_string()))?;
    if &magic != FRAME_MAGIC { return Err((job_id, "control frame magic mismatch".into())); }
    if version != PROTOCOL_VERSION { return Err((job_id, format!("control protocol version {version} is unsupported"))); }
    if length > 1_048_576 { return Err((job_id, "control frame payload exceeds 1 MiB".into())); }
    let mut payload = vec![0u8; length];
    input.read_exact(&mut payload).map_err(|e| (job_id, e.to_string()))?;
    if crc32(&payload) != expected_crc { return Err((job_id, "control frame CRC mismatch".into())); }
    Ok(Some(Frame { message_type, job_id, payload }))
}

fn write_frame(output: &mut impl Write, message_type: u16, job_id: u64, payload: &[u8]) -> io::Result<()> {
    output.write_all(FRAME_MAGIC)?;
    output.write_all(&PROTOCOL_VERSION.to_le_bytes())?;
    output.write_all(&message_type.to_le_bytes())?;
    output.write_all(&job_id.to_le_bytes())?;
    output.write_all(&(payload.len() as u32).to_le_bytes())?;
    output.write_all(&crc32(payload).to_le_bytes())?;
    output.write_all(payload)?;
    output.flush()
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for byte in bytes {
        crc ^= *byte as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320u32 & mask);
        }
    }
    !crc
}

fn push_u16(out: &mut Vec<u8>, value: u16) { out.extend_from_slice(&value.to_le_bytes()); }
fn push_u32(out: &mut Vec<u8>, value: u32) { out.extend_from_slice(&value.to_le_bytes()); }
fn push_u64(out: &mut Vec<u8>, value: u64) { out.extend_from_slice(&value.to_le_bytes()); }

fn read_u16(input: &mut impl Read) -> Result<u16, String> { read_u16_io(input).map_err(|e| e.to_string()) }
fn read_u32(input: &mut impl Read) -> Result<u32, String> { read_u32_io(input).map_err(|e| e.to_string()) }
fn read_u64(input: &mut impl Read) -> Result<u64, String> { read_u64_io(input).map_err(|e| e.to_string()) }
fn read_u16_io(input: &mut impl Read) -> io::Result<u16> { let mut b=[0;2]; input.read_exact(&mut b)?; Ok(u16::from_le_bytes(b)) }
fn read_u32_io(input: &mut impl Read) -> io::Result<u32> { let mut b=[0;4]; input.read_exact(&mut b)?; Ok(u32::from_le_bytes(b)) }
fn read_u64_io(input: &mut impl Read) -> io::Result<u64> { let mut b=[0;8]; input.read_exact(&mut b)?; Ok(u64::from_le_bytes(b)) }
fn write_u16(output: &mut impl Write, value: u16) -> Result<(), String> { output.write_all(&value.to_le_bytes()).map_err(|e| e.to_string()) }
fn write_u32(output: &mut impl Write, value: u32) -> Result<(), String> { output.write_all(&value.to_le_bytes()).map_err(|e| e.to_string()) }
fn write_u64(output: &mut impl Write, value: u64) -> Result<(), String> { output.write_all(&value.to_le_bytes()).map_err(|e| e.to_string()) }

