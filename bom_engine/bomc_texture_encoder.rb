# frozen_string_literal: true
# BOMC Texture Encoder Capability Gate and WebP Transcoding Backend (Batch 6)

require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'zlib'
require_relative 'windows_codec_process'

module BOMEngine
  module BOMCTextureEncoder
    DEFAULT_TIMEOUT_SEC = 10
    BUNDLED_CWEBP_VERSION = '1.6.0'
    BUNDLED_CWEBP_SHA256 = '6a2f5cb5dce71366353ab1d9caf9c636e039f25703acfce1c148eed346f2f72a'
    BUNDLED_DWEBP_SHA256 = '17c1488bf84b7834e9aa908bb40afd0be2e55d57567d210e96336c56bb6ae993'

    class EncoderError < StandardError; end
    class EncoderUnavailableError < EncoderError; end
    class TranscodeTimeoutError < EncoderError; end
    class TranscodeCancelledError < EncoderError; end

    module_function

    def configured_binary_path=(path)
      @configured_binary_path = path
      @cached_capabilities = nil
    end

    def configured_binary_path
      @configured_binary_path
    end

    def trusted_external_sha256=(sha)
      @trusted_external_sha256 = sha
      @cached_capabilities = nil
    end

    def trusted_external_sha256
      @trusted_external_sha256
    end

    def bundled_binary_path
      base = File.expand_path('bin', __dir__)
      if Gem.win_platform?
        File.join(base, 'win64', 'cwebp.exe')
      else
        File.join(base, 'cwebp')
      end
    end

    def locate_binary
      return configured_binary_path if configured_binary_path
      return ENV['SIBAMBO_CWEBP_PATH'] if ENV['SIBAMBO_CWEBP_PATH']

      bundled = bundled_binary_path
      return bundled if File.file?(bundled)

      # Search PATH
      lookup_command = Gem.win_platform? ? ['where.exe', 'cwebp.exe'] : ['which', 'cwebp']
      stdout, status = Open3.capture2(*lookup_command) rescue ['', nil]
      if status && status.success?
        found = stdout.lines.first.to_s.strip
        return found if !found.empty? && File.file?(found)
      end

      nil
    end

    def capabilities(force_refresh: false, require_verified: false)
      return @cached_capabilities if @cached_capabilities && !force_refresh && (!require_verified || @cached_capabilities[:verified])

      path = locate_binary
      unless path && File.file?(path)
        @cached_capabilities = {
          available: false,
          webp: false,
          webp_alpha: false,
          webp_lossless: false,
          encoder_name: 'libwebp/cwebp',
          version: 'unavailable',
          binary_path: nil,
          sha256: nil,
          verified: false,
          source: nil,
          status: :binary_not_found
        }.freeze
        return @cached_capabilities
      end

      version_str = nil
      sha256_hex = Digest::SHA256.file(path).hexdigest rescue nil
      source = binary_source(path)
      trusted_sha = ENV['SIBAMBO_CWEBP_TRUSTED_SHA256'] || @trusted_external_sha256
      verified = if source == :bundled
                   sha256_hex == BUNDLED_CWEBP_SHA256
                 elsif trusted_sha
                   sha256_hex == trusted_sha
                 else
                   false
                 end

      if require_verified && !verified
        return { available: false, webp: false, webp_alpha: false, webp_lossless: false,
          verified: false, binary_path: path, sha256: sha256_hex, source: source,
          status: :untrusted_binary, version: 'unverified' }.freeze
      end

      if source == :bundled && !verified
        @cached_capabilities = {
          available: false,
          webp: false,
          webp_alpha: false,
          webp_lossless: false,
          encoder_name: 'libwebp/cwebp',
          version: version_str || 'unknown',
          binary_path: path,
          sha256: sha256_hex,
          verified: false,
          source: source,
          status: :checksum_mismatch
        }.freeze
        return @cached_capabilities
      end

      if source != :bundled && trusted_sha && !verified
        @cached_capabilities = {
          available: false,
          webp: false,
          webp_alpha: false,
          webp_lossless: false,
          encoder_name: 'libwebp/cwebp',
          version: version_str || 'unknown',
          binary_path: path,
          sha256: sha256_hex,
          verified: false,
          source: source,
          status: :external_trust_verification_failed
        }.freeze
        return @cached_capabilities
      end

      version_str = probe_version(path)
      @cached_capabilities = {
        available: !version_str.nil?,
        webp: !version_str.nil?,
        webp_alpha: !version_str.nil?,
        webp_lossless: !version_str.nil?,
        encoder_name: 'libwebp/cwebp',
        version: version_str || 'unknown',
        binary_path: path,
        sha256: sha256_hex,
        verified: verified,
        source: source,
        status: version_str ? :ready : :probe_failed,
        probe: @last_version_probe
      }.freeze
      @cached_capabilities
    end

    def version
      capabilities[:version]
    end

    def binary_sha256_or_library_version
      capabilities[:sha256] || capabilities[:version]
    end

    def available?
      capabilities[:available]
    end

    def encode_webp(source_path:, output_path:, quality: 80, lossless: false, timeout_sec: DEFAULT_TIMEOUT_SEC, checkpoint: nil)
      caps = capabilities
      unless caps[:available]
        return {
          success: false,
          reason: :encoder_unavailable,
          status: caps[:status],
          output_path: nil
        }
      end

      raise ArgumentError, "Source file not found: #{source_path}" unless File.file?(source_path)

      temp_output = "#{output_path}.#{Process.pid}.part"
      FileUtils.mkdir_p(File.dirname(temp_output))

      args = [caps[:binary_path]]
      if lossless
        args.concat(['-lossless', '-exact'])
      else
        args.concat(['-q', [[quality.to_i, 0].max, 100].min.to_s])
      end
      args.concat(['-quiet', source_path, '-o', temp_output])

      begin
        execute_process(args, timeout_sec: timeout_sec, checkpoint: checkpoint)

        unless File.file?(temp_output) && valid_webp_header?(temp_output)
          File.delete(temp_output) if File.file?(temp_output)
          return {
            success: false,
            reason: :invalid_webp_output,
            output_path: nil
          }
        end

        FileUtils.mv(temp_output, output_path, force: true)
        {
          success: true,
          path: output_path,
          bytes: File.size(output_path),
          format: :webp,
          quality: quality,
          lossless: lossless
        }
      rescue TranscodeCancelledError
        File.delete(temp_output) if File.file?(temp_output)
        raise
      rescue TranscodeTimeoutError
        File.delete(temp_output) if File.file?(temp_output)
        {
          success: false,
          reason: :timeout,
          output_path: nil
        }
      rescue StandardError => e
        File.delete(temp_output) if File.file?(temp_output)
        {
          success: false,
          reason: :encoder_error,
          error: "#{e.class}: #{e.message}",
          output_path: nil
        }
      end
    end

    def valid_webp_header?(path)
      return false unless File.file?(path) && File.size(path) >= 12
      bytes = File.binread(path, 12)
      bytes[0, 4] == 'RIFF' && bytes[8, 4] == 'WEBP'
    end

    # Decode to PNG so both reference and candidate use SketchUp's ImageRep
    # channel order and orientation (BGR on Windows, RGB on macOS).
    def decode_webp(source_path:, output_path:, timeout_sec: DEFAULT_TIMEOUT_SEC, checkpoint: nil)
      decoder = File.join(File.dirname(bundled_binary_path), Gem.win_platform? ? 'dwebp.exe' : 'dwebp')
      unless File.file?(decoder) && Digest::SHA256.file(decoder).hexdigest == BUNDLED_DWEBP_SHA256
        return { success: false, reason: :verified_decoder_unavailable }
      end
      temporary = "#{output_path}.#{Process.pid}.part"
      begin
        execute_process([decoder, source_path, '-quiet', '-o', temporary], timeout_sec: timeout_sec, checkpoint: checkpoint)
        unless File.file?(temporary) && File.binread(temporary, 8) == "\x89PNG\r\n\x1a\n".b
          return { success: false, reason: :invalid_decoded_png }
        end
        FileUtils.mv(temporary, output_path)
        { success: true, path: output_path }
      rescue TranscodeCancelledError
        raise
      rescue TranscodeTimeoutError
        { success: false, reason: :decode_timeout }
      rescue StandardError => error
        { success: false, reason: :decode_error, error: "#{error.class}: #{error.message}" }
      ensure
        File.delete(temporary) if File.file?(temporary)
      end
    end

    # Embedded SketchUp on Windows can lose Open3 pipe output. Use private
    # regular files and the same bounded process runner as actual transcoding.
    def probe_version(binary_path, timeout_sec: 2)
      Dir.mktmpdir('bomc-codec-probe-') do |directory|
        stdout_path = File.join(directory, 'stdout.txt')
        stderr_path = File.join(directory, 'stderr.txt')
        error = nil
        begin
          execute_process([binary_path, '-version'], timeout_sec: timeout_sec, checkpoint: nil,
            stdout_path: stdout_path, stderr_path: stderr_path)
        rescue StandardError => failure
          error = "#{failure.class}: #{failure.message}"
        end
        stdout = File.file?(stdout_path) ? File.binread(stdout_path, 4096).to_s.dup.force_encoding('UTF-8').scrub.strip : ''
        stderr = File.file?(stderr_path) ? File.binread(stderr_path, 4096).to_s.dup.force_encoding('UTF-8').scrub.strip : ''
        @last_version_probe = { transport: :file, process_backend: process_backend(binary_path),
          stdout: stdout, stderr: stderr, error: error }.freeze
        return stdout if error.nil? && stdout.match?(/\A\d+\.\d+\.\d+(?:\s|\z)/)
        nil
      end
    end
    private_class_method :probe_version

    # Model-independent, tiny encode/decode trial. Call before expensive capture
    # so a broken codec cannot silently turn a long adaptive run into baseline.
    def preflight(checkpoint: nil)
      caps = capabilities(force_refresh: true, require_verified: true)
      return { success: false, stage: :capabilities, capabilities: caps } unless caps[:available] && caps[:verified]

      Dir.mktmpdir('bomc-codec-preflight-') do |directory|
        source = File.join(directory, 'source.png')
        chunk = lambda do |type, data|
          [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
        end
        pixels = [0, 255, 0, 0, 255, 0, 255, 0, 64].pack('C*') # Filter + 2 RGBA pixels.
        png = "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', [2, 1, 8, 6, 0, 0, 0].pack('NNCCCCC')) +
          chunk.call('IDAT', Zlib::Deflate.deflate(pixels)) + chunk.call('IEND', ''.b)
        File.binwrite(source, png)
        encoded = encode_webp(source_path: source, output_path: File.join(directory, 'trial.webp'),
          lossless: true, timeout_sec: 3, checkpoint: checkpoint)
        return { success: false, stage: :encode, capabilities: caps, result: encoded } unless encoded[:success]
        decoded = decode_webp(source_path: encoded[:path], output_path: File.join(directory, 'decoded.png'),
          timeout_sec: 3, checkpoint: checkpoint)
        return { success: false, stage: :decode, capabilities: caps, result: decoded } unless decoded[:success]
        { success: true, capabilities: caps, encoded_bytes: encoded[:bytes], decoded_format: 'png' }
      end
    end

    def binary_source(path)
      expanded = File.expand_path(path)
      return :bundled if expanded == File.expand_path(bundled_binary_path)
      return :configured if configured_binary_path && expanded == File.expand_path(configured_binary_path)
      return :environment if ENV['SIBAMBO_CWEBP_PATH'] && expanded == File.expand_path(ENV['SIBAMBO_CWEBP_PATH'])

      :path
    end
    private_class_method :binary_source

    def process_backend(binary_path)
      Gem.win_platform? && File.extname(binary_path).downcase == '.exe' ? :windows_native : :ruby_spawn
    end
    private_class_method :process_backend

    def execute_process(args, timeout_sec:, checkpoint:, stdout_path: nil, stderr_path: nil)
      if process_backend(args.first) == :windows_native
        begin
          poll = checkpoint && -> { checkpoint.call(stage: :transcode_webp) }
          code = WindowsCodecProcess.run(args, timeout_sec: timeout_sec, checkpoint: poll,
            stdout_path: stdout_path, stderr_path: stderr_path)
          raise EncoderError, "Encoder process exited with code #{code}" unless code == 0
          return
        rescue WindowsCodecProcess::TimeoutError => error
          raise TranscodeTimeoutError, error.message
        rescue WindowsCodecProcess::CancelledError => error
          raise TranscodeCancelledError, error.message
        rescue WindowsCodecProcess::ProcessError => error
          raise EncoderError, error.message
        end
      end

      # Portable path, also retained for explicitly configured legacy wrappers.
      # Bundled Windows .exe codecs never fall back to this broken host boundary.
      pid = Process.spawn(*args, out: stdout_path || File::NULL, err: stderr_path || File::NULL)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        res = Process.waitpid(pid, Process::WNOHANG)
        if res == pid
          status = $?
          raise EncoderError, "Encoder process exited with code #{status.exitstatus}" unless status.success?
          break
        end

        if checkpoint
          begin
            checkpoint.call(stage: :transcode_webp)
          rescue StandardError => e
            Process.kill('KILL', pid) rescue nil
            Process.waitpid(pid) rescue nil
            raise TranscodeCancelledError, "Transcoding cancelled: #{e.message}"
          end
        end

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed > timeout_sec
          Process.kill('KILL', pid) rescue nil
          Process.waitpid(pid) rescue nil
          raise TranscodeTimeoutError, "Transcoder timed out after #{timeout_sec}s"
        end

        sleep 0.02
      end
    end
    private_class_method :execute_process
  end
end
