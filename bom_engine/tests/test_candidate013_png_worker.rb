require 'minitest/autorun'
require 'tmpdir'
require 'zlib'
require 'digest'
require_relative '../bomc_png_optimizer'
require_relative '../bomc_texture_optimizer'

class TestCandidate013PngWorker < Minitest::Test
  def test_exact_staging_uses_detached_pixels_and_rejects_decoded_pixel_mismatch
    skip 'Windows process helper only' unless Gem.win_platform?
    frame_class = Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
    native = [77,55,33,0,99,88,66,255].pack('C*')
    reference = frame_class.new(2,1,32,0,native)
    texture = Object.new
    texture.define_singleton_method(:image_rep) { |_| reference }
    texture.define_singleton_method(:write) { |*| raise 'SDK PNG serializer must not be called' }
    optimizer = BOMEngine::BOMCTextureOptimizer
    png = BOMEngine::BOMCPngOptimizer
    loader = ->(path) {
      parsed = png.send(:parse, File.binread(path))
      raw = Zlib::Inflate.inflate(parsed[:idat])
      rows = png.send(:unfilter,raw,2,1,4,nil)
      data = rows.join.bytes.each_slice(4).flat_map { |r,g,b,a| [b,g,r,a] }.pack('C*')
      frame_class.new(2,1,32,0,data)
    }
    Dir.mktmpdir do |dir|
      optimizer.stub(:adaptive_webp, ->(_path,_reference,evidence,*_,**_options) { evidence }) do
        args = {texture:texture,directory:dir,basename:'stage',source_path:'embedded.bmp',
          profile: :exact,cooperative_png:true,image_rep_loader:loader}
        result = optimizer.stage(**args)
        assert_equal :detached_png_worker,result.dig(:evidence,:png_staging_backend)
        assert_equal native,loader.call(result[:path]).data
        assert_raises(RuntimeError) {
          optimizer.stage(**args.merge(basename:'bad',image_rep_loader: ->(_) {frame_class.new(2,1,32,0,"\0".b*8)}))
        }
      end
    end
  end

  def test_optional_filter_failure_retains_the_original_ruby_candidate
    optimizer = BOMEngine::BOMCPngOptimizer
    Dir.mktmpdir do |dir|
      width = 512; height = 512
      raw = ("\0".b + ([17,29,51]*width).pack('C*')) * height
      header = [width,height,8,2,0,0,0].pack('NNC5')
      bytes = optimizer::SIGNATURE + optimizer.send(:png_chunk,'IHDR',header) +
        optimizer.send(:png_chunk,'IDAT',Zlib::Deflate.deflate(raw,0)) + optimizer.send(:png_chunk,'IEND',''.b)
      path = File.join(dir,'input.png');File.binwrite(path,bytes)
      expected = nil; actual = nil
      BOMEngine::BOMCPngWorker.stub(:available?,false) {
        expected = optimizer.optimize(source_path:path,output_path:File.join(dir,'reference.png'))
      }
      BOMEngine::BOMCPngWorker.stub(:available?,true) do
        BOMEngine::BOMCPngWorker.stub(:filter, ->(**_) {raise IOError,'worker unavailable'}) {
          actual = optimizer.optimize(source_path:path,output_path:File.join(dir,'actual.png'))
        }
      end
      assert_equal File.binread(expected[:path]),File.binread(actual[:path])
      assert_equal :ruby,actual[:filter_backend]
      assert_match(/worker unavailable/,actual[:worker_error])
    end
  end

  def test_windows_worker_preserves_all_filter_bytes_and_cancellation
    skip 'Windows process helper only' unless Gem.win_platform?
    worker = BOMEngine::BOMCPngWorker
    Dir.mktmpdir do |dir|
      [3, 4].each do |bpp|
        random = Random.new(13)
        width = 259; height = 137
        rows = Array.new(height) { random.bytes(width*bpp) }
        previous = Array.new(width*bpp, 0)
        # Exercise every PNG input predictor, including row transitions.
        raw = rows.each_with_index.map do |row, y|
          values = row.bytes; type = y % 5
          filtered = values.each_with_index.map do |value, x|
            left = x >= bpp ? values[x-bpp] : 0; up = previous[x]
            ul = x >= bpp ? previous[x-bpp] : 0
            pa = (up-ul).abs; pb = (left-ul).abs; pc = (left+up-2*ul).abs
            predictor = [0, left, up, (left+up)/2, pa<=pb && pa<=pc ? left : pb<=pc ? up : ul][type]
            (value-predictor)&255
          end
          previous = values
          type.chr.b + filtered.pack('C*')
        end.join.b
        expected = BOMEngine::BOMCPngOptimizer.send(:refilter_adaptive, rows, width, height, bpp, nil)
        count = 0
        actual = worker.filter(raw: raw, width: width, height: height, bpp: bpp, directory: dir,
          checkpoint: ->(*) { count += 1 })
        assert_equal expected, actual
        assert_operator count, :>, 0
      end
      cancelled = BOMEngine::BOMCProcessing::Cancelled
      assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
        worker.filter(raw: "\0\1\2\3".b, width: 1, height: 1, bpp: 3, directory: dir,
          checkpoint: ->(*) { raise cancelled, 'stop' })
      }
      assert_empty Dir.glob(File.join(dir, '.png-work-*')), 'owned scratch must be cleaned'
      polls = 0
      assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
        worker.filter(raw: "\0\1\2\3".b, width: 1, height: 1, bpp: 3, directory: dir,
          checkpoint: ->(_, _, phase) { polls += 1; raise cancelled, 'stop live process' if phase == :png_worker })
      }
      assert_empty Dir.glob(File.join(dir, '.png-work-*')), 'cancelled process must release owned files'
      assert_operator polls, :>, 2
    end
  end

  def test_frame_staging_preserves_rgb_alpha_padding_and_channel_order
    skip 'Windows process helper only' unless Gem.win_platform?
    worker = BOMEngine::BOMCPngWorker
    frame_class = Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
    Dir.mktmpdir do |dir|
      [3,4].each do |channels|
        source = +''.b; expected = +''.b
        19.times do |y|
          37.times do |x|
            rgba = [x*7%256,y*13%256,(x+y)*17%256,(x+y)%3==0 ? 0 : 171]
            source << (channels==4 ? [rgba[2],rgba[1],rgba[0],rgba[3]] : [rgba[2],rgba[1],rgba[0]]).pack('C*')
            expected << rgba.first(channels==4 ? 4 : 3).pack('C*')
          end
          source << 'pad'
        end
        path = File.join(dir,"frame#{channels}.png")
        frame = frame_class.new(37,19,channels*8,3,source)
        assert worker.write_frame(frame,path,checkpoint: ->(*) {})
        parsed = BOMEngine::BOMCPngOptimizer.send(:parse,File.binread(path))
        refute_nil parsed
        raw = Zlib::Inflate.inflate(parsed[:idat])
        samples = 19.times.map { |y| assert_equal 0,raw.getbyte(y*(37*channels+1)); raw.byteslice(y*(37*channels+1)+1,37*channels) }.join.b
        assert_equal expected, samples, 'including nonzero RGB at alpha0'
      end
    end
  end
end
