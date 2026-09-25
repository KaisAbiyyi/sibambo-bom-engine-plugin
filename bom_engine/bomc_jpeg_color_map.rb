# frozen_string_literal: true
require 'digest'

module BOMEngine
  # Experimental standalone representation. Never advertise these bytes as JPEG.
  # v1: opaque top-down RGBA8; exact RGB-key dictionary; no color management.
  module BOMCJpegColorMap
    MAGIC = "BOMJCM\r\n".b.freeze
    HEADER_BYTES = 128
    MAX_PIXELS = 32_000_000
    MAX_ENTRIES = 262_144
    MAX_JPEG_BYTES = 32 * 1024 * 1024
    module_function

    # No JPEG re-encoding. The caller MUST decode these normalized bytes and use
    # that frame as the mapping base; stripping metadata is not itself pixel proof.
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
      expected = width * height * 4
      unless base_rgba.is_a?(String) && target_rgba.is_a?(String) && base_rgba.bytesize == expected && target_rgba.bytesize == expected
        raise ArgumentError, 'Exact color-map frame length'
      end
      table = {}
      offset = 0
      while offset < expected
        checkpoint.call(offset/4, width*height) if checkpoint
        # Bounded integer blocks avoid allocating millions of four-byte Strings
        # for repeated pixels; alpha and conflict checks still cover every pixel.
        length = [131_072,expected-offset].min
        base_pixels = base_rgba.byteslice(offset,length).unpack('N*')
        target_pixels = target_rgba.byteslice(offset,length).unpack('N*')
        base_pixels.each_with_index do |pixel,index|
          value = target_pixels[index]
          return nil unless (pixel & 255) == 255 && (value & 255) == 255
          key = pixel >> 8
          previous = table[key]
          return nil if previous && previous != value
          table[key] = value unless previous
          return nil if table.length > MAX_ENTRIES
        end
        offset += length
      end
      dictionary = +''.b
      table.keys.sort.each { |key| dictionary << [key >> 16, (key >> 8) & 255, key & 255].pack('C*') << [table[key]].pack('N') }
      bytes = MAGIC + [1,0,0,1].pack('C*') + [width,height,table.length,jpeg.bytesize,0].pack('V5') +
        Digest::SHA256.digest(jpeg) + Digest::SHA256.digest(base_rgba) + Digest::SHA256.digest(target_rgba) + jpeg.b + dictionary
      # Verify the serialized candidate, not just the in-memory map construction.
      raise ArgumentError, 'Exact color-map reconstruction differs' unless reconstruct(bytes,base_rgba,&checkpoint) == target_rgba.b
      bytes
    end

    def parse(bytes)
      raise ArgumentError, 'Exact color-map length' unless bytes.is_a?(String) && bytes.bytesize >= HEADER_BYTES
      raise ArgumentError, 'Exact color-map header' unless bytes.byteslice(0,8) == MAGIC && bytes.byteslice(8,4).unpack('C4') == [1,0,0,1]
      width,height,count,jpeg_length,reserved = bytes.byteslice(12,20).unpack('V5')
      raise ArgumentError, 'Exact color-map header' unless reserved.zero?
      validate_dimensions(width,height)
      unless count > 0 && count <= MAX_ENTRIES && count <= width*height && jpeg_length > 0 && jpeg_length <= MAX_JPEG_BYTES
        raise ArgumentError, 'Exact color-map resource bounds'
      end
      raise ArgumentError, 'Exact color-map length' unless bytes.bytesize == HEADER_BYTES + jpeg_length + count*7
      jpeg = bytes.byteslice(HEADER_BYTES,jpeg_length).b
      raise ArgumentError, 'Exact color-map JPEG hash' unless Digest::SHA256.digest(jpeg) == bytes.byteslice(32,32).b
      validate_jpeg(jpeg,width,height)
      dictionary = bytes.byteslice(HEADER_BYTES+jpeg_length,count*7).b
      table = {}
      previous = -1
      count.times do |index|
        offset = index*7
        key = dictionary.getbyte(offset)*65_536 + dictionary.getbyte(offset+1)*256 + dictionary.getbyte(offset+2)
        raise ArgumentError, 'Exact color-map keys must be strictly sorted' if key <= previous
        raise ArgumentError, 'Exact color-map v1 alpha unsupported' unless dictionary.getbyte(offset+6) == 255
        table[key] = dictionary.byteslice(offset+3,4)
        previous = key
      end
      {width:width,height:height,jpeg:jpeg,table:table,base_hash:bytes.byteslice(64,32).b,output_hash:bytes.byteslice(96,32).b}
    end

    def reconstruct(bytes, base_rgba, &checkpoint)
      map = parse(bytes)
      raise ArgumentError, 'Exact color-map base length' unless base_rgba.is_a?(String) && base_rgba.bytesize == map[:width]*map[:height]*4
      raise ArgumentError, 'Exact color-map base pixel hash' unless Digest::SHA256.digest(base_rgba) == map[:base_hash]
      out = +''.b
      offset = 0
      while offset < base_rgba.bytesize
        checkpoint.call(offset/4,map[:width]*map[:height]) if checkpoint && (offset % 131_072).zero?
        raise ArgumentError, 'Exact color-map base alpha unsupported' unless base_rgba.getbyte(offset+3) == 255
        key = base_rgba.getbyte(offset)*65_536 + base_rgba.getbyte(offset+1)*256 + base_rgba.getbyte(offset+2)
        value = map[:table][key]
        raise ArgumentError, 'Exact color-map missing dictionary key' unless value
        out << value
        offset += 4
      end
      raise ArgumentError, 'Exact color-map output pixel hash' unless Digest::SHA256.digest(out) == map[:output_hash]
      out
    end
  end
end
