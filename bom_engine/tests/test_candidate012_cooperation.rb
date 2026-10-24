require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'digest'
require_relative '../scene_visibility_resolver'
require_relative '../bomc_processing'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'
require_relative '../bomc_png_optimizer'
require_relative '../bomc_export_job'

class TestCandidate012Cooperation < Minitest::Test
  def test_png_filter_search_matches_candidate011_golden_bytes
    optimizer = BOMEngine::BOMCPngOptimizer
    random = Random.new(12)
    cases = [
      [:gradient, 512, 256, 4, '353ed77e459efbd3e323283ba2bb04281c8d9732001e2b8e9c06d6e121e3e672'],
      [:noise, 511, 257, 3, 'e6757022c7f48a24ad92082578da27f93d02abe5a4fe95f457d4a6f2f7956409'],
      [:repeated, 512, 256, 4, 'fe4eded35d037c7dc43824ef2b6385cd3f6d10a6c84692e45668209c4642f04f']
    ]
    cases.each do |kind, width, height, bpp, expected_hash|
      rows = height.times.map do |y|
        case kind
        when :noise then random.bytes(width * bpp)
        when :repeated then ([23, 71, 133, 0] * width).pack('C*')
        else width.times.flat_map { |x| [x % 256, y % 256, (x+y) % 256, 255] }.pack('C*')
        end
      end
      filtered = optimizer.send(:refilter_adaptive, rows, width, height, bpp, nil)
      assert_equal expected_hash, Digest::SHA256.hexdigest(filtered), kind.to_s
    end
  end

  def test_container_compression_yields_without_changing_a_single_container_byte
    container = BOMEngine::BOMC::Container
    sections = [{type: 1, count: 1, bytes: ('abcdef' * 50_000).b + Random.new(12).bytes(10_000), compress: true}]
    legacy_sections = sections.map do |section|
      section.merge(stored_bytes: Zlib::Deflate.deflate(section[:bytes], Zlib::BEST_COMPRESSION),
        codec: BOMEngine::BOMC::CODEC_DEFLATE)
    end
    expected = container.pack(legacy_sections)
    events = []
    actual = container.pack(sections, checkpoint: ->(**event) { events << event })
    assert_equal expected, actual
    assert_operator events.length, :>, 4, 'compression must poll within a section, not only after it'
    error = BOMEngine::BOMCProcessing::Cancelled.new('cancel container')
    assert_same error, assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
      container.pack(sections, checkpoint: ->(**_) { raise error })
    }
  end

  def test_optional_three_argument_validator_receives_the_live_controller
    received = nil
    stages = []
    context = {
      clock: -> { 0.0 }, cancelled: -> { false }, on_yield: ->(event) { stages << event[:stage] },
      source_info: ->(_) { {bytes: 1000} }, snapshot: ->(_, _) { {} },
      compile: ->(*_) { {bytes: 'compiled', candidate_bytes: 8} },
      validate: lambda { |result, graph = nil, checkpoint = nil|
        received = checkpoint
        checkpoint&.call(stage: :validate, processed: 1, total: 1, force: true)
        {passed: true}
      }
    }
    BOMEngine::BOMCExportJob.run(model: nil, output_path: 'unused',
      settings: BOMEngine::BOMCProcessing.settings(:interactive), context: context)
    assert_kind_of Proc, received, 'optional callback parameter must reach native extension validation'
    assert_operator stages.count(:VALIDATE), :>=, 2
  end

  def test_wide_png_rows_checkpoint_inside_the_row
    optimizer = BOMEngine::BOMCPngOptimizer
    width = 8192
    row = Random.new(12).bytes(width * 4)
    done = []
    actual = optimizer.send(:refilter_adaptive, [row], width, 1, 4, ->(processed, _) { done << processed })
    assert_operator done.first, :<=, 1024, 'one wide PNG row must not monopolize the Fiber'
    assert_equal row.bytesize + 1, actual.bytesize
  end

  def test_scene_polling_does_not_turn_fast_work_into_thousands_of_timer_round_trips
    now = 0.0
    yields = 0
    processed = 0
    controller = BOMEngine::BOMCProcessing::Controller.new(
      settings: BOMEngine::BOMCProcessing.settings(:interactive), clock: -> { now },
      cancelled: -> { false }, on_yield: ->(_) { yields += 1; now += 0.014 })
    cursor = BOMEngine::SceneVisibilityResolver::WorkCursor.new(clock: -> { now }, on_checkpoint: ->(event) {
      processed += event[:work_units]
      controller.checkpoint(stage: :snapshot_entities, processed: processed, total: 0, force: event[:force])
    })
    100_000.times { now += 0.000001; cursor.step('scene_overrides') }
    cursor.flush('scene_overrides')
    assert_equal 100_000, processed
    assert_operator yields, :<=, 20, '100 ms of work must not pay 390 Windows timer waits'
  end

  def graph
    JSON.parse(File.read(File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)), symbolize_names: true)
  end

  def test_decode_and_fidelity_callbacks_preserve_every_decoded_value_and_report
    source = graph
    result = BOMEngine::BOMCWriter.pack(source, profile: :exact)
    bytes = result.fetch(:bytes)
    expected = BOMEngine::BOMCDecoder.decode(bytes)
    events = []
    actual = BOMEngine::BOMCDecoder.decode(bytes, checkpoint: ->(**event) { events << event })
    assert_equal expected, actual
    refute_empty events, 'decode readback must expose cancellation boundaries'
    expected_report = BOMEngine::BOMCValidator.validate_profile(source: source, decoded: actual, profile: :exact)
    events.clear
    report = BOMEngine::BOMCValidator.validate_profile(source: source, decoded: actual, profile: :exact,
      checkpoint: ->(**event) { events << event })
    assert_equal expected_report, report
    refute_empty events
  end

  def test_validation_cancellation_is_not_treated_as_a_compatibility_fallback
    bytes = BOMEngine::BOMCWriter.pack(graph, profile: :exact).fetch(:bytes)
    error = BOMEngine::BOMCProcessing::Cancelled.new('cancel readback')
    caught = assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
      BOMEngine::BOMCDecoder.decode(bytes, checkpoint: ->(**_) { raise error })
    }
    assert_same error, caught
  end

  def test_png_deflate_yields_and_preserves_the_original_compressed_bytes
    optimizer = BOMEngine::BOMCPngOptimizer
    raw = Random.new(12).bytes(512_000)
    expected = [Zlib::DEFAULT_STRATEGY, Zlib::FILTERED].uniq.map do |strategy|
      stream = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, Zlib::MAX_WBITS, Zlib::DEF_MEM_LEVEL, strategy)
      begin
        stream.deflate(raw, Zlib::FINISH)
      ensure
        stream.close
      end
    end.min_by(&:bytesize)
    events = []
    actual = optimizer.send(:deflate_best, raw, ->(done, total) { events << [done, total] })
    assert_equal expected, actual, 'chunking must preserve DEFLATE bytes and tie order'
    assert_operator events.length, :>, 4
    error = BOMEngine::BOMCProcessing::Cancelled.new('cancel PNG')
    assert_same error, assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
      optimizer.send(:deflate_best, raw, ->(*) { raise error })
    }
  end
end
