# frozen_string_literal: true

require 'zlib'

module BOMEngine
  module EvolutionCleanPKG
    module DeterministicZip
      STORE_EXTENSIONS = %w[.jpg .jpeg .png .webp].freeze
      module_function

      def write(path, entries, compression_level: Zlib::BEST_COMPRESSION)
        central = []
        offset = 0
        File.open(path, 'wb') do |file|
          entries.sort_by { |name, _| name }.each do |name, bytes|
            name = name.to_s.b
            payload = bytes.to_s.b
            compressed = STORE_EXTENSIONS.include?(File.extname(name).downcase) ? nil : deflate(payload, compression_level)
            method = compressed && compressed.bytesize < payload.bytesize ? 8 : 0
            encoded = method == 8 ? compressed : payload
            crc = Zlib.crc32(payload)
            local = [0x04034b50, 20, 0, method, 0, 0, crc, encoded.bytesize, payload.bytesize, name.bytesize, 0].pack('VvvvvvVVVvv')
            file.write(local)
            file.write(name)
            file.write(encoded)
            central << [name, payload.bytesize, encoded.bytesize, crc, method, offset]
            offset += local.bytesize + name.bytesize + encoded.bytesize
          end
          central_offset = offset
          central.each do |name, raw, encoded, crc, method, local_offset|
            header = [0x02014b50, 20, 20, 0, method, 0, 0, crc, encoded, raw, name.bytesize, 0, 0, 0, 0, 0, local_offset].pack('VvvvvvvVVVvvvvvVV')
            file.write(header)
            file.write(name)
            offset += header.bytesize + name.bytesize
          end
          central_size = offset - central_offset
          file.write([0x06054b50, 0, 0, central.length, central.length, central_size, central_offset, 0].pack('VvvvvVVv'))
        end
      end

      def deflate(payload, level)
        stream = Zlib::Deflate.new(Integer(level), -Zlib::MAX_WBITS)
        stream.deflate(payload, Zlib::FINISH)
      ensure
        stream&.close
      end
      private_class_method :deflate
    end
  end
end
