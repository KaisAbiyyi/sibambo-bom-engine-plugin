# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'time'
require 'zlib'

module SibamboNativeCompilerWorkerSpike
  PROTOCOL_VERSION = 1
  FRAME_MAGIC = 'SCW1'.b.freeze
  INPUT_MAGIC = 'SCIP'.b.freeze
  OUTPUT_MAGIC = 'SCOP'.b.freeze
  ENDIAN_MARKER = 0x4c45

  MSG_REQUEST = 1
  MSG_CANCEL = 2
  MSG_SHUTDOWN = 3
  MSG_CRASH_TEST = 4
  MSG_READY = 100
  MSG_PROGRESS = 101
  MSG_RESULT = 102
  MSG_ERROR = 103
  MSG_CANCELLED = 104

  module_function

  def root
    File.expand_path('../..', __dir__)
  end

  def worker_root
    File.join(__dir__, 'native_compiler_worker_spike')
  end

  def worker_executable
    File.join(worker_root, 'target', 'release', 'sibambo-native-compiler-worker-spike.exe')
  end

  def cargo_path
    candidates = [
      ENV['SIBAMBO_CARGO'],
      'C:/Users/kaisa/.cargo/bin/cargo.exe',
      'C:/Users/Administrator/.cargo/bin/cargo.exe'
    ].compact
    candidates.find { |path| File.file?(path) } || 'cargo'
  end

  def zlib_path
    candidates = [
      ENV['SIBAMBO_ZLIB_DLL'],
      'C:/Ruby32-x64/bin/ruby_builtin_dlls/zlib1.dll',
      'C:/Ruby32-x64/msys64/ucrt64/bin/zlib1.dll',
      'C:/Program Files/Git/mingw64/bin/zlib1.dll'
    ].compact
    candidates.find { |path| File.file?(path) }
  end

  def build_worker!
    cargo = cargo_path
    stdout, stderr, status = Open3.capture3(cargo, 'build', '--release', chdir: worker_root)
    raise "native worker build failed:\n#{stdout}\n#{stderr}" unless status.success? && File.file?(worker_executable)
    worker_executable
  end

  def write_payload(path, job_id:, numbers:, sections:)
    File.open(path, 'wb') do |file|
      file.write(INPUT_MAGIC)
      file.write([PROTOCOL_VERSION, ENDIAN_MARKER].pack('v2'))
      file.write([Integer(job_id)].pack('Q<'))
      file.write([numbers.length, sections.length].pack('V2'))
      file.write(numbers.pack('E*'))
      sections.each_with_index do |section, index|
        kind = Integer(section[:type] || index + 1)
        flags = Integer(section[:flags] || 0)
        raw = section.fetch(:bytes).b
        file.write([kind, flags, raw.bytesize].pack('v2Q<'))
        file.write(raw)
      end
    end
    File.size(path)
  end

  def ruby_compile(numbers:, sections:)
    started = monotonic
    numeric = numbers.pack('e*')
    semantic = Digest::SHA256.new
    semantic.update(numeric)
    stored_bytes = numeric.bytesize
    sections.each_with_index do |section, index|
      kind = Integer(section[:type] || index + 1)
      raw = section.fetch(:bytes).b
      crc = Zlib.crc32(raw)
      raw_sha = Digest::SHA256.digest(raw)
      stored = Zlib::Deflate.deflate(raw, 6)
      readback = Zlib::Inflate.inflate(stored)
      raise "Ruby readback mismatch for section #{kind}" unless readback == raw && Zlib.crc32(readback) == crc && Digest::SHA256.digest(readback) == raw_sha
      semantic.update([kind].pack('v'))
      semantic.update(raw_sha)
      semantic.update([crc].pack('V'))
      stored_bytes += stored.bytesize
    end
    {
      elapsed_ms: (monotonic - started) * 1000.0,
      semantic_sha256: semantic.hexdigest,
      output_payload_bytes: stored_bytes
    }
  end

  def read_output(path)
    File.open(path, 'rb') do |file|
      raise 'native output magic mismatch' unless file.read(4) == OUTPUT_MAGIC
      version, endian = file.read(4).unpack('v2')
      raise "native output version #{version}" unless version == PROTOCOL_VERSION
      raise 'native output endian mismatch' unless endian == ENDIAN_MARKER
      job_id = file.read(8).unpack1('Q<')
      numeric_count, section_count = file.read(8).unpack('V2')
      semantic_sha = file.read(32).unpack1('H*')
      numeric_bytes = file.read(8).unpack1('Q<')
      numeric = file.read(numeric_bytes)
      raise 'native numeric byte length mismatch' unless numeric && numeric.bytesize == numeric_count * 4
      sections = section_count.times.map do
        kind, codec = file.read(4).unpack('v2')
        raw_bytes, stored_bytes = file.read(16).unpack('Q<2')
        crc = file.read(4).unpack1('V')
        raw_sha = file.read(32).unpack1('H*')
        stored = file.read(stored_bytes)
        raise "native section #{kind} codec #{codec}" unless codec == 1
        raw = Zlib::Inflate.inflate(stored)
        raise "native section #{kind} length mismatch" unless raw.bytesize == raw_bytes
        raise "native section #{kind} CRC mismatch" unless Zlib.crc32(raw) == crc
        raise "native section #{kind} SHA mismatch" unless Digest::SHA256.hexdigest(raw) == raw_sha
        { type: kind, raw_bytes: raw_bytes, stored_bytes: stored_bytes, crc32: crc, sha256: raw_sha }
      end
      raise 'native output has trailing bytes' unless file.read(1).nil?
      { job_id: job_id, numeric_count: numeric_count, semantic_sha256: semantic_sha, numeric: numeric, sections: sections }
    end
  end

  class WorkerClient
    attr_reader :pid, :startup_ms

    def initialize(executable: SibamboNativeCompilerWorkerSpike.worker_executable, zlib: SibamboNativeCompilerWorkerSpike.zlib_path)
      raise 'zlib1.dll not found for native worker spike' unless zlib && File.file?(zlib)
      started = SibamboNativeCompilerWorkerSpike.monotonic
      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3({ 'SIBAMBO_ZLIB_DLL' => zlib }, executable)
      @stdin.binmode
      @stdout.binmode
      @pid = @wait_thread.pid
      ready = read_frame
      raise "native worker did not become ready: #{ready.inspect}" unless ready[:type] == MSG_READY
      @startup_ms = (SibamboNativeCompilerWorkerSpike.monotonic - started) * 1000.0
      @closed = false
    end

    def request(job_id:, input_path:, output_path:, profile: 1)
      input = input_path.to_s.encode(Encoding::UTF_8)
      output = output_path.to_s.encode(Encoding::UTF_8)
      raise 'native worker path exceeds u16 protocol limit' if input.bytesize > 65_535 || output.bytesize > 65_535
      payload = [4, profile, 1, 0, input.bytesize, output.bytesize].pack('C4v2') + input + output
      write_frame(MSG_REQUEST, job_id, payload)
      progress = []
      started = SibamboNativeCompilerWorkerSpike.monotonic
      loop do
        frame = read_frame
        raise 'native worker exited before a terminal response' unless frame
        next unless frame[:job_id] == job_id
        case frame[:type]
        when MSG_PROGRESS
          stage, completed, total = frame[:payload].unpack('vV2')
          row = { stage: stage, completed: completed, total: total }
          progress << row
          yield(row) if block_given?
        when MSG_RESULT
          worker_ns, input_bytes, output_bytes = frame[:payload].byteslice(0, 24).unpack('Q<3')
          semantic = frame[:payload].byteslice(24, 32).unpack1('H*')
          return {
            status: :success,
            roundtrip_ms: (SibamboNativeCompilerWorkerSpike.monotonic - started) * 1000.0,
            worker_ms: worker_ns / 1_000_000.0,
            input_bytes: input_bytes,
            output_bytes: output_bytes,
            semantic_sha256: semantic,
            progress: progress
          }
        when MSG_CANCELLED
          return { status: :cancelled, roundtrip_ms: (SibamboNativeCompilerWorkerSpike.monotonic - started) * 1000.0, progress: progress }
        when MSG_ERROR
          return { status: :error, error: frame[:payload].force_encoding(Encoding::UTF_8), roundtrip_ms: (SibamboNativeCompilerWorkerSpike.monotonic - started) * 1000.0, progress: progress }
        end
      end
    end

    def cancel(job_id)
      write_frame(MSG_CANCEL, job_id, ''.b)
    end

    def send_raw(message_type:, job_id:, payload: ''.b, version: PROTOCOL_VERSION)
      write_frame(message_type, job_id, payload, version: version)
    end

    def next_frame
      read_frame
    end

    def crash_for_test
      write_frame(MSG_CRASH_TEST, 0, ''.b)
      @stdin.close unless @stdin.closed?
      status = @wait_thread.value
      @closed = true
      status
    ensure
      close_streams
    end

    def shutdown
      return if @closed
      write_frame(MSG_SHUTDOWN, 0, ''.b) rescue nil
      @stdin.close unless @stdin.closed?
      @wait_thread.join(5)
      unless @wait_thread.stop?
        Process.kill('KILL', @pid) rescue nil
        @wait_thread.join(5)
      end
      @closed = true
      @wait_thread.value
    ensure
      close_streams
    end

    def alive?
      @wait_thread&.alive? == true
    end

    private

    def write_frame(type, job_id, payload, version: PROTOCOL_VERSION)
      bytes = payload.b
      @stdin.write(FRAME_MAGIC)
      @stdin.write([version, type, Integer(job_id), bytes.bytesize, Zlib.crc32(bytes)].pack('v2Q<V2'))
      @stdin.write(bytes)
      @stdin.flush
    end

    def read_frame
      magic = @stdout.read(4)
      return nil if magic.nil? || magic.empty?
      raise "native worker frame magic mismatch #{magic.inspect}" unless magic == FRAME_MAGIC
      header = @stdout.read(20)
      raise 'native worker frame header truncated' unless header && header.bytesize == 20
      version, type, job_id, length, crc = header.unpack('v2Q<V2')
      raise "native worker response version #{version}" unless version == PROTOCOL_VERSION
      payload = @stdout.read(length)
      raise 'native worker frame payload truncated' unless payload && payload.bytesize == length
      raise 'native worker frame CRC mismatch' unless Zlib.crc32(payload) == crc
      { type: type, job_id: job_id, payload: payload }
    end

    def close_streams
      [@stdin, @stdout, @stderr].compact.each { |io| io.close unless io.closed? rescue nil }
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def median(values)
    sorted = values.map(&:to_f).sort
    middle = sorted.length / 2
    sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def fixture_sections(path, section_count:, section_bytes:)
    source = File.binread(path)
    section_count.times.map do |index|
      repeated = String.new(capacity: section_bytes, encoding: Encoding::BINARY)
      repeated << source while repeated.bytesize < section_bytes
      repeated = repeated.byteslice(0, section_bytes)
      { type: index + 1, flags: 0, bytes: repeated }
    end
  end

  def fixture_numbers(count)
    Array.new(count) { |index| ((index % 10_000) - 5_000) / 113.0 }
  end

  def benchmark(options)
    build_worker!
    zlib = zlib_path
    raise 'zlib1.dll not found' unless zlib
    numbers = fixture_numbers(options.fetch(:numeric_count))
    sections = fixture_sections(options.fetch(:fixture), section_count: options.fetch(:section_count), section_bytes: options.fetch(:section_bytes))
    ruby_rows = Array.new(options.fetch(:repetitions)) { ruby_compile(numbers: numbers, sections: sections) }
    expected_sha = ruby_rows.first.fetch(:semantic_sha256)
    raise 'Ruby semantic digest is nondeterministic' unless ruby_rows.all? { |row| row[:semantic_sha256] == expected_sha }

    cold_rows = []
    warm_rows = []
    Dir.mktmpdir('sibambo-native-worker-step6') do |dir|
      options.fetch(:repetitions).times do |index|
        job_id = 10_000 + index
        input_path = File.join(dir, "cold-#{index}.input")
        output_path = File.join(dir, "cold-#{index}.output")
        total_started = monotonic
        serialize_started = monotonic
        write_payload(input_path, job_id: job_id, numbers: numbers, sections: sections)
        serialize_ms = (monotonic - serialize_started) * 1000.0
        client = WorkerClient.new(zlib: zlib)
        row = client.request(job_id: job_id, input_path: input_path, output_path: output_path)
        client.shutdown
        raise "cold worker failed: #{row.inspect}" unless row[:status] == :success && row[:semantic_sha256] == expected_sha
        cold_rows << row.merge(serialize_ms: serialize_ms, startup_ms: client.startup_ms, end_to_end_ms: (monotonic - total_started) * 1000.0)
      end

      warm = WorkerClient.new(zlib: zlib)
      warm_startup_ms = warm.startup_ms
      begin
        options.fetch(:repetitions).times do |index|
          job_id = 20_000 + index
          input_path = File.join(dir, "warm-#{index}.input")
          output_path = File.join(dir, "warm-#{index}.output")
          total_started = monotonic
          serialize_started = monotonic
          write_payload(input_path, job_id: job_id, numbers: numbers, sections: sections)
          serialize_ms = (monotonic - serialize_started) * 1000.0
          row = warm.request(job_id: job_id, input_path: input_path, output_path: output_path)
          raise "warm worker failed: #{row.inspect}" unless row[:status] == :success && row[:semantic_sha256] == expected_sha
          warm_rows << row.merge(serialize_ms: serialize_ms, end_to_end_ms: (monotonic - total_started) * 1000.0)
        end
      ensure
        warm.shutdown
      end

      verified = read_output(File.join(dir, 'warm-0.output'))
      raise 'native output semantic digest mismatch on independent Ruby readback' unless verified[:semantic_sha256] == expected_sha

      ruby_median = median(ruby_rows.map { |row| row[:elapsed_ms] })
      cold_median = median(cold_rows.map { |row| row[:end_to_end_ms] })
      warm_median = median(warm_rows.map { |row| row[:end_to_end_ms] })
      pure_worker_median = median(warm_rows.map { |row| row[:worker_ms] })
      speedup = pure_worker_median.positive? ? ruby_median / pure_worker_median : 0.0
      adoption = speedup >= 1.5 && warm_median < ruby_median ? 'ADOPT_NATIVE_WORKER' : 'KEEP_OPTIMIZED_RUBY'
      result = {
        schema: 'sibambo-native-compiler-worker-spike-v1',
        generated_at: Time.now.utc.iso8601,
        fixture: File.expand_path(options.fetch(:fixture)),
        input_shape: {
          numeric_count: numbers.length,
          section_count: sections.length,
          raw_section_bytes: sections.sum { |section| section[:bytes].bytesize }
        },
        protocol_version: PROTOCOL_VERSION,
        worker_executable: worker_executable,
        zlib_dll: zlib,
        repetitions: options.fetch(:repetitions),
        semantic_sha256: expected_sha,
        medians_ms: {
          ruby_in_process: ruby_median,
          native_worker_processing: pure_worker_median,
          native_cold_end_to_end: cold_median,
          native_warm_end_to_end: warm_median,
          native_warm_payload_serialization: median(warm_rows.map { |row| row[:serialize_ms] }),
          native_warm_roundtrip: median(warm_rows.map { |row| row[:roundtrip_ms] }),
          native_cold_startup: median(cold_rows.map { |row| row[:startup_ms] }),
          native_warm_startup_once: warm_startup_ms
        },
        pure_compile_speedup_vs_ruby: speedup,
        adoption_gate: {
          expected_pure_speedup_min: 1.5,
          requires_end_to_end_win: true,
          decision: adoption
        },
        ruby_runs: ruby_rows,
        cold_runs: cold_rows,
        warm_runs: warm_rows
      }
      FileUtils.mkdir_p(File.dirname(options.fetch(:output)))
      File.write(options.fetch(:output), JSON.pretty_generate(result) + "\n", encoding: 'UTF-8')
      result
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    fixture: File.join(SibamboNativeCompilerWorkerSpike.root, 'bom_engine', 'benchmarks', 'fixtures', 'section-cut-heavy-rumah-l.json'),
    output: File.expand_path('../../../docs/worklogs/EVOLUTION-CONVERSION-PERFORMANCE-001/step6-native-worker-benchmark.json', __dir__),
    repetitions: 7,
    numeric_count: 500_000,
    section_count: 4,
    section_bytes: 4 * 1024 * 1024
  }
  OptionParser.new do |parser|
    parser.on('--fixture PATH') { |value| options[:fixture] = File.expand_path(value) }
    parser.on('--output PATH') { |value| options[:output] = File.expand_path(value) }
    parser.on('--repetitions N', Integer) { |value| options[:repetitions] = value }
    parser.on('--numeric-count N', Integer) { |value| options[:numeric_count] = value }
    parser.on('--section-count N', Integer) { |value| options[:section_count] = value }
    parser.on('--section-mib N', Integer) { |value| options[:section_bytes] = value * 1024 * 1024 }
  end.parse!
  result = SibamboNativeCompilerWorkerSpike.benchmark(options)
  puts JSON.pretty_generate(result.reject { |key, _| [:ruby_runs, :cold_runs, :warm_runs].include?(key) })
end

