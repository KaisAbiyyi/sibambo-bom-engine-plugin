# frozen_string_literal: true
require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'zlib'
require_relative '../bomc_texture_optimizer'
require_relative '../bomc_extension'
require_relative '../material_extractor'

class TestAdaptiveTextureStaging < Test::Unit::TestCase
  Frame = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data) do
    def save_file(path)
      File.binwrite(path, 'j' * 1000)
    end
  end
  Texture = Struct.new(:reference) do
    def write(path, _colorized)
      File.binwrite(path, 'p' * 20_000)
      true
    end
    def image_rep(_colorized); reference; end
  end
  class Cancelled < StandardError; end

  def test_color_map_frame_conversion_preserves_padding_alpha_and_final_checkpoint
    [24, 32].each do |bits|
      bytes = +''.b
      expected = +''.b
      3.times do |row|
        257.times do |column|
          b, g, r, a = column % 256, row * 31, (column * 7) % 256, column % 256
          bytes << (bits == 24 ? [b, g, r] : [b, g, r, a]).pack('C*')
          expected << [r, g, b, bits == 24 ? 255 : a].pack('C*')
        end
        bytes << [99, 88, 77].pack('C*')
      end
      checkpoints = []
      actual = BOMEngine::BOMCTextureOptimizer.send(:color_map_rgba,
        Frame.new(257, 3, bits, 3, bytes)) { |done, total| checkpoints << [done, total] }
      assert_equal expected, actual
      assert_equal [771, 771], checkpoints.last
    end
  end

  def test_color_map_frame_conversion_yields_at_bounded_intervals_and_propagates_cancel
    frame = Frame.new(256, 257, 24, 0, [3, 2, 1].pack('C*') * (256 * 257))
    checkpoints = []
    result = BOMEngine::BOMCTextureOptimizer.send(:color_map_rgba, frame) { |done, _| checkpoints << done }
    assert_equal [1, 2, 3, 255].pack('C*') * (256 * 257), result
    assert_equal 256 * 257, checkpoints.last
    assert checkpoints.each_cons(2).all? { |a, b| b - a <= 32_768 }
    assert_raise(Cancelled) do
      BOMEngine::BOMCTextureOptimizer.send(:color_map_rgba, frame) do |done, _|
        raise Cancelled, 'stop conversion' if done >= 32_768
      end
    end
  end

  def stage_color_map(dir, enabled: true, conflict: false, alpha: 255, budget: nil, tint: 0, identical: false)
    jpeg=[255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*')
    base=Frame.new(2,1,24,2,[30,20,10,60,50,40,0,0].pack('C*'))
    base.data=[30,20,10,30,20,10,0,0].pack('C*') if conflict
    target=Frame.new(2,1,32,0,[33+tint,22,11,alpha,66,55,44,alpha].pack('C*'))
    target.data=[30,20,10,255,60,50,40,255].pack('C*') if identical
    texture=Texture.new(target)
    texture.define_singleton_method(:write) do |path,colorized|
      File.binwrite(path,colorized ? 'p'*20_000 : jpeg)
      true
    end
    BOMEngine::BOMCTextureOptimizer.stage(texture:texture,directory:dir,basename:'different-name',source_path:'embedded.jpg',profile: :exact,
      allow_jpeg_color_map:enabled,color_map_budget:budget,image_rep_loader:->(path){path.end_with?('.jpg') ? base : target})
  end

  def test_color_map_budget_reserves_unique_payloads_and_keeps_verified_fallback
    omit('Exact JPEG color-map staging is Windows-only') unless RUBY_PLATFORM.match?(/mingw|mswin/i)
    with_codec do
      budget={remaining_pixels:2,hashes:{}}
      [0,0,1].each_with_index do |tint,index|
        Dir.mktmpdir do |dir|
          result=stage_color_map(dir,budget:budget,tint:tint)
          assert_equal index==2 ? '.webp' : '.jcm',File.extname(result[:path])
          assert_equal 0,budget[:remaining_pixels]
          assert_equal 1,budget[:hashes].length
        end
      end
    end
  end

  def test_already_exact_native_jpeg_does_not_consume_mapping_time_or_pixel_budget
    with_codec(fail_encode:true) do
      Dir.mktmpdir do |dir|
        result=stage_color_map(dir,identical:true)
        assert_equal :native_jpeg_candidate,result.dig(:evidence,:selected)
        assert_empty Dir.glob(File.join(dir,'*.jcm-base.jpg'))
      end
    end
  end

  def test_experimental_color_map_competes_with_complete_verified_webp_bytes
    omit('Exact JPEG color-map staging is Windows-only') unless RUBY_PLATFORM.match?(/mingw|mswin/i)
    with_codec do
      Dir.mktmpdir do |dir|
        selected=stage_color_map(dir)
        assert_equal '.jcm',File.extname(selected[:path])
        assert_equal :jpeg_color_map_candidate,selected.dig(:evidence,:selected)
        assert_operator File.size(selected[:path]),:<,12_000
        assert_equal Digest::SHA256.file(selected[:path]).hexdigest,selected.dig(:evidence,:selected_sha256)
        assert_equal [11,22,33,255,44,55,66,255].pack('C*'),BOMEngine::BOMCJpegColorMap.reconstruct(File.binread(selected[:path]),[10,20,30,255,40,50,60,255].pack('C*'))
      end
    end
  end

  def test_color_map_is_opt_in_and_conflicts_or_alpha_keep_verified_fallback
    with_codec do
      [{enabled:false},{conflict:true},{alpha:127}].each do |options|
        Dir.mktmpdir do |dir|
          selected=stage_color_map(dir,**options)
          assert_equal '.webp',File.extname(selected[:path])
          assert_equal 0,selected.dig(:evidence,:quality,:max_channel_error)
        end
      end
    end
  end

  def frame(error = 0, alpha: 255)
    Frame.new(2, 2, 32, 0, ([100 + error, 80 + error, 60 + error, alpha] * 4).pack('C*'))
  end

  # Only the external codec is doubled: selection, quality measurement and
  # filesystem operations are real. Different quality levels decode differently.
  def with_codec(fail_encode: false, cancel: false, on_encode: nil, on_decode: nil)
    encoder = BOMEngine::BOMCTextureEncoder
    names = [:capabilities, :encode_webp, :decode_webp]
    originals = names.map { |name| [name, encoder.respond_to?(name) ? encoder.method(name) : nil] }.to_h
    encoder.define_singleton_method(:capabilities) { |**_| { available: true, verified: true, sha256: 'codec-test' } }
    encoder.define_singleton_method(:encode_webp) do |source_path:, output_path:, quality: 80, lossless: false, **_|
      on_encode.call(lossless: lossless, quality: quality) if on_encode
      raise Cancelled, 'cancel' if cancel
      return { success: false, reason: :timeout } if fail_encode
      raise 'must encode the original PNG' unless source_path.end_with?('.png')
      File.binwrite(output_path, 'w' * (lossless ? 12_000 : quality * 50))
      { success: true, path: output_path }
    end
    encoder.define_singleton_method(:decode_webp) do |source_path:, output_path:, **_|
      on_decode.call if on_decode
      File.binwrite(output_path, source_path)
      { success: true, path: output_path }
    end
    yield
  ensure
    originals.each do |name, method|
      method ? encoder.define_singleton_method(name, method) : encoder.singleton_class.remove_method(name)
    end
  end

  def stage(dir, profile: :research, alpha: 255, policy: nil, candidate_cache: nil, &loader)
    cache_option = candidate_cache ? { candidate_cache: candidate_cache } : {}
    BOMEngine::BOMCTextureOptimizer.stage(
      texture: Texture.new(frame(0, alpha: alpha)), directory: dir,
      basename: 'arbitrary-material', source_path: 'embedded/texture.png',
      profile: profile, policy: policy, **cache_option, image_rep_loader: loader || lambda { |path|
        if path.end_with?('.jpg')
          frame(20, alpha: alpha) # default JPEG fails the quality gate
        elsif path.include?('lossless')
          frame(0, alpha: alpha)
        elsif path.include?('90') || path.include?('95') || path.include?('100')
          frame(1, alpha: alpha)
        else
          frame(10, alpha: alpha)
        end
      }
    )
  end

  def test_candidate_cache_reuses_encoded_variants_after_first_profile_directory_is_removed
    encode_calls = []
    with_codec(on_encode: ->(**event) { encode_calls << event }) do
      Dir.mktmpdir('candidate-cache-test') do |root|
        cache_dir = File.join(root, 'cache')
        Dir.mkdir(cache_dir)
        cache = { directory: cache_dir, entries: {}, hits: 0 }
        first_sha = nil
        first_calls = nil
        assert_nothing_raised(ArgumentError) do
          Dir.mktmpdir('first-profile', root) do |dir|
            first = stage(dir, profile: :research, candidate_cache: cache)
            first_sha = Digest::SHA256.file(first[:path]).hexdigest
          end
          first_calls = encode_calls.length
          assert_operator first_calls, :>, 0
          Dir.mktmpdir('second-profile', root) do |dir|
            second = stage(dir, profile: :research, candidate_cache: cache)
            assert_equal first_sha, Digest::SHA256.file(second[:path]).hexdigest
            assert_equal true, second.dig(:evidence, :quality, :compatible)
          end
        end
        assert_equal first_calls, encode_calls.length
        assert_operator cache[:hits], :>, 0
      end
    end
  end

  def test_candidate_cache_keeps_research_quality_decision_identical_after_visual
    encode_calls = []
    with_codec(on_encode: ->(**event) { encode_calls << event }) do
      Dir.mktmpdir('cross-profile-cache') do |root|
        cache_dir = File.join(root, 'cache')
        Dir.mkdir(cache_dir)
        cache = { directory: cache_dir, entries: {}, hits: 0 }
        Dir.mktmpdir('visual', root) { |dir| stage(dir, profile: :visual, candidate_cache: cache) }
        calls_after_visual = encode_calls.length
        cached = nil
        Dir.mktmpdir('research-cached', root) do |dir|
          result = stage(dir, profile: :research, candidate_cache: cache)
          cached = [Digest::SHA256.file(result[:path]).hexdigest, result.dig(:evidence, :quality, :psnr_db)]
        end
        calls_after_cached = encode_calls.length
        uncached = nil
        Dir.mktmpdir('research-uncached', root) do |dir|
          result = stage(dir, profile: :research)
          uncached = [Digest::SHA256.file(result[:path]).hexdigest, result.dig(:evidence, :quality, :psnr_db)]
        end
        assert_equal uncached, cached
        assert_equal calls_after_visual, calls_after_cached
        assert_operator encode_calls.length, :>, calls_after_cached
      end
    end
  end

  def test_session_jpeg_quality_cache_skips_repeat_decode_but_rechecks_changed_reference
    jpeg_decodes = 0
    loader = lambda do |path|
      jpeg_decodes += 1 if path.end_with?('.jpg')
      path.end_with?('.jpg') ? frame(20) : frame(0)
    end
    with_codec do
      Dir.mktmpdir('jpeg-quality-cache') do |root|
        cache_dir = File.join(root, 'cache')
        Dir.mkdir(cache_dir)
        cache = { directory: cache_dir, entries: {}, hits: 0 }
        first = nil
        Dir.mktmpdir('visual', root) { |dir| first = stage(dir, profile: :visual, candidate_cache: cache, &loader) }
        assert_equal 1, jpeg_decodes
        second = nil
        Dir.mktmpdir('research', root) { |dir| second = stage(dir, profile: :research, candidate_cache: cache, &loader) }
        assert_equal 1, jpeg_decodes, 'identical verified JPEG and reference pixels avoid a second image decode'
        assert_operator cache.fetch(:jpeg_quality_hits, 0), :>, 0
        assert_equal first.dig(:evidence, :attempts, 0, :quality), second.dig(:evidence, :attempts, 0, :quality)
        Dir.mktmpdir('changed', root) do |dir|
          BOMEngine::BOMCTextureOptimizer.stage(texture: Texture.new(frame(1)), directory: dir,
            basename: 'changed', source_path: 'texture.png', profile: :research,
            candidate_cache: cache, image_rep_loader: loader)
        end
        assert_equal 2, jpeg_decodes, 'changed reference pixels require a fresh quality measurement'
      end
    end
  end

  def test_quality_cache_reuses_only_same_reference_pixels_and_verified_candidate
    decode_calls = 0
    with_codec(on_decode: -> { decode_calls += 1 }) do
      Dir.mktmpdir('quality-cache-test') do |root|
        cache_dir = File.join(root, 'cache')
        Dir.mkdir(cache_dir)
        cache = { directory: cache_dir, entries: {}, hits: 0 }
        first = nil
        Dir.mktmpdir('first', root) do |dir|
          first = BOMEngine::BOMCTextureOptimizer.stage(texture: Texture.new(frame(0)),
            directory: dir, basename: 'material', source_path: 'texture.png', profile: :exact,
            candidate_cache: cache, image_rep_loader: ->(_path) { frame(0) })
        end
        assert_equal :webp_candidate, first.dig(:evidence, :selected)
        after_first = decode_calls
        assert_operator after_first, :>, 0

        Dir.mktmpdir('same', root) do |dir|
          same = BOMEngine::BOMCTextureOptimizer.stage(texture: Texture.new(frame(0)),
            directory: dir, basename: 'material', source_path: 'texture.png', profile: :exact,
            candidate_cache: cache, image_rep_loader: ->(_path) { frame(0) })
          assert_equal :webp_candidate, same.dig(:evidence, :selected)
          assert_equal after_first, decode_calls, 'verified candidate quality should not be decoded again for identical pixels'
          assert(Array(same.dig(:evidence, :attempts)).any? { |a| a[:quality_cache_hit] == true })
          assert_operator cache.fetch(:quality_hits, 0), :>, 0
        end

        Dir.mktmpdir('changed-reference', root) do |dir|
          changed = BOMEngine::BOMCTextureOptimizer.stage(texture: Texture.new(frame(1)),
            directory: dir, basename: 'material', source_path: 'texture.png', profile: :exact,
            candidate_cache: cache, image_rep_loader: ->(_path) { frame(0) })
          assert_equal :staged_png, changed.dig(:evidence, :selected),
            'identical staged bytes must not bypass remeasurement when SketchUp reference pixels differ'
          assert_operator decode_calls, :>, after_first
        end
      end
    end
  end

  def test_candidate_cache_reencodes_a_corrupted_entry
    encode_calls = []
    decode_calls = 0
    with_codec(on_encode: ->(**event) { encode_calls << event }, on_decode: -> { decode_calls += 1 }) do
      Dir.mktmpdir('tampered-candidate-cache') do |root|
        cache_dir = File.join(root, 'cache')
        Dir.mkdir(cache_dir)
        cache = { directory: cache_dir, entries: {}, hits: 0 }
        expected_sha = nil
        Dir.mktmpdir('before', root) do |dir|
          expected_sha = Digest::SHA256.file(stage(dir, candidate_cache: cache)[:path]).hexdigest
        end
        calls_before = encode_calls.length
        decodes_before = decode_calls
        cached_file = Dir.glob(File.join(cache_dir, '*.webp')).first
        refute_nil cached_file
        File.binwrite(cached_file, 'corrupt')
        Dir.mktmpdir('after', root) do |dir|
          assert_equal expected_sha, Digest::SHA256.file(stage(dir, candidate_cache: cache)[:path]).hexdigest
        end
        assert_operator encode_calls.length, :>, calls_before
        assert_operator decode_calls, :>, decodes_before,
          'a corrupted cached candidate must be redecoded, not trust previously measured quality'
      end
    end
  end

  def test_research_recovers_from_rejected_jpeg_with_measured_webp
    with_codec do
      Dir.mktmpdir('adaptive-texture') do |dir|
        result = stage(dir)
        assert_equal '.webp', File.extname(result[:path])
        assert_operator File.size(result[:path]), :<, 12_000
        assert_equal true, result.dig(:evidence, :alpha_preserved)
        assert_operator result.dig(:evidence, :quality, :psnr_db), :>=, 42.0
        assert_equal Digest::SHA256.file(result[:path]).hexdigest, result.dig(:evidence, :selected_sha256)
        assert_nothing_raised { JSON.generate(result[:evidence]) }
      end
    end
  end

  def test_texture_staging_reports_phase_costs_without_changing_candidate_choice
    with_codec do
      Dir.mktmpdir('texture-phase-evidence') do |dir|
        result = stage(dir, profile: :research)
        assert_equal :webp_candidate, result.dig(:evidence, :selected)
        times = result.dig(:evidence, :timings_ms)
        assert_kind_of Hash, times
        [:png_write, :reference_image_rep, :webp_search, :total].each do |phase|
          assert_kind_of Numeric, times[phase]
          assert_operator times[phase], :>=, 0
        end
        candidate = result.dig(:evidence, :attempts).find { |attempt| attempt[:codec] == :webp && attempt[:reason] == :accepted }
        assert_not_nil candidate
        [:encode, :decode, :candidate_image_rep, :pixel_compare, :total].each do |phase|
          assert_kind_of Numeric, candidate.dig(:timings_ms, phase)
        end
      end
    end
  end

  def test_transparency_is_not_discarded_to_meet_budget
    with_codec do
      Dir.mktmpdir('adaptive-alpha') do |dir|
        result = stage(dir, alpha: 64) { |_path| frame(0, alpha: 255) }
        assert_equal '.png', File.extname(result[:path])
        assert(Array(result.dig(:evidence, :attempts)).any? { |a| a[:reason] == :alpha_mismatch })
      end
    end
  end

  def test_exact_selects_smaller_pixel_identical_webp_without_lossy_attempts
    with_codec do
      Dir.mktmpdir('adaptive-exact') do |dir|
        result = stage(dir, profile: :exact)
        assert_equal '.webp', File.extname(result[:path])
        assert_equal 12_000, File.size(result[:path])
        assert_equal 0, result.dig(:evidence, :quality, :max_channel_error)
        assert_equal 0.0, result.dig(:evidence, :quality, :mean_squared_error)
        lossless_attempts = result[:evidence][:attempts].select { |attempt| attempt[:mode].to_s == 'lossless' }
        assert_equal 2, lossless_attempts.length, 'Exact tries both normal and high-effort lossless WebP candidates'
        assert_equal ['m4-q75', 'm6-q100-mt'], lossless_attempts.map { |attempt| attempt[:variant] }
        assert Dir.glob(File.join(dir, '*.jpg')).empty?, 'Exact must never re-encode JPEG'
        assert Dir.glob(File.join(dir, '*.lossy-*.webp')).empty?, 'Exact must never try lossy WebP'
        assert_nothing_raised { JSON.generate(result[:evidence]) }
      end
    end
  end

  def test_explicit_pixel_lossless_policy_also_blocks_lossy_candidates
    with_codec do
      Dir.mktmpdir do |dir|
        result = stage(dir, profile: :research, policy: :pixel_lossless)
        assert_equal '.webp', File.extname(result[:path])
        assert_equal 0, result.dig(:evidence, :quality, :max_channel_error)
        assert Dir.glob(File.join(dir, '*.lossy-*.webp')).empty?
        assert Dir.glob(File.join(dir, '*.jpg')).empty?
      end
    end
  end

  def stage_native(dir, changed: false, cancel: false)
    texture = Texture.new(frame)
    texture.define_singleton_method(:write) do |path, colorized|
      if File.extname(path) == '.jpg'
        raise Cancelled, 'cancel native extraction' if cancel
        raise 'must extract embedded JPEG without colorization' if colorized
        File.binwrite(path, 'native' * 100)
      else
        raise 'PNG must preserve displayed colors' unless colorized
        File.binwrite(path, 'p' * 20_000)
      end
      true
    end
    BOMEngine::BOMCTextureOptimizer.stage(texture: texture, directory: dir, basename: 'material',
      source_path: 'embedded.JPG', profile: :exact,
      image_rep_loader: ->(path) { path.end_with?('.jpg') && changed ? frame(1) : frame })
  end

  def test_exact_keeps_smaller_native_jpeg_only_when_displayed_pixels_match
    with_codec do
      Dir.mktmpdir do |dir|
        result = stage_native(dir)
        assert_equal '.jpg', File.extname(result[:path])
        assert_equal 600, File.size(result[:path])
        assert_equal 0, result.dig(:evidence, :quality, :max_channel_error)
        assert_equal true, result.dig(:evidence, :alpha_preserved)
        # Presence of a PNG fallback must not displace a verified Exact JPEG.
        File.binwrite(File.join(dir, File.basename(result[:path], '.*') + '.png'), 'fallback')
        graph = { materials: [{ name: 'm', texture: {} }] }
        extracted = [{ name: 'm', texture: { filename: result[:filename], staging_evidence: result[:evidence] } }]
        BOMEngine::BOMCExtension.send(:attach_staged_textures, graph, extracted, dir, profile: :exact)
        assert_equal result[:path], graph[:materials][0][:texture][:source_path]
      end
    end
  end

  def test_exact_colorized_native_jpeg_is_rejected_even_if_smaller
    with_codec do
      Dir.mktmpdir do |dir|
        result = stage_native(dir, changed: true)
        assert_equal '.webp', File.extname(result[:path])
        assert Array(result[:evidence][:attempts]).any? { |a| a[:reason] == :native_jpeg_pixel_mismatch }
      end
    end
  end

  def test_native_jpeg_extraction_cancellation_propagates
    with_codec do
      Dir.mktmpdir { |dir| assert_raise(Cancelled) { stage_native(dir, cancel: true) } }
    end
  end

  def test_exact_rejects_one_channel_difference_and_preserves_png
    with_codec do
      Dir.mktmpdir do |dir|
        result = stage(dir, profile: :exact) { |_| frame(1) }
        assert_equal '.png', File.extname(result[:path])
        assert Array(result[:evidence][:attempts]).any? { |a| a[:reason] == :lossless_pixel_mismatch }
      end
    end
  end

  def test_exact_codec_cancellation_is_not_converted_to_png_success
    with_codec(cancel: true) do
      Dir.mktmpdir { |dir| assert_raise(Cancelled) { stage(dir, profile: :exact) } }
    end
  end

  def test_unavailable_candidate_preserves_png_and_records_reason
    with_codec(fail_encode: true) do
      Dir.mktmpdir('adaptive-failure') do |dir|
        result = stage(dir)
        assert_equal '.png', File.extname(result[:path])
        assert(Array(result.dig(:evidence, :attempts)).any? { |a| a[:reason] == :timeout })
      end
    end
  end

  def test_cancellation_is_not_hidden_as_fallback
    with_codec(cancel: true) do
      Dir.mktmpdir('adaptive-cancel') do |dir|
        assert_raise(Cancelled) { stage(dir) }
      end
    end
  end

  def test_material_extraction_propagates_codec_cancellation
    texture = Struct.new(:filename, :width, :height, :image_width, :image_height).new('embedded.png', 1, 1, 2, 2)
    color = Struct.new(:red, :green, :blue, :alpha).new(255, 255, 255, 255)
    material = Struct.new(:name, :display_name, :color, :alpha, :materialType, :texture).new('m', 'm', color, 1, 1, texture)
    model = Struct.new(:materials).new([material])
    Dir.mktmpdir('adaptive-material-cancel') do |dir|
      assert_raise(BOMEngine::BOMCTextureEncoder::TranscodeCancelledError) do
        BOMEngine::MaterialExtractor.extract(model, nil, dir, optimize_textures: true, checkpoint: lambda { |**event|
          raise BOMEngine::BOMCTextureEncoder::TranscodeCancelledError, 'cancel' if event[:stage] == :snapshot_textures
        })
      end
    end
  end

  def test_rejected_candidate_metrics_do_not_describe_the_png_fallback
    with_codec(fail_encode: true) do
      Dir.mktmpdir('adaptive-fallback') do |dir|
        result = stage(dir)
        assert_equal 0.0, result.dig(:evidence, :quality, :mean_squared_error)
        assert_equal true, result.dig(:evidence, :alpha_preserved)
        assert_nothing_raised { JSON.generate(result[:evidence]) }
      end
    end
  end

  def test_no_candidate_is_accepted_when_all_decoded_pixels_are_bad
    with_codec do
      Dir.mktmpdir('adaptive-all-bad') do |dir|
        result = stage(dir) { |_| frame(80) }
        assert_equal '.png', File.extname(result[:path])
        assert(Array(result.dig(:evidence, :attempts)).any? { |a| a[:reason] == :lossless_pixel_mismatch })
        assert(Array(result.dig(:evidence, :attempts)).any? { |a| a[:reason] == :quality_gate_failed })
      end
    end
  end

  def test_jpeg_decode_failure_does_not_prevent_webp_search
    with_codec do
      Dir.mktmpdir('adaptive-jpeg-error') do |dir|
        result = stage(dir) do |path|
          raise 'JPEG decode unavailable' if path.end_with?('.jpg')
          frame(0)
        end
        assert_equal '.webp', File.extname(result[:path])
        assert_equal :jpeg_error, result[:evidence][:attempts][0][:reason]
      end
    end
  end

  def test_malformed_pixel_layout_is_rejected
    malformed = frame
    malformed.bits_per_pixel = 25
    assert_equal false, BOMEngine::BOMCTextureOptimizer.compare(malformed, frame)[:compatible]
    malformed = frame
    malformed.row_padding = -1
    assert_equal false, BOMEngine::BOMCTextureOptimizer.compare(malformed, frame)[:compatible]
  end

  def test_identical_pixel_blocks_avoid_per_channel_ruby_scanning
    bytes = Class.new(String) do
      attr_reader :byte_reads
      def getbyte(index)
        @byte_reads = (@byte_reads || 0) + 1
        super
      end
    end.new(([23, 45, 67, 0] * 65_536).pack('C*'))
    reference = Frame.new(256, 256, 32, 0, bytes)
    candidate = Frame.new(256, 256, 32, 0, String.new(bytes))
    checkpoints = []
    measured = BOMEngine::BOMCTextureOptimizer.compare(reference, candidate) { |done, _| checkpoints << done }
    assert_equal 0.0, measured[:mean_squared_error]
    assert_equal true, measured[:alpha_preserved]
    assert_equal 0, bytes.byte_reads.to_i, 'identical bytes should be compared in native String blocks'
    assert !checkpoints.empty?, 'fast equality still yields for cancellation'
  end

  def test_pixel_block_comparison_ignores_padding_but_checks_last_pixel
    source = Frame.new(2, 2, 24, 2, ([10] * 6 + [99, 99] + [10] * 6 + [99, 99]).pack('C*'))
    same = Frame.new(2, 2, 24, 1, ([10] * 6 + [0] + [10] * 6 + [0]).pack('C*'))
    result = BOMEngine::BOMCTextureOptimizer.compare(source, same)
    assert_equal 0.0, result[:mean_squared_error]
    same.data.setbyte(12, 11)
    result = BOMEngine::BOMCTextureOptimizer.compare(source, same)
    assert_equal 1, result[:max_channel_error]
    assert_in_delta 1.0 / 12, result[:mean_squared_error], 1e-12
  end

  def test_checked_staging_is_not_overridden_by_an_external_file
    with_codec do
      Dir.mktmpdir('adaptive-attachment') do |dir|
        result = stage(dir)
        external = File.join(dir, 'unrelated.png')
        File.binwrite(external, 'unrelated pixels')
        graph = { materials: [{ name: 'material', texture: {} }] }
        extracted = [{ name: 'material', texture: { filename: result[:filename], source_path: external, staging_evidence: result[:evidence] } }]
        BOMEngine::BOMCExtension.send(:attach_staged_textures, graph, extracted, dir, profile: :research)
        assert_equal result[:path], graph[:materials][0][:texture][:source_path]
        File.binwrite(result[:path], 'tampered')
        assert_raise(RuntimeError) { BOMEngine::BOMCExtension.send(:attach_staged_textures, graph, extracted, dir, profile: :research) }
      end
    end
  end

  def test_size_failure_retains_per_texture_decisions
    with_codec do
      Dir.mktmpdir('adaptive-budget') do |dir|
        result = stage(dir)
        graph = {
          materials: [{ name: 'generic', texture: { source_path: result[:path], filename: result[:filename],
            image_width_px: 2, image_height_px: 2, encoding_evidence: { staging: result[:evidence] } } }],
          format: { name: 'BOM Engine Canonical', version: '3.0.0' }, tags: [], meshes: [],
          definitions: [{ id: 'root-definition', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] }],
          nodes: [{ id: 'root', kind: 'root', definition_id: 'root-definition', transform_id: 0, visible: true }],
          transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]]
        }
        error = assert_raise(BOMEngine::BOMCSizeGate::TargetNotMet) do
          BOMEngine::BOMCSizeGate.compile_candidate(graph, profile: :research, source_info: { available: true, bytes: 1 })
        end
        assert_respond_to error, :texture_diagnostics
        assert_equal 'generic', error.texture_diagnostics[0][:material]
        assert_equal result.dig(:evidence, :selected_sha256), error.texture_diagnostics[0][:decision][:selected_sha256]
        assert_nothing_raised { JSON.generate(error.texture_diagnostics) }
      end
    end
  end

  # Real PNG -> bundled cwebp -> bundled dwebp -> PNG, with a PNG decoder
  # independent of the production comparator; no SketchUp runtime is claimed.
  def test_real_codec_staging_on_opaque_and_transparent_textures
    omit('bundled codecs are Windows-only') unless Gem.win_platform?
    [255, 0].product([:research, :exact]).each do |alpha, profile|
      Dir.mktmpdir('adaptive-real') do |dir|
        pixels = Array.new(64 * 64) { |i| [i % 32 * 7, (i / 64) % 32 * 7, 43, alpha] }.flatten.pack('C*')
        ref = Frame.new(64, 64, 32, 0, pixels)
        raw = (0...64).map { |y| "\0".b + pixels.byteslice(y * 256, 256) }.join.b
        png = "\x89PNG\r\n\x1a\n".b + chunk('IHDR', [64, 64, 8, 6, 0, 0, 0].pack('NNC5')) +
          chunk('IDAT', Zlib::Deflate.deflate(raw, 0)) + chunk('IEND', ''.b)
        texture = Object.new
        texture.define_singleton_method(:write) { |path, _| File.binwrite(path, png); true }
        texture.define_singleton_method(:image_rep) { |_| ref }
        loader = lambda { |path| path.end_with?('.jpg') ? frame(20) : read_png(path) }
        result = BOMEngine::BOMCTextureOptimizer.stage(texture: texture, directory: dir, basename: 'pattern',
          source_path: 'embedded/pattern.png', profile: profile, image_rep_loader: loader)
        assert_equal '.webp', File.extname(result[:path]), result[:evidence].inspect
        assert_operator File.size(result[:path]), :<, png.bytesize
        assert_equal true, result.dig(:evidence, :alpha_preserved)
        if profile == :exact
          assert_equal 0.0, result.dig(:evidence, :quality, :mean_squared_error)
          assert_equal 0, result.dig(:evidence, :quality, :max_channel_error)
        end
        assert_nothing_raised { JSON.generate(result[:evidence]) }
        assert Dir.glob(File.join(dir, '*.decoded.png')).empty?
      end
    end
  end

  def chunk(kind, bytes)
    [bytes.bytesize].pack('N') + kind.b + bytes + [Zlib.crc32(kind.b + bytes)].pack('N')
  end

  def read_png(path)
    bytes = File.binread(path)
    width, height, depth, color = bytes.byteslice(16, 10).unpack('NNCC')
    raise 'unexpected PNG layout' unless depth == 8 && [2, 6].include?(color)
    channels = color == 6 ? 4 : 3
    compressed = ''.b
    offset = 8
    while offset < bytes.bytesize
      size = bytes.byteslice(offset, 4).unpack1('N')
      compressed << bytes.byteslice(offset + 8, size) if bytes.byteslice(offset + 4, 4) == 'IDAT'
      offset += size + 12
    end
    raw = Zlib::Inflate.inflate(compressed).bytes
    stride = width * channels
    previous = Array.new(stride, 0)
    decoded = []
    height.times do |y|
      filter = raw[y * (stride + 1)]
      row = raw.slice(y * (stride + 1) + 1, stride)
      row.each_index do |x|
        left = x >= channels ? row[x - channels] : 0
        up = previous[x]
        upper_left = x >= channels ? previous[x - channels] : 0
        predictor = case filter
                    when 0 then 0
                    when 1 then left
                    when 2 then up
                    when 3 then (left + up) / 2
                    when 4
                      p = left + up - upper_left
                      [left, up, upper_left].min_by { |v| (p - v).abs }
                    else raise 'unknown PNG filter'
                    end
        row[x] = (row[x] + predictor) & 255
      end
      decoded.concat(row)
      previous = row
    end
    Frame.new(width, height, channels * 8, 0, decoded.pack('C*'))
  end
end
