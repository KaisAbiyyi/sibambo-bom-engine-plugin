# frozen_string_literal: true

require 'fileutils'
require 'zlib'
require_relative '../bomc_texture_encoder'

module BOMEngine
  module TextureBrowserFixture
    module_function

    CASES = {
      'opaque' => [255, 48, 48, 255, 32, 210, 96, 255],
      'alpha' => [255, 48, 48, 255, 32, 96, 255, 64]
    }.freeze

    def generate(output_directory)
      FileUtils.mkdir_p(output_directory)

      CASES.each do |name, rgba_pixels|
        png_path = File.join(output_directory, "#{name}.png")
        webp_path = File.join(output_directory, "#{name}.webp")
        write_rgba_png(png_path, rgba_pixels)

        result = BOMCTextureEncoder.encode_webp(
          source_path: png_path,
          output_path: webp_path,
          lossless: true,
          timeout_sec: 15
        )
        raise "#{name} fixture encode failed: #{result.inspect}" unless result[:success]
      end
    end

    def write_rgba_png(path, rgba_pixels)
      raw = "\x00".b + rgba_pixels.pack('C*')
      signature = "\x89PNG\r\n\x1a\n".b
      ihdr = [2, 1, 8, 6, 0, 0, 0].pack('NNC5')
      File.binwrite(
        path,
        signature + png_chunk('IHDR', ihdr) +
          png_chunk('IDAT', Zlib::Deflate.deflate(raw)) +
          png_chunk('IEND', ''.b)
      )
    end

    def png_chunk(type, data)
      payload = type.b + data
      [data.bytesize].pack('N') + payload + [Zlib.crc32(payload)].pack('N')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  output_directory = File.expand_path('../benchmarks/browser_verify', __dir__)
  BOMEngine::TextureBrowserFixture.generate(output_directory)
  puts "Browser verification fixtures written to #{output_directory}"
end
