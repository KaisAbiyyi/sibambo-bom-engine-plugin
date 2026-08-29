# frozen_string_literal: true

# Run with SketchUp:
#   SketchUp.exe -RubyStartup ".../verify_texture_encoder_sketchup.rb"

require 'json'
require 'tmpdir'
require 'zlib'
require 'fileutils'
require_relative '../bomc_texture_encoder'

module BOMEngine
  module TextureEncoderSketchUpVerification
    module_function

    def run
      output_path = ENV['SIBAMBO_WEBP_RUNTIME_EVIDENCE']
      raise 'SIBAMBO_WEBP_RUNTIME_EVIDENCE is required.' if output_path.to_s.empty?

      evidence = {
        schema_version: 1,
        sketchup_version: Sketchup.version,
        os: RUBY_PLATFORM,
        ruby_version: RUBY_VERSION,
        encoder: BOMCTextureEncoder.capabilities(force_refresh: true)
      }

      Dir.mktmpdir('sibambo-sketchup-webp') do |directory|
        evidence[:opaque_texture] = verify_case(
          directory,
          'opaque',
          [255, 0, 0, 255, 0, 255, 0, 255]
        )
        evidence[:alpha_texture] = verify_case(
          directory,
          'alpha',
          [255, 0, 0, 255, 0, 0, 255, 64]
        )
      end

      evidence[:status] = if evidence[:opaque_texture][:pixel_exact] && evidence[:alpha_texture][:pixel_exact]
                            'pass'
                          else
                            'fail'
                          end
      write_evidence(output_path, evidence)
    rescue StandardError => error
      write_evidence(
        output_path,
        {
          schema_version: 1,
          status: 'error',
          sketchup_version: defined?(Sketchup) ? Sketchup.version : nil,
          error: "#{error.class}: #{error.message}",
          backtrace: Array(error.backtrace).first(10)
        }
      ) if output_path && !output_path.empty?
    ensure
      Sketchup.quit if defined?(Sketchup)
    end

    def verify_case(directory, name, rgba_pixels)
      source_path = File.join(directory, "#{name}.png")
      webp_path = File.join(directory, "#{name}.webp")
      pam_path = File.join(directory, "#{name}.pam")
      write_rgba_png(source_path, rgba_pixels)

      encoded = BOMCTextureEncoder.encode_webp(
        source_path: source_path,
        output_path: webp_path,
        lossless: true,
        timeout_sec: 15
      )
      raise "#{name} WebP encode failed: #{encoded.inspect}" unless encoded[:success]

      decoder_path = File.join(File.dirname(BOMCTextureEncoder.bundled_binary_path), 'dwebp.exe')
      pid = Process.spawn(decoder_path, webp_path, '-pam', '-o', pam_path, out: File::NULL, err: File::NULL)
      Process.waitpid(pid)
      raise "#{name} WebP decode failed." unless $?.success? && File.file?(pam_path)

      decoded = read_pam(pam_path)
      {
        source_bytes: File.size(source_path),
        candidate_bytes: File.size(webp_path),
        source_dimensions: [2, 1],
        decoded_dimensions: [decoded[:width], decoded[:height]],
        dimensions_preserved: decoded[:width] == 2 && decoded[:height] == 1,
        alpha_preserved: decoded[:rgba].each_slice(4).map { |pixel| pixel[3] } == rgba_pixels.each_slice(4).map { |pixel| pixel[3] },
        pixel_metric: 'lossless exact RGBA comparison',
        pixel_exact: decoded[:rgba] == rgba_pixels,
        webp_header_valid: BOMCTextureEncoder.valid_webp_header?(webp_path)
      }
    end

    def write_rgba_png(path, rgba_pixels)
      raw = "\x00".b + rgba_pixels.pack('C*')
      signature = "\x89PNG\r\n\x1a\n".b
      ihdr = [2, 1, 8, 6, 0, 0, 0].pack('NNC5')
      File.binwrite(path, signature + png_chunk('IHDR', ihdr) + png_chunk('IDAT', Zlib::Deflate.deflate(raw)) + png_chunk('IEND', ''.b))
    end

    def png_chunk(type, data)
      payload = type.b + data
      [data.bytesize].pack('N') + payload + [Zlib.crc32(payload)].pack('N')
    end

    def read_pam(path)
      bytes = File.binread(path)
      header_end = bytes.index("ENDHDR\n")
      raise 'Invalid PAM output.' unless header_end

      header = bytes.byteslice(0, header_end + 7)
      width = header[/^WIDTH (\d+)$/, 1].to_i
      height = header[/^HEIGHT (\d+)$/, 1].to_i
      depth = header[/^DEPTH (\d+)$/, 1].to_i
      pixels = bytes.byteslice(header_end + 7, bytes.bytesize).bytes
      rgba = if depth == 4
               pixels
             elsif depth == 3
               pixels.each_slice(3).flat_map { |pixel| pixel + [255] }
             else
               raise "Unsupported PAM depth #{depth}."
             end
      { width: width, height: height, rgba: rgba }
    end

    def write_evidence(path, evidence)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(evidence))
    end
  end
end

UI.start_timer(0.5, false) { BOMEngine::TextureEncoderSketchUpVerification.run }
