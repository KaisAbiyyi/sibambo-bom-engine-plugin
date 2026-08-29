# frozen_string_literal: true
# Unit tests for BOMC Profile Benchmark Tool (Batch 0 Baseline)

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

  def test_benchmark_fixture_schema_structure
    result = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      name: 'tiny_test',
      skp_bytes: 10_000
    )

    assert_equal 1, result[:schema_version]
    assert_not_nil result[:producer_sha]
    assert_equal 'tiny_test', result[:source][:name]
    assert_equal 10_000, result[:source][:skp_bytes]

    # Legacy fields
    assert_not_nil result[:legacy][:candidate_bytes]
    assert_operator result[:legacy][:candidate_bytes], :>, 0
    assert_equal 'pass', result[:legacy][:status]
    assert_not_nil result[:legacy][:strategy]
    assert_kind_of Array, result[:legacy][:attempts]

    # Sections map
    assert_kind_of Hash, result[:sections]
    assert result[:sections].key?('model')
    assert result[:sections].key?('strings')

    # Codec metrics
    assert_kind_of Hash, result[:codec_metrics]
    assert result[:codec_metrics].key?(:normals)
    assert result[:codec_metrics].key?(:transforms)
    assert result[:codec_metrics].key?(:topology)

    # Texture metrics
    assert_kind_of Hash, result[:texture_metrics]
    assert_equal 0, result[:texture_metrics][:unique]
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

    json1 = JSON.generate(result1)
    json2 = JSON.generate(result2)

    assert_equal json1, json2, 'Benchmark output must be 100% deterministic across multiple runs'
  end

  def test_legacy_status_transitions
    # When candidate < SKP -> pass
    res_pass = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      skp_bytes: 1_000_000
    )
    assert_equal 'pass', res_pass[:legacy][:status]
    assert_operator res_pass[:legacy][:ratio], :<, 1.0

    # When candidate >= SKP -> over_budget
    res_over = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      skp_bytes: 50
    )
    assert_equal 'over_budget', res_over[:legacy][:status]
    assert_operator res_over[:legacy][:ratio], :>, 1.0

    # When SKP bytes unavailable -> unavailable
    res_unavail = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      skp_bytes: nil
    )
    assert_equal 'unavailable', res_unavail[:legacy][:status]
    assert_nil res_unavail[:legacy][:ratio]
  end

  def test_cli_execution_and_file_outputs
    out_json = File.join(@temp_dir, 'benchmark.json')
    out_md = File.join(@temp_dir, 'benchmark.md')

    payload = BOMEngine::BOMCProfileBenchmark.run([
      '--fixture', @tiny_fixture,
      '--skp-bytes', '50000',
      '--output', out_json,
      '--markdown', out_md
    ])

    assert File.file?(out_json), 'JSON report must be written'
    assert File.file?(out_md), 'Markdown report must be written'

    parsed = JSON.parse(File.read(out_json), symbolize_names: true)
    assert_equal 1, parsed[:schema_version]
    assert_equal 50_000, parsed[:source][:skp_bytes]

    md_content = File.read(out_md)
    assert md_content.include?('BOMC Profile Benchmark: Legacy Baseline Report')
    assert md_content.include?('Section Breakdown')
  end
end
