# frozen_string_literal: true

require 'zlib'

module BOMEngine
  module CleanAnalysis
    # Minimal deterministic ZIP writer: text uses raw DEFLATE, binary buffers
    # select the smaller of STORE/DEFLATE, and compressed images remain stored.
    module DeterministicZip
      STORE_EXTENSIONS = %w[.jpg .jpeg .png .webp].freeze

      module_function

      def write(path, entries, compression_level: Zlib::BEST_COMPRESSION)
        central = []
        offset = 0
        statistics = {}
        File.open(path, 'wb') do |file|
          entries.sort_by { |name, _bytes| name }.each do |name, bytes|
            entry_name = name.to_s.b
            payload = bytes.to_s.b
            deflated = stored_entry?(entry_name) ? nil : deflate(payload, compression_level)
            method = compression_method(entry_name, payload, deflated)
            encoded = method == 8 ? deflated : payload
            crc = Zlib.crc32(payload)
            local = [0x04034b50, 20, 0, method, 0, 0, crc, encoded.bytesize,
                     payload.bytesize, entry_name.bytesize, 0].pack('VvvvvvVVVvv')
            file.write(local)
            file.write(entry_name)
            file.write(encoded)
            central << [entry_name, payload.bytesize, encoded.bytesize, crc, method, offset]
            statistics[entry_name] = {
              raw_bytes: payload.bytesize,
              archive_bytes: encoded.bytesize,
              method: method == 8 ? 'DEFLATED' : 'STORED',
              deflated_candidate_bytes: deflated&.bytesize,
              stored_candidate_bytes: payload.bytesize
            }
            offset += local.bytesize + entry_name.bytesize + encoded.bytesize
          end
          central_offset = offset
          central.each do |name, raw_size, encoded_size, crc, method, local_offset|
            header = [0x02014b50, 20, 20, 0, method, 0, 0, crc, encoded_size,
                      raw_size, name.bytesize, 0, 0, 0, 0, 0,
                      local_offset].pack('VvvvvvvVVVvvvvvVV')
            file.write(header)
            file.write(name)
            offset += header.bytesize + name.bytesize
          end
          central_size = offset - central_offset
          file.write([0x06054b50, 0, 0, central.length, central.length,
                      central_size, central_offset, 0].pack('VvvvvVVv'))
        end
        statistics
      end

      def stored_entry?(name)
        STORE_EXTENSIONS.include?(File.extname(name.to_s).downcase)
      end
      private_class_method :stored_entry?

      def compression_method(name, payload, deflated)
        return 0 if stored_entry?(name)
        return deflated.bytesize < payload.bytesize ? 8 : 0 if File.extname(name.to_s).downcase == '.bin'

        8
      end
      private_class_method :compression_method

      def deflate(payload, level)
        compressor = Zlib::Deflate.new(Integer(level), -Zlib::MAX_WBITS)
        begin
          compressor.deflate(payload, Zlib::FINISH)
        ensure
          compressor.close
        end
      end
      private_class_method :deflate
    end
  end
end
