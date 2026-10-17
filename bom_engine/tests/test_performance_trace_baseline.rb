# frozen_string_literal: true

require 'test/unit'
require_relative '../tools/performance_trace_baseline'

class TestPerformanceTraceBaseline < Test::Unit::TestCase
  def test_trace_on_and_off_keep_identical_bomc_and_emit_named_stages
    root = File.expand_path('../..', __dir__)
    fixture = File.join(root, 'examples', 'model-eval-json-v1-small.json')
    row = BOMEngine::PerformanceTraceBaseline.benchmark_fixture(
      id: 'tiny', fixture_path: fixture, source_skp_bytes: 163_941,
      repetitions: 2, warmup: 0
    )

    assert_equal row[:trace_off][:sha256], row[:trace_on][:sha256]
    assert_equal row[:trace_off][:bytes], row[:trace_on][:bytes]
    assert_operator row[:trace_off][:median_ms], :>=, 0.0
    assert_operator row[:trace_on][:median_ms], :>=, 0.0
    assert_kind_of Numeric, row[:overhead_percent]
    stage_names = row.fetch(:representative_trace).fetch(:stages).map { |stage| stage[:name] }
    assert_include stage_names, 'normalize_graph'
    assert_include stage_names, 'compression'
    assert_include stage_names, 'decode_readback'
    assert_include stage_names, 'fidelity_validation'
  end
end
