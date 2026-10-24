require 'minitest/autorun'
require 'tmpdir'
require 'digest'
require_relative '../bomc_extension'
require_relative '../bomc_codecs'
require_relative '../bomc_processing'
require_relative '../bomc_png_optimizer'

class TestCandidate013Cooperation < Minitest::Test
  def test_writer_geometry_uses_monotonic_work_across_codec_counter_resets
    graph = JSON.parse(File.read(File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)), symbolize_names: true)
    expected = BOMEngine::BOMCWriter.pack(graph, profile: :exact)[:bytes]
    geometry = []; recording = false
    actual = BOMEngine::BOMCWriter.pack(graph, profile: :exact, checkpoint: ->(**event) {
      recording = true if event[:operation_label] == 'position candidates'
      geometry << event if recording
      recording = false if event[:stage] == :encode_transforms
    })[:bytes]
    assert_equal expected, actual
    assert_operator geometry.length, :>, 4
    assert_equal geometry.map { |e| e[:processed] }.sort.uniq, geometry.map { |e| e[:processed] }
    assert geometry.all? { |e| e[:total] == 0 && e[:operation_label] }
  end

  def test_parallel_png_compression_preserves_every_strategy_byte_and_owns_cancellation
    optimizer = BOMEngine::BOMCPngOptimizer
    candidates = [{label: :existing, raw: Random.new(13).bytes(1_200_000)},
      {label: :adaptive, raw: ('rgba' * 300_000).b}]
    expected = candidates.map { |candidate| candidate.merge(compressed: optimizer.send(:deflate_best, candidate[:raw], nil)) }
    main_thread = Thread.current; polls = 0
    actual = optimizer.send(:compress_candidates, candidates, ->(*) {
      assert_same main_thread, Thread.current, 'callbacks must remain on the caller'
      polls += 1
    })
    assert_equal expected, actual
    assert_operator polls, :>, 1
    before = Thread.list
    error = BOMEngine::BOMCProcessing::Cancelled.new('stop DEFLATE')
    assert_same error, assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
      optimizer.send(:compress_candidates, candidates, ->(*) { raise error })
    }
    assert_empty Thread.list - before, 'cancelled compression must leave no workers'
  end

  def test_geometry_candidates_poll_inside_large_buffers_without_changing_reports_or_bytes
    count = 4096
    cases = [
      [BOMEngine::BOMC::PositionCodec, Array.new(count) { |i| [i*0.013, i%13*0.1, i%7*0.07] }.flatten, {max_error_m: 0.0}],
      [BOMEngine::BOMC::UVCodec, Array.new(count) { |i| [i*0.013, i%13*0.1] }.flatten, {max_error: 0.0}],
      [BOMEngine::BOMC::NormalCodec, Array.new(count) { |i| [0.0, 0.0, 1.0] }.flatten, {max_error_deg: 0.0}]
    ]
    cases.each do |codec, values, options|
      expected = codec.evaluated_candidates(values, **options)
      events = []
      actual = codec.evaluated_candidates(values, **options, checkpoint: ->(**e) { events << e })
      assert_equal expected, actual, codec.name
      assert_operator events.length, :>, 8, 'must poll within individual candidate evaluation'
      error = BOMEngine::BOMCProcessing::Cancelled.new('stop codec')
      assert_same error, assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
        codec.candidate_objects(values, **options, checkpoint: ->(**_) { raise error })
      }
    end
  end

  def test_checked_attachment_never_probes_a_stale_external_source
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'checked.png'); bytes = 'checked'.b.freeze
      File.binwrite(path, bytes)
      sha = Digest::SHA256.hexdigest(bytes)
      stale = '//offline.invalid/customer/source.png'
      extracted = [{name: 'checked', texture: {filename: 'checked.png', source_path: stale,
        bytes: bytes, sha256: sha, staging_evidence: {policy_revision: 'checked', selected_sha256: sha}}}]
      graph = {materials: [{name: 'checked'}]}; events = []
      original = File.method(:file?)
      File.stub(:file?, ->(p) { raise 'stale path probe' if p == stale; original.call(p) }) do
        BOMEngine::BOMCExtension.send(:attach_staged_textures, graph, extracted, dir, profile: :exact,
          checkpoint: ->(**e) { events << e })
      end
      assert_same bytes, graph[:materials][0][:texture][:bytes]
      assert_nil graph[:materials][0][:texture][:encoding_evidence][:source_bytes]
      refute_empty events
    end
  end

  def test_material_classification_cancellation_is_not_swallowed_by_recursive_rescue
    definition = Struct.new(:entities).new([Object.new])
    entity = Struct.new(:definition).new(definition)
    model = Struct.new(:entities).new([entity])
    calls = 0; error = BOMEngine::BOMCProcessing::Cancelled.new('stop classification')
    assert_same error, assert_raises(BOMEngine::BOMCProcessing::Cancelled) {
      BOMEngine::BOMCExtension.compute_material_classes(model, checkpoint: ->(**_) {
        calls += 1; raise error if calls == 2
      })
    }
  end
end
