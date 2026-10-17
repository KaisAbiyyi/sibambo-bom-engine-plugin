# frozen_string_literal: true

require 'zlib'
require 'digest'
require 'tempfile'

module BOMEngine
  module EvolutionCleanPKG
    module DeterministicZip
      FileSource = Struct.new(:path)
      PreparedSource = Struct.new(:raw_size, :encoded_size, :crc, :method, :source, :temporary)
      STORE_EXTENSIONS = %w[.jpg .jpeg .png .webp].freeze
      COPY_CHUNK = 64 * 1024
      module_function

      def file_source(path)
        FileSource.new(File.expand_path(path.to_s))
      end

      def write(path, entries, compression_level: Zlib::BEST_COMPRESSION)
        central = []
        offset = 0
        digest = Digest::SHA256.new
        prepared_sources = []
        File.open(path, 'wb') do |file|
          entries.sort_by { |name, _| name }.each do |name, source|
            name = name.to_s.b
            prepared = prepare_source(name, source, compression_level)
            prepared_sources << prepared
            local = [0x04034b50, 20, 0, prepared.method, 0, 0, prepared.crc, prepared.encoded_size, prepared.raw_size, name.bytesize, 0].pack('VvvvvvVVVvv')
            emit(file, digest, local)
            emit(file, digest, name)
            copy_source(file, digest, prepared.source)
            central << [name, prepared.raw_size, prepared.encoded_size, prepared.crc, prepared.method, offset]
            offset += local.bytesize + name.bytesize + prepared.encoded_size
          end
          central_offset = offset
          central.each do |name, raw, encoded, crc, method, local_offset|
            header = [0x02014b50, 20, 20, 0, method, 0, 0, crc, encoded, raw, name.bytesize, 0, 0, 0, 0, 0, local_offset].pack('VvvvvvvVVVvvvvvVV')
            emit(file, digest, header)
            emit(file, digest, name)
            offset += header.bytesize + name.bytesize
          end
          central_size = offset - central_offset
          footer = [0x06054b50, 0, 0, central.length, central.length, central_size, central_offset, 0].pack('VvvvvVVv')
          emit(file, digest, footer)
          offset += footer.bytesize
        end
        { path: path, bytes: offset, sha256: digest.hexdigest }
      ensure
        Array(prepared_sources).each do |prepared|
          prepared.temporary.close! if prepared && prepared.temporary
        rescue StandardError
          nil
        end
      end

      def deflate(payload, level)
        stream = Zlib::Deflate.new(Integer(level), -Zlib::MAX_WBITS)
        stream.deflate(payload, Zlib::FINISH)
      ensure
        stream&.close
      end
      private_class_method :deflate

      def prepare_source(name, source, level)
        return prepare_file_source(name, source.path, level) if source.is_a?(FileSource)

        payload = source.to_s.b
        compressed = STORE_EXTENSIONS.include?(File.extname(name).downcase) ? nil : deflate(payload, level)
        method = compressed && compressed.bytesize < payload.bytesize ? 8 : 0
        encoded = method == 8 ? compressed : payload
        PreparedSource.new(payload.bytesize, encoded.bytesize, Zlib.crc32(payload), method, encoded, nil)
      end
      private_class_method :prepare_source

      def prepare_file_source(name, path, level)
        raise ArgumentError, "ZIP source missing: #{path}" unless File.file?(path)
        if STORE_EXTENSIONS.include?(File.extname(name).downcase)
          crc = crc_file(path)
          return PreparedSource.new(File.size(path), File.size(path), crc, 0, FileSource.new(path), nil)
        end

        temporary = Tempfile.new(['evolution-zip-', '.deflate'])
        temporary.binmode
        crc = 0
        raw_size = 0
        deflater = Zlib::Deflate.new(Integer(level), -Zlib::MAX_WBITS)
        File.open(path, 'rb') do |input|
          while (chunk = input.read(COPY_CHUNK))
            raw_size += chunk.bytesize
            crc = Zlib.crc32(chunk, crc)
            encoded = deflater.deflate(chunk, Zlib::NO_FLUSH)
            temporary.write(encoded) unless encoded.empty?
          end
        end
        tail = deflater.finish
        temporary.write(tail) unless tail.empty?
        deflater.close
        temporary.flush
        if temporary.size < raw_size
          PreparedSource.new(raw_size, temporary.size, crc, 8, FileSource.new(temporary.path), temporary)
        else
          temporary.close!
          PreparedSource.new(raw_size, raw_size, crc, 0, FileSource.new(path), nil)
        end
      rescue StandardError
        deflater&.close rescue nil
        temporary&.close! rescue nil
        raise
      end
      private_class_method :prepare_file_source

      def crc_file(path)
        crc = 0
        File.open(path, 'rb') do |input|
          while (chunk = input.read(COPY_CHUNK))
            crc = Zlib.crc32(chunk, crc)
          end
        end
        crc
      end
      private_class_method :crc_file

      def copy_source(file, digest, source)
        if source.is_a?(FileSource)
          File.open(source.path, 'rb') do |input|
            while (chunk = input.read(COPY_CHUNK))
              emit(file, digest, chunk)
            end
          end
        else
          emit(file, digest, source)
        end
      end
      private_class_method :copy_source

      def emit(file, digest, bytes)
        file.write(bytes)
        digest.update(bytes)
      end
      private_class_method :emit
    end
  end
end
