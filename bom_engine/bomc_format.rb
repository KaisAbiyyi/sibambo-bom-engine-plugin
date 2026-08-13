# Deterministic BOMC 1.0 container primitives.

require 'zlib'

module BOMEngine
  module BOMC
    MAGIC = "BOMC\r\n\x1a\n".b.freeze
    VERSION_MAJOR = 1
    VERSION_MINOR = 0
    HEADER_BYTES = 32
    DIRECTORY_ENTRY_BYTES = 40
    ENDIAN_MARKER = 0x0102_0304
    ALIGNMENT = 8

    PROFILE_PRODUCTION = 0x0000_0001
    PROFILE_DEBUG = 0x0000_0002

    CODEC_STORE = 0
    CODEC_DEFLATE = 1

    SECTION_MODEL = 1
    SECTION_STRINGS = 2
    SECTION_MATERIALS = 3
    SECTION_TAGS = 4
    SECTION_MESHES = 5
    SECTION_FACES = 6
    SECTION_POSITIONS = 7
    SECTION_TOPOLOGY = 8
    SECTION_NORMALS = 9
    SECTION_UVS = 10
    SECTION_DEFINITIONS = 11
    SECTION_INSTANCES = 12
    SECTION_TRANSFORMS = 13
    SECTION_VISUAL_EDGES = 14
    SECTION_TEXTURE_TABLE = 15
    SECTION_TEXTURE_BLOBS = 16
    SECTION_COVERAGE = 17
    SECTION_FALLBACK = 18
    SECTION_DEBUG = 240

    SURFACE_TYPES = {
      '' => 0, 'unknown' => 0, 'wall' => 1, 'floor' => 2, 'ceiling' => 3,
      'roof' => 4, 'roof_slope' => 5, 'roof_flat' => 6, 'opening' => 7,
      'window' => 8, 'door' => 9, 'railing' => 10, 'room' => 11,
      'facade' => 12, 'column' => 13, 'beam' => 14, 'stair' => 15
    }.freeze
    SURFACE_NAMES = {
      0 => 'unknown', 1 => 'wall', 2 => 'floor', 3 => 'ceiling', 4 => 'roof',
      5 => 'roof_slope', 6 => 'roof_flat', 7 => 'opening', 8 => 'window',
      9 => 'door', 10 => 'railing', 11 => 'room', 12 => 'facade', 13 => 'column',
      14 => 'beam', 15 => 'stair'
    }.freeze
    NODE_TYPES = { 'unknown' => 0, 'root' => 1, 'component_instance' => 2, 'group_instance' => 3, 'image' => 4, 'text' => 5 }.freeze
    NODE_NAMES = NODE_TYPES.each_with_object({}) { |(name, value), result| result[value] = name }.freeze
    DEFINITION_TYPES = { 'unknown' => 0, 'model_definition' => 1, 'component_definition' => 2, 'group_definition' => 3 }.freeze
    DEFINITION_NAMES = DEFINITION_TYPES.each_with_object({}) { |(name, value), result| result[value] = name }.freeze
    SEMANTIC_ROLES = {
      '' => 0, 'unknown' => 0, 'wall' => 1, 'floor' => 2, 'ceiling' => 3,
      'roof' => 4, 'opening' => 5, 'window' => 6, 'door' => 7,
      'railing' => 8, 'room' => 9, 'facade' => 10, 'column' => 11,
      'beam' => 12, 'stair' => 13
    }.freeze
    SEMANTIC_ROLE_NAMES = {
      0 => 'unknown', 1 => 'wall', 2 => 'floor', 3 => 'ceiling', 4 => 'roof',
      5 => 'opening', 6 => 'window', 7 => 'door', 8 => 'railing', 9 => 'room',
      10 => 'facade', 11 => 'column', 12 => 'beam', 13 => 'stair'
    }.freeze
    TEXTURE_MEDIA = { binary: 0, png: 1, jpeg: 2, webp: 3, avif: 4, ktx2: 5 }.freeze
    TEXTURE_MEDIA_NAMES = TEXTURE_MEDIA.each_with_object({}) { |(name, value), result| result[value] = name }.freeze

    HEADER_PACK = 'a8vvVVVQ<'.freeze
    DIRECTORY_PACK = 'vCCQ<Q<Q<VVV'.freeze

    module Binary
      module_function

      def write_varuint(value)
        integer = Integer(value)
        raise ArgumentError, 'varuint cannot encode a negative value.' if integer < 0

        bytes = +''.b
        loop do
          byte = integer & 0x7f
          integer >>= 7
          byte |= 0x80 unless integer.zero?
          bytes << byte
          break if integer.zero?
        end
        bytes
      end

      def read_varuint(bytes, offset = 0)
        value = 0
        shift = 0
        cursor = offset.to_i
        loop do
          raise 'BOMC invalid: truncated varint.' if cursor >= bytes.bytesize

          byte = bytes.getbyte(cursor)
          cursor += 1
          value |= (byte & 0x7f) << shift
          return [value, cursor] if (byte & 0x80).zero?

          shift += 7
          raise 'BOMC invalid: varint overflow.' if shift > 63
        end
      end

      def write_zigzag(value)
        integer = Integer(value)
        encoded = integer < 0 ? ((-integer) << 1) - 1 : integer << 1
        write_varuint(encoded)
      end

      def read_zigzag(bytes, offset = 0)
        encoded, cursor = read_varuint(bytes, offset)
        value = (encoded & 1).zero? ? encoded >> 1 : -((encoded + 1) >> 1)
        [value, cursor]
      end

      def index_width(count)
        integer = Integer(count)
        raise ArgumentError, 'index count cannot be negative.' if integer < 0

        return 1 if integer <= 255
        return 2 if integer <= 65_535

        4
      end

      def sentinel(width)
        case width
        when 1 then 255
        when 2 then 65_535
        when 4 then 4_294_967_295
        else raise ArgumentError, "unsupported index width #{width}."
        end
      end

      def pack_indices(values, width)
        missing = sentinel(width)
        integers = Array(values).map do |value|
          next missing if value.nil?

          integer = Integer(value)
          if integer < 0 || integer >= missing
            raise ArgumentError, "index #{integer} does not fit width #{width}."
          end
          integer
        end
        integers.pack(index_pack(width))
      end

      def unpack_indices(bytes, width, count = nil)
        values = bytes.unpack(index_pack(width))
        if count && values.length != count.to_i
          raise "BOMC invalid: adaptive index count #{values.length} != #{count}."
        end
        missing = sentinel(width)
        values.map { |value| value == missing ? nil : value }
      end

      def index_pack(width)
        case width
        when 1 then 'C*'
        when 2 then 'S<*'
        when 4 then 'V*'
        else raise ArgumentError, "unsupported index width #{width}."
        end
      end

      def align(value, alignment = ALIGNMENT)
        integer = Integer(value)
        boundary = Integer(alignment)
        integer + ((boundary - (integer % boundary)) % boundary)
      end
    end

    module Container
      module_function

      def pack(sections, flags: PROFILE_PRODUCTION)
        ordered = Array(sections).each_with_index.sort_by do |section, index|
          [Integer(section.fetch(:type)), index]
        end.map(&:first)
        prepared = ordered.map { |section| prepare_section(section) }
        directory_offset = HEADER_BYTES
        cursor = Binary.align(directory_offset + prepared.length * DIRECTORY_ENTRY_BYTES)
        prepared.each do |section|
          cursor = Binary.align(cursor)
          section[:offset] = cursor
          cursor += section[:stored_bytes].bytesize
        end

        header = [
          MAGIC,
          VERSION_MAJOR,
          VERSION_MINOR,
          ENDIAN_MARKER,
          Integer(flags),
          prepared.length,
          directory_offset
        ].pack(HEADER_PACK)
        raise 'BOMC internal: header byte count mismatch.' unless header.bytesize == HEADER_BYTES

        directory = +''.b
        prepared.each do |section|
          directory << [
            section[:type],
            section[:codec],
            section[:flags],
            section[:offset],
            section[:stored_bytes].bytesize,
            section[:raw_bytes].bytesize,
            section[:count],
            Zlib.crc32(section[:stored_bytes]),
            0
          ].pack(DIRECTORY_PACK)
        end
        raise 'BOMC internal: directory byte count mismatch.' unless directory.bytesize == prepared.length * DIRECTORY_ENTRY_BYTES

        output = header + directory
        output << ("\0" * (Binary.align(output.bytesize) - output.bytesize)).b
        prepared.each do |section|
          output << ("\0" * (section[:offset] - output.bytesize)).b
          output << section[:stored_bytes]
        end
        output.b
      end

      def parse(bytes, verify_checksums: true)
        content = bytes.b
        directory = read_directory(content)
        decoded = directory[:sections].map do |descriptor|
          stored = content.byteslice(descriptor[:offset], descriptor[:stored_size]).b
          if verify_checksums && Zlib.crc32(stored) != descriptor[:crc32]
            raise "BOMC invalid: section #{descriptor[:index]} checksum mismatch."
          end
          raw = decode_section(stored, descriptor[:codec], descriptor[:index])
          if raw.bytesize != descriptor[:raw_size]
            raise "BOMC invalid: section #{descriptor[:index]} raw size mismatch."
          end
          descriptor.merge(bytes: raw, stored_bytes: stored)
        end
        directory.merge(sections: decoded)
      rescue Zlib::Error => error
        raise "BOMC invalid: compressed section #{error.message}"
      end

      def read_directory(bytes)
        content = bytes.b
        raise 'BOMC invalid: truncated header.' if content.bytesize < HEADER_BYTES

        magic, major, minor, endian, flags, section_count, directory_offset = content.byteslice(0, HEADER_BYTES).unpack(HEADER_PACK)
        raise 'BOMC invalid: magic mismatch.' unless magic == MAGIC
        raise "BOMC invalid: unsupported version #{major}.#{minor}." unless major == VERSION_MAJOR
        raise 'BOMC invalid: unsupported byte order.' unless endian == ENDIAN_MARKER
        raise 'BOMC invalid: directory precedes fixed header.' if directory_offset < HEADER_BYTES

        directory_size = section_count * DIRECTORY_ENTRY_BYTES
        directory_end = directory_offset + directory_size
        raise 'BOMC invalid: directory outside file.' if directory_end > content.bytesize

        descriptors = section_count.times.map do |index|
          entry_offset = directory_offset + index * DIRECTORY_ENTRY_BYTES
          values = content.byteslice(entry_offset, DIRECTORY_ENTRY_BYTES).unpack(DIRECTORY_PACK)
          type, codec, section_flags, offset, stored_size, raw_size, count, crc32, reserved = values
          raise "BOMC invalid: section #{index} reserved field." unless reserved.zero?
          if offset < Binary.align(directory_end) || offset + stored_size > content.bytesize
            raise "BOMC invalid: section #{index} outside file."
          end
          raise "BOMC invalid: section #{index} alignment." unless (offset % ALIGNMENT).zero?

          {
            index: index,
            type: type,
            codec: codec,
            flags: section_flags,
            offset: offset,
            stored_size: stored_size,
            raw_size: raw_size,
            count: count,
            crc32: crc32
          }
        end
        descriptors.sort_by { |section| [section[:offset], section[:index]] }.each_cons(2) do |left, right|
          if left[:offset] + left[:stored_size] > right[:offset]
            raise "BOMC invalid: section #{right[:index]} overlaps section #{left[:index]}."
          end
        end

        {
          header: {
            major: major,
            minor: minor,
            header_bytes: HEADER_BYTES,
            directory_entry_bytes: DIRECTORY_ENTRY_BYTES,
            endianness: :little,
            flags: flags,
            section_count: section_count,
            directory_offset: directory_offset
          },
          sections: descriptors
        }
      end

      def prepare_section(section)
        raw = section.fetch(:bytes).b
        stored = raw
        codec = CODEC_STORE
        if section[:compress]
          candidate = Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)
          if candidate.bytesize < raw.bytesize
            stored = candidate
            codec = CODEC_DEFLATE
          end
        end
        {
          type: Integer(section.fetch(:type)),
          codec: codec,
          flags: Integer(section[:flags] || 0),
          count: Integer(section[:count] || 0),
          raw_bytes: raw,
          stored_bytes: stored
        }
      end
      private_class_method :prepare_section

      def decode_section(stored, codec, index)
        case codec
        when CODEC_STORE then stored
        when CODEC_DEFLATE then Zlib::Inflate.inflate(stored)
        else raise "BOMC invalid: section #{index} uses unsupported codec #{codec}."
        end
      end
      private_class_method :decode_section
    end
  end
end
