# frozen_string_literal: true

require 'zlib'
require_relative 'bomc_png_worker'

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

      original_raw = inflate_chunks(parsed[:idat], checkpoint)
      expected = parsed[:height] * (parsed[:stride] + 1)
      return nil unless original_raw.bytesize == expected

      candidates = [{ label: :redeflate_existing_filters, raw: original_raw }]
      filter_backend = :ruby
      worker_error = nil
      if parsed[:pixels] <= ADAPTIVE_FILTER_PIXELS
        adaptive = nil
        if parsed[:pixels] >= 262_144 && BOMCPngWorker.available?
          begin
            adaptive = BOMCPngWorker.filter(raw: original_raw, width: parsed[:width], height: parsed[:height],
              bpp: parsed[:bpp], directory: File.dirname(output_path), checkpoint: checkpoint)
            filter_backend = :windows_worker if adaptive
          rescue IOError, SystemCallError => error
            # An unavailable optional accelerator must not remove a candidate.
            worker_error = "#{error.class}: #{error.message}"
          end
        end
        unless adaptive
          pixels = unfilter(original_raw, parsed[:width], parsed[:height], parsed[:bpp], checkpoint)
          adaptive = refilter_adaptive(pixels, parsed[:width], parsed[:height], parsed[:bpp], checkpoint)
        end
        candidates << { label: :adaptive_filters, raw: adaptive }
      end

      best = compress_candidates(candidates, checkpoint).min_by { |candidate| candidate[:compressed].bytesize }

      rebuilt = rebuild(parsed[:chunks], best[:compressed])
      return nil unless rebuilt.bytesize < bytes.bytesize

      File.binwrite(output_path, rebuilt)
      {
        path: output_path,
        bytes: rebuilt.bytesize,
        source_bytes: bytes.bytesize,
        savings_bytes: bytes.bytesize - rebuilt.bytesize,
        strategy: best[:label],
        adaptive_filters: best[:label] == :adaptive_filters,
        filter_backend: filter_backend,
        worker_error: worker_error
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
          checkpoint.call((y+1)*width, width*height) if checkpoint
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
        checkpoint.call((y+1)*width, width*height) if checkpoint
      end
      rows
    end
    private_class_method :unfilter

    def refilter_adaptive(rows, width, height, bpp, checkpoint)
      stride = width * bpp
      previous = nil
      previous_bytes = nil
      out = +''.b
      # Repeating row pairs are common in flat/pattern textures. Keep a small,
      # invocation-local cache of exact inputs and their exact filtered output.
      row_cache = {}
      cache_bytes = 0
      rows.each_with_index do |row_string, y|
        key = [previous, row_string]
        encoded = row_cache[key]
        unless encoded
          row = row_string.bytes
          s0 = s1 = s2 = s3 = s4 = 0
          f1, f2, f3, f4 = Array.new(4) { Array.new(stride) }
          x = 0
          while x < stride
            value = row[x]
            left = x >= bpp ? row[x-bpp] : 0
            up = previous_bytes ? previous_bytes[x] : 0
            upper_left = previous_bytes && x >= bpp ? previous_bytes[x-bpp] : 0
            # Same Paeth distances/tie ordering, without the per-byte method
            # call; scalar scores avoid repeated Array updates in the hot loop.
            pa = (up-upper_left).abs
            pb = (left-upper_left).abs
            pc = (left+up-2*upper_left).abs
            predictor = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upper_left)
            b1 = (value-left)&255
            b2 = (value-up)&255
            b3 = (value-((left+up)/2))&255
            b4 = (value-predictor)&255
            f1[x] = b1; f2[x] = b2; f3[x] = b3; f4[x] = b4
            s0 += value < 128 ? value : 256-value
            s1 += b1 < 128 ? b1 : 256-b1
            s2 += b2 < 128 ? b2 : 256-b2
            s3 += b3 < 128 ? b3 : 256-b3
            s4 += b4 < 128 ? b4 : 256-b4
            x += 1
            checkpoint.call(y*width+x/bpp, width*height) if checkpoint && (x & 4095).zero?
          end
          scores = [s0,s1,s2,s3,s4]
          best_type = (0..4).min_by { |type| [scores[type],type] }
          if best_type.zero?
            encoded = "\0".b + row_string
          else
            filtered = [row, f1, f2, f3, f4][best_type]
            encoded = best_type.chr.b + filtered.pack('C*')
          end
          if row_cache.length < 32 && cache_bytes + stride*3 <= 2_097_152
            row_cache[key] = encoded
            cache_bytes += stride*3
          end
        end
        out << encoded
        previous = row_string
        previous_bytes = row_string.bytes
        checkpoint.call((y+1)*width, width*height) if checkpoint
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

    def inflate_chunks(bytes, checkpoint)
      stream = Zlib::Inflate.new
      begin
        output = +''.b
        offset = 0
        while offset < bytes.bytesize
          checkpoint.call(0, bytes.bytesize, :png_inflate) if checkpoint
          output << stream.inflate(bytes.byteslice(offset, 32_768))
          offset += 32_768
        end
        output << stream.finish
        output
      ensure
        stream.close
      end
    end
    private_class_method :inflate_chunks

    # Zlib's native compression releases Ruby's GVL. Four bounded, owned
    # workers evaluate the SAME raw/filter/strategy combinations concurrently.
    # They see detached immutable strings only, never SDK objects or callbacks.
    # The caller alone polls/yields and owns cancellation and worker cleanup.
    def compress_candidates(candidates, checkpoint)
      return candidates.map { |candidate| candidate.merge(compressed: deflate_best(candidate[:raw], checkpoint)) } if
        candidates.all? { |candidate| candidate[:raw].bytesize < 1_048_576 }

      strategies = [Zlib::DEFAULT_STRATEGY, Zlib::FILTERED].uniq
      results = Array.new(candidates.length * strategies.length)
      errors = Array.new(results.length)
      cancelled = false
      threads = []
      candidates.each_with_index do |candidate, candidate_index|
        raw = candidate[:raw].freeze
        strategies.each_with_index do |strategy, strategy_index|
          slot = candidate_index * strategies.length + strategy_index
          threads << Thread.new do
            stream = nil
            begin
              stream = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, Zlib::MAX_WBITS, Zlib::DEF_MEM_LEVEL, strategy)
              compressed = +''.b; offset = 0
              while offset < raw.bytesize
                break if cancelled
                compressed << stream.deflate(raw.byteslice(offset, 32_768), Zlib::NO_FLUSH)
                offset += 32_768
              end
              results[slot] = compressed << stream.finish unless cancelled
            rescue StandardError => error
              errors[slot] = error
            ensure
              stream.close if stream
            end
          end
        end
      end
      while threads.any?(&:alive?)
        checkpoint.call(0, 0, :png_deflate_workers) if checkpoint
        sleep(0.005)
      end
      raise errors.compact.first if errors.any?
      candidates.each_with_index.map do |candidate, index|
        compressed = results.slice(index * strategies.length, strategies.length).min_by(&:bytesize)
        candidate.merge(compressed: compressed)
      end
    ensure
      cancelled = true
      Array(threads).each(&:join)
    end
    private_class_method :compress_candidates

    def deflate_best(raw, checkpoint = nil)
      results = []
      [Zlib::DEFAULT_STRATEGY, (Zlib.const_defined?(:FILTERED) ? Zlib::FILTERED : Zlib::DEFAULT_STRATEGY)].uniq.each do |strategy|
        stream = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, Zlib::MAX_WBITS, Zlib::DEF_MEM_LEVEL, strategy)
        begin
          compressed = +''.b
          offset = 0
          while offset < raw.bytesize
            checkpoint.call(offset, raw.bytesize) if checkpoint
            compressed << stream.deflate(raw.byteslice(offset, 32_768), Zlib::NO_FLUSH)
            offset += 32_768
          end
          compressed << stream.finish
          results << compressed
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
