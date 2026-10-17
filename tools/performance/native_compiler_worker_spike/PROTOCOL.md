# Sibambo Native Compiler Worker Spike Protocol v1

This protocol exists only for `EVOLUTION-CONVERSION-PERFORMANCE-001` Step 6 evidence. It is not a shipped E4 interface unless the Step 6 adoption gate explicitly promotes it.

## Ownership and transport

- Control messages use stdin/stdout binary frames. The worker never writes diagnostics to stdout outside this protocol; stderr is diagnostic-only.
- Large detached-Capture-IR data uses an owned temporary input file and an owned temporary output file so the spike measures a realistic file/mmap-style boundary without JSON/base64 copies.
- All integers and floating-point values are little-endian. UTF-8 is used only for file paths and error text.
- The parent owns worker lifecycle and temporary files. The worker owns only its process-local buffers and the `.part` output while a request is active.
- The worker never accesses SketchUp or any live host object.

## Control frame

Every control frame is:

| Field | Type |
| --- | --- |
| magic | 4 bytes, `SCW1` |
| protocol version | `u16`, currently `1` |
| message type | `u16` |
| job id | `u64` |
| payload bytes | `u32` |
| payload CRC-32 | `u32` |
| payload | byte string |

Message types: `1 REQUEST`, `2 CANCEL`, `3 SHUTDOWN`, `4 CRASH_TEST`, `100 READY`, `101 PROGRESS`, `102 RESULT`, `103 ERROR`, `104 CANCELLED`.

`REQUEST` payload is `engine:u8, profile:u8, operation:u8, reserved:u8, inputPathBytes:u16, outputPathBytes:u16, inputPath:utf8, outputPath:utf8`. Step 6 operation `1` is the representative BOMC pure-compile subset. Engine code `4` is E4. Profiles are `1 visual`, `2 research`, `3 exact`.

`CANCEL` is generation/job-specific. A dedicated stdin reader thread receives it while compilation is running; the compilation loop polls the job cancellation set between bounded numeric/section phases. Cancelled work deletes its `.part` output and emits `CANCELLED`.

`PROGRESS` payload is `stage:u16, completed:u32, total:u32`. Stage codes are `1 read`, `2 numeric-pack`, `3 section-compress/readback`, `4 publish`.

`RESULT` payload is `workerElapsedNs:u64, inputBytes:u64, outputBytes:u64, semanticSha256:32 bytes`.

`ERROR` payload is UTF-8. The parent treats process exit without a terminal frame as a crash and owns cleanup/reaping.

## Detached payload file v1

Input header: magic `SCIP`, version `u16=1`, endian marker `u16=0x4c45`, `jobId:u64`, `numericCount:u32`, `sectionCount:u32`.

It is followed by `numericCount` Float64 values and then `sectionCount` records: `type:u16, flags:u16, rawBytes:u64, raw payload`. The Step 6 worker packs numeric values to Float32 LE, computes SHA-256 and CRC-32 for every raw section, compresses each section with zlib level 6, immediately inflates it again, and rejects any byte/CRC/SHA mismatch.

Output header: magic `SCOP`, version/endian/job id, numeric count, section count, semantic SHA-256, packed-numeric byte length, packed Float32 bytes. Each section then stores `type:u16, codec:u16(=1 zlib), rawBytes:u64, storedBytes:u64, crc32:u32, rawSha256:32 bytes, compressed bytes`.

The semantic SHA-256 binds the packed numeric bytes plus each section's type, raw SHA-256 and CRC-32. It is intentionally independent of zlib implementation byte-for-byte output so Ruby and worker semantic equality can be proven even if their zlib builds choose different valid DEFLATE streams.

## Version/corruption behavior

- Unknown protocol versions produce `ERROR`; they are never guessed or downgraded.
- Frame CRC mismatch, payload magic/version/endian mismatch, malformed lengths, unsupported engine/profile/operation and readback mismatch produce `ERROR` and no published output.
- Output is written to `<output>.part` and renamed only after internal readback/integrity succeeds.
- `CRASH_TEST` is deliberately available only in this spike executable so ownership/crash cleanup can be tested. It exits immediately with code `97` and is not a production protocol feature.

