# frozen_string_literal: true

require 'zlib'

module BOMEngine
  module CleanAnalysis
    # Minimal ZIP writer using stored entries and a fixed DOS timestamp.
    module DeterministicZip
      module_function

      def write(path, entries)
        central = []
        offset = 0
        File.open(path, 'wb') do |file|
          entries.sort_by { |name, _bytes| name }.each do |name, bytes|
            entry_name = name.to_s.b
            payload = bytes.to_s.b
            crc = Zlib.crc32(payload)
            local = [0x04034b50, 20, 0, 0, 0, 0, crc, payload.bytesize,
                     payload.bytesize, entry_name.bytesize, 0].pack('VvvvvvVVVvv')
            file.write(local)
            file.write(entry_name)
            file.write(payload)
            central << [entry_name, payload, crc, offset]
            offset += local.bytesize + entry_name.bytesize + payload.bytesize
          end
          central_offset = offset
          central.each do |name, payload, crc, local_offset|
            header = [0x02014b50, 20, 20, 0, 0, 0, 0, crc, payload.bytesize,
                      payload.bytesize, name.bytesize, 0, 0, 0, 0, 0,
                      local_offset].pack('VvvvvvvVVVvvvvvVV')
            file.write(header)
            file.write(name)
            offset += header.bytesize + name.bytesize
          end
          central_size = offset - central_offset
          file.write([0x06054b50, 0, 0, central.length, central.length,
                      central_size, central_offset, 0].pack('VvvvvVVv'))
        end
      end
    end
  end
end
