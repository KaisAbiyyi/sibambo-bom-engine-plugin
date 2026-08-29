# Deterministic BOMC 1.0/1.1/1.2 container primitives.

require 'zlib'

module BOMEngine
  module BOMC
    MAGIC = "BOMC\r\n\x1a\n".b.freeze
    VERSION_MAJOR = 1
    VERSION_MINOR = 2
    HEADER_BYTES = 32
    # BOMC 1.0 descriptor size. Kept as the compatibility constant for callers
    # that need to inspect or construct a legacy directory.
    DIRECTORY_ENTRY_BYTES = 40
    COMPACT_DIRECTORY_ENTRY_BYTES = 24
    ENDIAN_MARKER = 0x0102_0304
    ALIGNMENT = 8

    PROFILE_PRODUCTION = 0x0000_0001
    PROFILE_DEBUG = 0x0000_0002
    FLAG_COMPACT_DIRECTORY = 0x0000_0010
    FLAG_SCOPE_ACTIVE = 0x0000_0100
    FLAG_SCOPE_ALL = 0x0000_0200
    FLAG_HAS_SCENES = 0x0000_0400

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
    SECTION_SCENES = 19
    SECTION_ENCODING_CONTRACT = 20
    SECTION_CLIP_PLANES = 21
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
      'beam' => 12, 'stair' => 13, 'furniture' => 14, 'fixture' => 15,
      'site' => 16, 'landscape' => 17, 'equipment' => 18, 'foundation' => 19,
      'structure' => 20, 'room_boundary' => 21, 'exterior_wall' => 22, 'interior_wall' => 23
    }.freeze
    SEMANTIC_ROLE_NAMES = {
      0 => 'unknown', 1 => 'wall', 2 => 'floor', 3 => 'ceiling', 4 => 'roof',
      5 => 'opening', 6 => 'window', 7 => 'door', 8 => 'railing', 9 => 'room',
      10 => 'facade', 11 => 'column', 12 => 'beam', 13 => 'stair',
      14 => 'furniture', 15 => 'fixture', 16 => 'site', 17 => 'landscape',
      18 => 'equipment', 19 => 'foundation', 20 => 'structure', 21 => 'room_boundary',
      22 => 'exterior_wall', 23 => 'interior_wall'
    }.freeze
    TEXTURE_MEDIA = { binary: 0, png: 1, jpeg: 2, webp: 3, avif: 4, ktx2: 5 }.freeze
    TEXTURE_MEDIA_NAMES = TEXTURE_MEDIA.each_with_object({}) { |(name, value), result| result[value] = name }.freeze

    HEADER_PACK = 'a8vvVVVQ<'.freeze
    DIRECTORY_PACK = 'vCCQ<Q<Q<VVV'.freeze
    COMPACT_DIRECTORY_PACK = 'vCCVVVVV'.freeze

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

      def pack(sections, flags: PROFILE_PRODUCTION, compact_directory: true, version_minor: nil, compression_level: Zlib::BEST_COMPRESSION, checkpoint: nil)
        compact = !!compact_directory
        minor = version_minor.nil? ? (compact ? VERSION_MINOR : 0) : Integer(version_minor)
        if compact && minor < 1
          raise ArgumentError, 'compact directory requires BOMC 1.1 or newer.'
        end
        if !compact && minor != 0
          raise ArgumentError, 'fixed directory is only defined for BOMC 1.0.'
        end
        directory_entry_bytes = compact ? COMPACT_DIRECTORY_ENTRY_BYTES : DIRECTORY_ENTRY_BYTES
        header_flags = Integer(flags)
        header_flags |= FLAG_COMPACT_DIRECTORY if compact
        ordered = Array(sections).each_with_index.sort_by do |section, index|
          [Integer(section.fetch(:type)), index]
        end.map(&:first)
        prepared = ordered.each_with_index.map do |section, index|
          prepared_section = prepare_section(section, compression_level)
          if checkpoint
            checkpoint.call(
              stage: :compress_sections,
              processed: index + 1,
              total: ordered.length,
              candidate_bytes: prepared_section[:stored_bytes].bytesize
            )
          end
          prepared_section
        end
        directory_offset = HEADER_BYTES
        cursor = Binary.align(directory_offset + prepared.length * directory_entry_bytes)
        prepared.each do |section|
          cursor = Binary.align(cursor)
          section[:offset] = cursor
          cursor += section[:stored_bytes].bytesize
        end

        header = [
          MAGIC,
          VERSION_MAJOR,
          minor,
          ENDIAN_MARKER,
          header_flags,
          prepared.length,
          directory_offset
        ].pack(HEADER_PACK)
        raise 'BOMC internal: header byte count mismatch.' unless header.bytesize == HEADER_BYTES

        directory = +''.b
        prepared.each do |section|
          values = [
            section[:type], section[:codec], section[:flags], section[:offset],
            section[:stored_bytes].bytesize, section[:raw_bytes].bytesize,
            section[:count], Zlib.crc32(section[:stored_bytes])
          ]
          if compact
            if values[3, 4].any? { |value| value > 0xffff_ffff }
              raise ArgumentError, 'compact BOMC directory exceeds its uint32 range.'
            end
            directory << values.pack(COMPACT_DIRECTORY_PACK)
          else
            directory << (values + [0]).pack(DIRECTORY_PACK)
          end
        end
        unless directory.bytesize == prepared.length * directory_entry_bytes
          raise 'BOMC internal: directory byte count mismatch.'
        end

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
        unless major == VERSION_MAJOR && minor >= 0 && minor <= VERSION_MINOR
          raise "BOMC invalid: unsupported version #{major}.#{minor}."
        end
        raise 'BOMC invalid: unsupported byte order.' unless endian == ENDIAN_MARKER
        raise 'BOMC invalid: directory precedes fixed header.' if directory_offset < HEADER_BYTES

        compact = (flags & FLAG_COMPACT_DIRECTORY) != 0
        if compact && minor < 1
          raise 'BOMC invalid: compact directory flag requires BOMC 1.1.'
        end
        directory_entry_bytes = compact ? COMPACT_DIRECTORY_ENTRY_BYTES : DIRECTORY_ENTRY_BYTES
        directory_pack = compact ? COMPACT_DIRECTORY_PACK : DIRECTORY_PACK
        directory_size = section_count * directory_entry_bytes
        directory_end = directory_offset + directory_size
        raise 'BOMC invalid: directory outside file.' if directory_end > content.bytesize

        descriptors = section_count.times.map do |index|
          entry_offset = directory_offset + index * directory_entry_bytes
          values = content.byteslice(entry_offset, directory_entry_bytes).unpack(directory_pack)
          type, codec, section_flags, offset, stored_size, raw_size, count, crc32 = values[0, 8]
          reserved = values[8]
          if !compact && !reserved.zero?
            raise "BOMC invalid: section #{index} reserved field."
          end
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
            directory_entry_bytes: directory_entry_bytes,
            endianness: :little,
            flags: flags,
            section_count: section_count,
            directory_offset: directory_offset
          },
          sections: descriptors
        }
      end

      def prepare_section(section, compression_level)
        raw = section.fetch(:bytes).b
        stored = raw
        codec = CODEC_STORE
        if section[:compress]
          candidate = Zlib::Deflate.deflate(raw, Integer(compression_level))
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
