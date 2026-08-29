# frozen_string_literal: true
# Unit tests for BOMC Profile Benchmark Tool (Batch 14 — Three Profile Benchmark)

require 'test/unit'
require 'json'
require 'fileutils'
require 'tmpdir'
require_relative '../tools/bomc_profile_benchmark'

class TestBOMCProfileBenchmark < Test::Unit::TestCase
  def setup
    @root = File.expand_path('../..', __dir__)
    @tiny_fixture = File.join(@root, 'examples', 'model-eval-json-v1-small.json')
    raise "Tiny fixture missing: #{@tiny_fixture}" unless File.file?(@tiny_fixture)
    @temp_dir = Dir.mktmpdir('bomc_profile_bm_test')
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.directory?(@temp_dir)
  end

  def test_benchmark_fixture_three_profiles_structure
    result = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      name: 'tiny_test',
      category: 'tiny',
      skp_bytes: 10_000
    )

    assert_equal 'tiny_test', result[:id]
    assert_equal 'tiny', result[:category]
    assert_equal 10_000, result[:source_skp_bytes]
    assert_equal [:exact, :research, :visual], result[:profiles].keys.sort

    # Visual profile checks
    visual = result[:profiles][:visual]
    assert_equal 'visual', visual[:profile]
    assert_equal 'pass', visual[:status]
    assert_operator visual[:bomc_bytes], :>, 0
    assert_operator visual[:ratio], :<=, 0.90
    assert_operator visual[:encode_time_ms], :>=, 0
    assert_operator visual[:decode_time_ms], :>=, 0
    assert visual[:invariants][:semantics_pass]
    assert visual[:invariants][:scenes_pass]
    assert visual[:invariants][:clip_planes_pass]
    assert visual[:invariants][:protected_topology_pass]

    # Exact profile checks
    exact = result[:profiles][:exact]
    assert_equal 'exact', exact[:profile]
    assert_equal 'pass', exact[:status]
    assert_equal 0.0, exact[:metrics][:position_max_error_m]
    assert_equal 0.0, exact[:metrics][:normal_max_error_deg]
  end

  def test_deterministic_output_across_runs
    result1 = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      name: 'tiny_box',
      skp_bytes: 5_000
    )

    result2 = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      name: 'tiny_box',
      skp_bytes: 5_000
    )

    # Encode time can vary slightly, compare structure, sizes and metrics
    [:exact, :research, :visual].each do |p|
      assert_equal result1[:profiles][p][:bomc_bytes], result2[:profiles][p][:bomc_bytes]
      assert_equal result1[:profiles][p][:ratio], result2[:profiles][p][:ratio]
      assert_equal result1[:profiles][p][:metrics], result2[:profiles][p][:metrics]
      assert_equal result1[:profiles][p][:invariants], result2[:profiles][p][:invariants]
    end
  end

  def test_budget_transitions
    # Over budget scenario for visual/research when SKP is minuscule
    res_over = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      skp_bytes: 50
    )
    assert_equal 'over_budget', res_over[:profiles][:visual][:status]
    assert_equal 'over_budget', res_over[:profiles][:research][:status]
    # Exact has no size guarantee, always pass
    assert_equal 'pass', res_over[:profiles][:exact][:status]
  end

  def test_report_generation_and_markdown
    results = [
      BOMEngine::BOMCProfileBenchmark.benchmark_fixture(@tiny_fixture, name: 'tiny_test', category: 'tiny', skp_bytes: 100_000)
    ]
    report = BOMEngine::BOMCProfileBenchmark.generate_report(results)
    assert_equal '1.2.0', report[:schema_version]
    assert_equal 1, report[:aggregates][:total_fixtures]
    assert_equal 3, report[:aggregates][:total_runs]
    assert_equal 3, report[:aggregates][:passed_runs]

    md = BOMEngine::BOMCProfileBenchmark.render_markdown(report)
    assert md.include?('# BOMC 1.2 Three-Profile Corpus Benchmark Report')
    assert md.include?('Aggregate Performance Summary')
    assert md.include?('tiny_test')
  end
end
