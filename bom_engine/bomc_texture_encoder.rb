# frozen_string_literal: true
# BOMC Texture Encoder Capability Gate and WebP Transcoding Backend (Batch 6)

require 'digest'
require 'fileutils'
require 'open3'

module BOMEngine
  module BOMCTextureEncoder
    DEFAULT_TIMEOUT_SEC = 10
    BUNDLED_CWEBP_VERSION = '1.6.0'
    BUNDLED_CWEBP_SHA256 = '6a2f5cb5dce71366353ab1d9caf9c636e039f25703acfce1c148eed346f2f72a'

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

    def capabilities(force_refresh: false)
      return @cached_capabilities if @cached_capabilities && !force_refresh

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

      version_str = probe_version(path)
      sha256_hex = Digest::SHA256.file(path).hexdigest rescue nil
      source = binary_source(path)
      verified = source == :bundled && sha256_hex == BUNDLED_CWEBP_SHA256
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
        status: version_str ? :ready : :probe_failed
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
        args << '-lossless'
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

    def probe_version(binary_path)
      stdout, status = Open3.capture2(binary_path, '-version') rescue ['', nil]
      return stdout.strip if status && status.success? && !stdout.strip.empty?
      nil
    end
    private_class_method :probe_version

    def binary_source(path)
      expanded = File.expand_path(path)
      return :bundled if expanded == File.expand_path(bundled_binary_path)
      return :configured if configured_binary_path && expanded == File.expand_path(configured_binary_path)
      return :environment if ENV['SIBAMBO_CWEBP_PATH'] && expanded == File.expand_path(ENV['SIBAMBO_CWEBP_PATH'])

      :path
    end
    private_class_method :binary_source

    def execute_process(args, timeout_sec:, checkpoint:)
      pid = Process.spawn(*args, out: File::NULL, err: File::NULL)
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
