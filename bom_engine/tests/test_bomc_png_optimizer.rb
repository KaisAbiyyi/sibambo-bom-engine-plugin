# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'zlib'
require_relative '../bomc_png_optimizer'

class TestBOMCPngOptimizer < Minitest::Test
  def chunk(type,data)
    [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
  end

  def build_png(width,height)
    pixels = Array.new(width*height) do |index|
      x = index % width
      y = index / width
      [x % 17, y % 19, (x+y) % 23, (x+y) % 5 == 0 ? 128 : 255]
    end.flatten.pack('C*')
    raw = (0...height).map { |y| "\0".b + pixels.byteslice(y*width*4,width*4) }.join.b
    signature = BOMEngine::BOMCPngOptimizer::SIGNATURE
    signature + chunk('IHDR',[width,height,8,6,0,0,0].pack('NNC5')) +
      chunk('IDAT',Zlib::Deflate.deflate(raw,Zlib::NO_COMPRESSION)) + chunk('IEND',''.b)
  end

  def build_png_with_filters(width,height)
    pixels=(0...height).map do |y|
      width.times.flat_map { |x| [x*13%256,y*17%256,(x+y)*7%256,255] }.pack('C*').bytes
    end
    encoded=(0...height).map do |y|
      type=y%5
      previous=y.zero? ? Array.new(width*4,0) : pixels[y-1]
      filtered=pixels[y].each_with_index.map do |value,x|
        left=x>=4 ? pixels[y][x-4] : 0
        up=previous[x]
        upper_left=x>=4 ? previous[x-4] : 0
        predictor=case type
                  when 0 then 0
                  when 1 then left
                  when 2 then up
                  when 3 then (left+up)/2
                  when 4
                    p=left+up-upper_left
                    pa,pb,pc=(p-left).abs,(p-up).abs,(p-upper_left).abs
                    pa<=pb && pa<=pc ? left : (pb<=pc ? up : upper_left)
                  end
        (value-predictor)&255
      end
      type.chr.b + filtered.pack('C*')
    end.join.b
    BOMEngine::BOMCPngOptimizer::SIGNATURE + chunk('IHDR',[width,height,8,6,0,0,0].pack('NNC5'))+
      chunk('IDAT',Zlib::Deflate.deflate(encoded,Zlib::NO_COMPRESSION)) + chunk('IEND',''.b)
  end

  def decoded_samples(bytes)
    width,height,depth,color = bytes.byteslice(16,10).unpack('NNCC')
    raise 'fixture layout' unless depth == 8 && color == 6
    compressed = +''.b
    offset = 8
    while offset < bytes.bytesize
      length = bytes.byteslice(offset,4).unpack1('N')
      type = bytes.byteslice(offset+4,4)
      compressed << bytes.byteslice(offset+8,length) if type == 'IDAT'
      offset += 12 + length
    end
    raw = Zlib::Inflate.inflate(compressed)
    stride = width*4
    previous = Array.new(stride,0)
    out = +''.b
    height.times do |y|
      base = y*(stride+1)
      filter = raw.getbyte(base)
      row = raw.byteslice(base+1,stride).bytes
      row.each_index do |x|
        left = x >= 4 ? row[x-4] : 0
        up = previous[x]
        upper_left = x >= 4 ? previous[x-4] : 0
        predictor = case filter
                    when 0 then 0
                    when 1 then left
                    when 2 then up
                    when 3 then (left+up)/2
                    when 4
                      p=left+up-upper_left
                      [left,up,upper_left].min_by { |value| (p-value).abs }
                    else raise 'filter'
                    end
        row[x]=(row[x]+predictor)&255
      end
      out << row.pack('C*')
      previous=row
    end
    out
  end

  def test_repack_is_smaller_and_pixel_identical
    Dir.mktmpdir do |dir|
      source=File.join(dir,'source.png')
      output=File.join(dir,'optimized.png')
      File.binwrite(source,build_png(128,128))
      before=File.binread(source)
      result=BOMEngine::BOMCPngOptimizer.optimize(source_path:source,output_path:output)
      refute_nil result
      assert_operator File.size(output), :<, File.size(source)
      assert_equal decoded_samples(before), decoded_samples(File.binread(output))
      assert_includes [:redeflate_existing_filters,:adaptive_filters], result[:strategy]
    end
  end

  def test_malformed_png_fails_closed_without_output
    Dir.mktmpdir do |dir|
      source=File.join(dir,'bad.png')
      output=File.join(dir,'optimized.png')
      File.binwrite(source,'not-a-png')
      assert_nil BOMEngine::BOMCPngOptimizer.optimize(source_path:source,output_path:output)
      refute File.exist?(output)
    end
  end

  def test_all_five_png_filters_remain_exact_after_repack
    Dir.mktmpdir do |dir|
      source=File.join(dir,'all-filters.png')
      output=File.join(dir,'repacked.png')
      File.binwrite(source,build_png_with_filters(120,125))
      original=File.binread(source)
      optimized=BOMEngine::BOMCPngOptimizer.optimize(source_path:source,output_path:output)
      refute_nil optimized
      assert_equal decoded_samples(original),decoded_samples(File.binread(output)),
        'the fused row-filter search preserves every byte of RGBA image samples'
      assert_operator optimized[:bytes],:<,original.bytesize
    end
  end
end
