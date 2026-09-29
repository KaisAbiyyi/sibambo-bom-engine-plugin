# frozen_string_literal: true
require 'digest'
require 'zlib'

module BOMEngine
  # Exact JPEG-backed texture representation.
  # v1: opaque top-down RGBA8; exact correction payload; no color management.
  #
  # Correction codecs:
  #   0 = stored RGB->RGBA dictionary (legacy v1)
  #   1 = zlib-deflated RGB->RGBA dictionary
  #   2 = zlib-deflated per-pixel RGBA XOR residual
  module BOMCJpegColorMap
    MAGIC = "BOMJCM\r\n".b.freeze
    HEADER_BYTES = 128
    MAX_PIXELS = 32_000_000
    MAX_ENTRIES = 262_144
    MAX_JPEG_BYTES = 32 * 1024 * 1024
    DICTIONARY_STORED = 0
    DICTIONARY_DEFLATE = 1
    XOR_RESIDUAL_DEFLATE = 2
    module_function

    # No JPEG re-encoding. The caller MUST decode these normalized bytes and use
    # that frame as the correction base; stripping metadata is not pixel proof.
    def normalize_jpeg(jpeg, width, height)
      validate_dimensions(width,height)
      raise ArgumentError, 'Exact color-map invalid JPEG' unless jpeg.is_a?(String) && jpeg.bytesize <= MAX_JPEG_BYTES && jpeg.byteslice(0,2) == "\xff\xd8".b
      out = jpeg.byteslice(0,2).b
      cursor = 2
      while cursor < jpeg.bytesize
        start = cursor
        raise ArgumentError, 'Exact color-map JPEG marker' unless jpeg.getbyte(cursor) == 255
        cursor += 1
        cursor += 1 while jpeg.getbyte(cursor) == 255
        marker = jpeg.getbyte(cursor)
        cursor += 1
        raise ArgumentError, 'Exact color-map JPEG length' if cursor+2 > jpeg.bytesize
        length = jpeg.byteslice(cursor,2).unpack1('n')
        raise ArgumentError, 'Exact color-map JPEG length' if length < 2 || cursor+length > jpeg.bytesize
        if marker == 0xda
          out << jpeg.byteslice(start,jpeg.bytesize-start)
          validate_jpeg(out,width,height)
          return out
        end
        out << jpeg.byteslice(start,cursor+length-start) unless marker && (0xe1..0xef).cover?(marker)
        cursor += length
      end
      raise ArgumentError, 'Exact color-map truncated JPEG'
    end

    def validate_dimensions(width, height)
      unless width.is_a?(Integer) && height.is_a?(Integer) && width > 0 && height > 0 &&
          width <= 16_384 && height <= 16_384 && width * height <= MAX_PIXELS
        raise ArgumentError, 'Exact color-map resource bounds'
      end
    end

    def validate_jpeg(jpeg, width, height)
      raise ArgumentError, 'Exact color-map invalid JPEG' unless jpeg.is_a?(String) &&
        jpeg.bytesize <= MAX_JPEG_BYTES && jpeg.byteslice(0,2) == "\xff\xd8".b
      cursor = 2
      frame = scan = entropy = false
      while cursor < jpeg.bytesize
        if entropy && jpeg.getbyte(cursor) != 255
          cursor += 1
          next
        end
        raise ArgumentError, 'Exact color-map JPEG marker' unless jpeg.getbyte(cursor) == 255
        cursor += 1
        cursor += 1 while jpeg.getbyte(cursor) == 255
        marker = jpeg.getbyte(cursor)
        cursor += 1
        next if entropy && marker && (marker == 0 || (0xd0..0xd7).cover?(marker))
        entropy = false
        if marker == 0xd9
          raise ArgumentError, 'Exact color-map JPEG ending' unless frame && scan && cursor == jpeg.bytesize
          return true
        end
        raise ArgumentError, 'Exact color-map JPEG metadata unsupported' if marker && (0xe1..0xef).cover?(marker)
        raise ArgumentError, 'Exact color-map JPEG length' if cursor + 2 > jpeg.bytesize
        length = jpeg.byteslice(cursor,2).unpack1('n')
        raise ArgumentError, 'Exact color-map JPEG length' if length < 2 || cursor + length > jpeg.bytesize
        if [0xc0,0xc2].include?(marker)
          raise ArgumentError, 'Exact color-map JPEG frame' if frame || length < 8 || jpeg.getbyte(cursor+2) != 8
          components = jpeg.getbyte(cursor+7)
          raise ArgumentError, 'Exact color-map JPEG components' unless [1,3].include?(components) && length == 8 + components*3
          raise ArgumentError, 'Exact color-map JPEG dimensions' unless jpeg.byteslice(cursor+3,4).unpack('n2') == [height,width]
          frame = true
        elsif marker == 0xda
          raise ArgumentError, 'Exact color-map JPEG scan' unless frame && length >= 6 && length == 6 + jpeg.getbyte(cursor+2)*2
          scan = entropy = true
        elsif ![0xc4,0xdb,0xdd,0xe0,0xfe].include?(marker)
          raise ArgumentError, 'Exact color-map unsupported JPEG marker'
        end
        cursor += length
      end
      raise ArgumentError, 'Exact color-map truncated JPEG'
    end

    def encode(jpeg:, base_rgba:, target_rgba:, width:, height:, &checkpoint)
      validate_dimensions(width,height)
      validate_jpeg(jpeg,width,height)
      pixels = width * height
      expected = pixels * 4
      unless base_rgba.is_a?(String) && target_rgba.is_a?(String) &&
          base_rgba.bytesize == expected && target_rgba.bytesize == expected
        raise ArgumentError, 'Exact color-map frame length'
      end

      table = {}
      table_valid = true
      residual_stream = Zlib::Deflate.new(Zlib::BEST_COMPRESSION)
      residual = +''.b
      offset = 0
      begin
        while offset < expected
          checkpoint.call(offset/4, pixels) if checkpoint
          length = [131_072, expected-offset].min
          length -= length % 4
          base_pixels = base_rgba.byteslice(offset,length).unpack('N*')
          target_pixels = target_rgba.byteslice(offset,length).unpack('N*')
          base_pixels.each_index do |index|
            pixel = base_pixels[index]
            value = target_pixels[index]
            return nil unless (pixel & 255) == 255 && (value & 255) == 255

            if table_valid
              key = pixel >> 8
              previous = table[key]
              if previous && previous != value
                table_valid = false
                table = nil
              elsif previous.nil?
                table[key] = value
                if table.length > MAX_ENTRIES
                  table_valid = false
                  table = nil
                end
              end
            end

            base_pixels[index] = pixel ^ value
          end
          residual << residual_stream.deflate(base_pixels.pack('N*'), Zlib::NO_FLUSH)
          offset += length
        end
        residual << residual_stream.finish
      ensure
        residual_stream.close rescue nil
      end

      candidates = []
      if table_valid && table && !table.empty?
        dictionary = +''.b
        table.keys.sort.each do |key|
          dictionary << [key >> 16, (key >> 8) & 255, key & 255].pack('C*') << [table[key]].pack('N')
        end
        candidates << serialize(
          jpeg: jpeg, base_rgba: base_rgba, target_rgba: target_rgba,
          width: width, height: height, count: table.length,
          codec: DICTIONARY_STORED, correction: dictionary
        )
        compressed_dictionary = Zlib::Deflate.deflate(dictionary, Zlib::BEST_COMPRESSION)
        if compressed_dictionary.bytesize < dictionary.bytesize
          candidates << serialize(
            jpeg: jpeg, base_rgba: base_rgba, target_rgba: target_rgba,
            width: width, height: height, count: table.length,
            codec: DICTIONARY_DEFLATE, correction: compressed_dictionary
          )
        end
      end

      candidates << serialize(
        jpeg: jpeg, base_rgba: base_rgba, target_rgba: target_rgba,
        width: width, height: height, count: pixels,
        codec: XOR_RESIDUAL_DEFLATE, correction: residual
      )

      bytes = candidates.min_by(&:bytesize)
      raise ArgumentError, 'Exact color-map reconstruction differs' unless reconstruct(bytes,base_rgba,&checkpoint) == target_rgba.b
      bytes
    end

    def serialize(jpeg:, base_rgba:, target_rgba:, width:, height:, count:, codec:, correction:)
      stored_length = codec == DICTIONARY_STORED ? 0 : correction.bytesize
      MAGIC + [1,0,codec,1].pack('C*') +
        [width,height,count,jpeg.bytesize,stored_length].pack('V5') +
        Digest::SHA256.digest(jpeg) + Digest::SHA256.digest(base_rgba) +
        Digest::SHA256.digest(target_rgba) + jpeg.b + correction.b
    end
    private_class_method :serialize

    def inflate_exact(bytes, expected)
      raise ArgumentError, 'Exact color-map correction bounds' if expected <= 0 || expected > MAX_PIXELS * 4
      raise ArgumentError, 'Exact color-map correction bounds' if bytes.bytesize > expected + 65_536
      inflated = Zlib::Inflate.inflate(bytes)
      raise ArgumentError, 'Exact color-map correction length' unless inflated.bytesize == expected
      inflated.b
    rescue Zlib::Error => error
      raise ArgumentError, "Exact color-map correction deflate: #{error.message}"
    end
    private_class_method :inflate_exact

    def parse(bytes)
      raise ArgumentError, 'Exact color-map length' unless bytes.is_a?(String) && bytes.bytesize >= HEADER_BYTES
      raise ArgumentError, 'Exact color-map header' unless bytes.byteslice(0,8) == MAGIC
      version, flags, codec, layout = bytes.byteslice(8,4).unpack('C4')
      unless version == 1 && flags.zero? && [DICTIONARY_STORED, DICTIONARY_DEFLATE, XOR_RESIDUAL_DEFLATE].include?(codec) && layout == 1
        raise ArgumentError, 'Exact color-map header'
      end

      width,height,count,jpeg_length,correction_length = bytes.byteslice(12,20).unpack('V5')
      validate_dimensions(width,height)
      pixels = width * height
      raise ArgumentError, 'Exact color-map resource bounds' unless jpeg_length > 0 && jpeg_length <= MAX_JPEG_BYTES

      expected_correction = if codec == XOR_RESIDUAL_DEFLATE
                              raise ArgumentError, 'Exact color-map residual count' unless count == pixels
                              pixels * 4
                            else
                              unless count > 0 && count <= MAX_ENTRIES && count <= pixels
                                raise ArgumentError, 'Exact color-map resource bounds'
                              end
                              count * 7
                            end

      payload_length = codec == DICTIONARY_STORED ? expected_correction : correction_length
      if codec == DICTIONARY_STORED
        raise ArgumentError, 'Exact color-map header' unless correction_length.zero?
      else
        raise ArgumentError, 'Exact color-map correction bounds' unless correction_length > 0 && correction_length <= expected_correction + 65_536
      end
      raise ArgumentError, 'Exact color-map length' unless bytes.bytesize == HEADER_BYTES + jpeg_length + payload_length

      jpeg = bytes.byteslice(HEADER_BYTES,jpeg_length).b
      raise ArgumentError, 'Exact color-map JPEG hash' unless Digest::SHA256.digest(jpeg) == bytes.byteslice(32,32).b
      validate_jpeg(jpeg,width,height)
      encoded_correction = bytes.byteslice(HEADER_BYTES+jpeg_length,payload_length).b
      correction = codec == DICTIONARY_STORED ? encoded_correction : inflate_exact(encoded_correction, expected_correction)

      result = {
        width: width, height: height, jpeg: jpeg, codec: codec,
        base_hash: bytes.byteslice(64,32).b, output_hash: bytes.byteslice(96,32).b
      }
      if codec == XOR_RESIDUAL_DEFLATE
        result[:residual] = correction
        return result
      end

      table = {}
      previous = -1
      count.times do |index|
        row = index*7
        key = correction.getbyte(row)*65_536 + correction.getbyte(row+1)*256 + correction.getbyte(row+2)
        raise ArgumentError, 'Exact color-map keys must be strictly sorted' if key <= previous
        raise ArgumentError, 'Exact color-map v1 alpha unsupported' unless correction.getbyte(row+6) == 255
        table[key] = correction.byteslice(row+3,4)
        previous = key
      end
      result[:table] = table
      result
    end

    def reconstruct(bytes, base_rgba, &checkpoint)
      map = parse(bytes)
      pixels = map[:width] * map[:height]
      raise ArgumentError, 'Exact color-map base length' unless base_rgba.is_a?(String) && base_rgba.bytesize == pixels*4
      raise ArgumentError, 'Exact color-map base pixel hash' unless Digest::SHA256.digest(base_rgba) == map[:base_hash]

      out = +''.b
      if map[:codec] == XOR_RESIDUAL_DEFLATE
        offset = 0
        while offset < base_rgba.bytesize
          checkpoint.call(offset/4,pixels) if checkpoint && (offset % 131_072).zero?
          length = [131_072,base_rgba.bytesize-offset].min
          length -= length % 4
          base_values = base_rgba.byteslice(offset,length).unpack('N*')
          residual_values = map[:residual].byteslice(offset,length).unpack('N*')
          base_values.each_index do |index|
            raise ArgumentError, 'Exact color-map base alpha unsupported' unless (base_values[index] & 255) == 255
            base_values[index] ^= residual_values[index]
            raise ArgumentError, 'Exact color-map output alpha unsupported' unless (base_values[index] & 255) == 255
          end
          out << base_values.pack('N*')
          offset += length
        end
      else
        offset = 0
        while offset < base_rgba.bytesize
          checkpoint.call(offset/4,pixels) if checkpoint && (offset % 131_072).zero?
          raise ArgumentError, 'Exact color-map base alpha unsupported' unless base_rgba.getbyte(offset+3) == 255
          key = base_rgba.getbyte(offset)*65_536 + base_rgba.getbyte(offset+1)*256 + base_rgba.getbyte(offset+2)
          value = map[:table][key]
          raise ArgumentError, 'Exact color-map missing dictionary key' unless value
          out << value
          offset += 4
        end
      end
      raise ArgumentError, 'Exact color-map output pixel hash' unless Digest::SHA256.digest(out) == map[:output_hash]
      out
    end
  end
end
