# frozen_string_literal: true

require 'zlib'

module BOMEngine
  # Lossless PNG repacker used only as another Exact texture candidate.
  # It preserves all non-IDAT chunks and image samples exactly, while allowing
  # a stronger DEFLATE pass and, for bounded images, adaptive row filtering.
  module BOMCPngOptimizer
    SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
    MAX_PIXELS = 32_000_000
    ADAPTIVE_FILTER_PIXELS = 4_000_000
    module_function

    def optimize(source_path:, output_path:, checkpoint: nil)
      bytes = File.binread(source_path)
      parsed = parse(bytes)
      return nil unless parsed

      original_raw = Zlib::Inflate.inflate(parsed[:idat])
      expected = parsed[:height] * (parsed[:stride] + 1)
      return nil unless original_raw.bytesize == expected

      candidates = [{ label: :redeflate_existing_filters, raw: original_raw }]
      if parsed[:pixels] <= ADAPTIVE_FILTER_PIXELS
        pixels = unfilter(original_raw, parsed[:width], parsed[:height], parsed[:bpp], checkpoint)
        adaptive = refilter_adaptive(pixels, parsed[:width], parsed[:height], parsed[:bpp], checkpoint)
        candidates << { label: :adaptive_filters, raw: adaptive }
      end

      best = candidates.map do |candidate|
        compressed = deflate_best(candidate[:raw])
        candidate.merge(compressed: compressed)
      end.min_by { |candidate| candidate[:compressed].bytesize }

      rebuilt = rebuild(parsed[:chunks], best[:compressed])
      return nil unless rebuilt.bytesize < bytes.bytesize

      File.binwrite(output_path, rebuilt)
      {
        path: output_path,
        bytes: rebuilt.bytesize,
        source_bytes: bytes.bytesize,
        savings_bytes: bytes.bytesize - rebuilt.bytesize,
        strategy: best[:label],
        adaptive_filters: best[:label] == :adaptive_filters
      }
    rescue Zlib::Error, ArgumentError, TypeError, IOError, SystemCallError
      nil
    end

    def parse(bytes)
      return nil unless bytes.start_with?(SIGNATURE)
      offset = SIGNATURE.bytesize
      chunks = []
      idat = +''.b
      ihdr = nil
      seen_iend = false

      while offset + 12 <= bytes.bytesize
        length = bytes.byteslice(offset,4).unpack1('N')
        return nil if length > bytes.bytesize || offset + 12 + length > bytes.bytesize
        type = bytes.byteslice(offset+4,4)
        data = bytes.byteslice(offset+8,length)
        crc = bytes.byteslice(offset+8+length,4).unpack1('N')
        return nil unless Zlib.crc32(type + data) == crc
        raw = bytes.byteslice(offset,12+length)
        chunks << { type: type, data: data, raw: raw }
        ihdr = data if type == 'IHDR'
        idat << data if type == 'IDAT'
        seen_iend = true if type == 'IEND'
        offset += 12 + length
        break if seen_iend
      end
      return nil unless seen_iend && offset == bytes.bytesize && ihdr && ihdr.bytesize == 13 && !idat.empty?

      width,height,depth,color,compression,filter,interlace = ihdr.unpack('NNC5')
      return nil unless width > 0 && height > 0 && width * height <= MAX_PIXELS
      return nil unless depth == 8 && [2,6].include?(color) && compression == 0 && filter == 0 && interlace == 0
      bpp = color == 6 ? 4 : 3
      { chunks: chunks, idat: idat, width: width, height: height, pixels: width*height,
        bpp: bpp, stride: width*bpp }
    end
    private_class_method :parse

    def unfilter(raw, width, height, bpp, checkpoint)
      stride = width * bpp
      previous = Array.new(stride, 0)
      rows = Array.new(height)
      height.times do |y|
        base = y * (stride + 1)
        filter = raw.getbyte(base)
        # ImageRep PNGs with filter=0 need no Ruby per-byte inverse filter.
        # Keep the exact decoded samples while avoiding millions of redundant
        # predictor operations on large unfiltered image rows.
        if filter == 0
          rows[y] = raw.byteslice(base + 1, stride)
          previous = rows[y].bytes
          checkpoint.call((y+1)*width, width*height) if checkpoint && ((y & 31).zero? || y+1 == height)
          next
        end
        row = raw.byteslice(base + 1, stride).bytes
        row.each_index do |x|
          left = x >= bpp ? row[x-bpp] : 0
          up = previous[x]
          upper_left = x >= bpp ? previous[x-bpp] : 0
          predictor = case filter
                      when 0 then 0
                      when 1 then left
                      when 2 then up
                      when 3 then (left + up) / 2
                      when 4 then paeth(left, up, upper_left)
                      else raise ArgumentError, 'Unsupported PNG row filter'
                      end
          row[x] = (row[x] + predictor) & 255
        end
        rows[y] = row.pack('C*')
        previous = row
        checkpoint.call((y+1)*width, width*height) if checkpoint && ((y & 31).zero? || y+1 == height)
      end
      rows
    end
    private_class_method :unfilter

    def refilter_adaptive(rows, width, height, bpp, checkpoint)
      stride = width * bpp
      previous = nil
      out = +''.b
      rows.each_with_index do |row_string,y|
        row = row_string.bytes
        previous_bytes = previous ? previous.bytes : nil
        filtered = [row, Array.new(stride), Array.new(stride), Array.new(stride), Array.new(stride)]
        scores = [0,0,0,0,0]
        x = 0
        while x < stride
          value = row[x]
          left = x >= bpp ? row[x-bpp] : 0
          up = previous_bytes ? previous_bytes[x] : 0
          upper_left = previous_bytes && x >= bpp ? previous_bytes[x-bpp] : 0
          b1=(value-left)&255
          b2=(value-up)&255
          b3=(value-((left+up)/2))&255
          b4=(value-paeth(left,up,upper_left))&255
          filtered[1][x]=b1; filtered[2][x]=b2
          filtered[3][x]=b3; filtered[4][x]=b4
          scores[0]+=value<128 ? value : 256-value
          scores[1]+=b1<128 ? b1 : 256-b1
          scores[2]+=b2<128 ? b2 : 256-b2
          scores[3]+=b3<128 ? b3 : 256-b3
          scores[4]+=b4<128 ? b4 : 256-b4
          x+=1
        end
        best_type=(0..4).min_by { |type| [scores[type],type] }
        best_bytes=filtered[best_type]

        out << best_type.chr << best_bytes.pack('C*')
        previous = row_string
        checkpoint.call((y+1)*width, width*height) if checkpoint && ((y & 31).zero? || y+1 == height)
      end
      out
    end
    private_class_method :refilter_adaptive

    def paeth(a,b,c)
      p = a + b - c
      pa = (p-a).abs
      pb = (p-b).abs
      pc = (p-c).abs
      pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
    end
    private_class_method :paeth

    def deflate_best(raw)
      results = []
      [Zlib::DEFAULT_STRATEGY, (Zlib.const_defined?(:FILTERED) ? Zlib::FILTERED : Zlib::DEFAULT_STRATEGY)].uniq.each do |strategy|
        stream = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, Zlib::MAX_WBITS, Zlib::DEF_MEM_LEVEL, strategy)
        begin
          results << stream.deflate(raw, Zlib::FINISH)
        ensure
          stream.close rescue nil
        end
      end
      results.min_by(&:bytesize)
    end
    private_class_method :deflate_best

    def rebuild(chunks, compressed)
      output = SIGNATURE.dup
      wrote_idat = false
      chunks.each do |chunk|
        if chunk[:type] == 'IDAT'
          next if wrote_idat
          output << png_chunk('IDAT', compressed)
          wrote_idat = true
        else
          output << chunk[:raw]
        end
      end
      output
    end
    private_class_method :rebuild

    def png_chunk(type,data)
      [data.bytesize].pack('N') + type.b + data + [Zlib.crc32(type.b + data)].pack('N')
    end
    private_class_method :png_chunk
  end
end
