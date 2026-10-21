# frozen_string_literal: true
# Cloud-only contract tests: no SketchUp, native SKP, RBZ or producer mutation.
require 'minitest/autorun'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../../tools/performance/trace_harness'

class PerfTraceHarnessTest < Minitest::Test
  FIXTURE = File.expand_path('../../tools/performance/fixtures/synthetic-observation.json', __dir__)
  SCRIPT = File.expand_path('../../tools/performance/trace_harness.rb', __dir__)

  def synthetic
    JSON.parse(File.read(FIXTURE, encoding: 'UTF-8'))
  end

  def native
    row = synthetic
    row['measurement_kind'] = 'native'
    row['run_id'] = 'synthetic-native-shape-only'
    row['environment']['os'] = 'Windows 11'
    row['environment']['sketchup_version'] = '26.2.243'
    row['environment']['ruby_version'] = '3.2.2'
    row['outcome']['fidelity'] = 'pass'
    row['outcome']['peak_rss_bytes'] = 10_000_000
    row['materials'][0]['exact_rgba_alpha_pass'] = true
    row
  end

  def test_synthetic_is_valid_and_cannot_be_counted_as_native
    row = synthetic
    assert_empty SibamboPerf.validate(row)
    refute SibamboPerf.qualified_native?(row)
    report = SibamboPerf.report([row])
    assert_equal 1, report[:synthetic_rows]
    assert_equal 0, report[:qualified_native_rows]
    assert_empty report[:cohorts]
  end

  def test_native_shape_requires_peak_rss_and_full_fidelity
    row = native
    assert_empty SibamboPerf.validate(row)
    assert SibamboPerf.qualified_native?(row)
    row['outcome']['peak_rss_bytes'] = nil
    assert SibamboPerf.validate(row).any? { |e| e.include?('peak_rss_bytes') }
    refute SibamboPerf.qualified_native?(row)
    row = native
    row['outcome']['fidelity'] = 'pending'
    assert_empty SibamboPerf.validate(row)
    refute SibamboPerf.qualified_native?(row)
  end

  def test_legacy_e1_and_research_are_not_new_export_rows
    row = native
    row['export']['wire_engine_id'] = 'e1'
    assert SibamboPerf.validate(row).any? { |e| e.include?('wire_engine_id') }
    row['export']['wire_engine_id'] = 'e2'
    row['export']['profile'] = 'research'
    assert SibamboPerf.validate(row).any? { |e| e.include?('export.profile') }
    assert_equal 'E1 Canonical', SibamboPerf::ENGINE_NAMES.fetch('e2')
    assert_equal 'E2 CleanPKG', SibamboPerf::ENGINE_NAMES.fetch('e3')
    assert_equal 'E3 BOMC', SibamboPerf::ENGINE_NAMES.fetch('e4')
  end

  def test_trace_structure_and_material_accounting_fail_closed
    row = synthetic
    row['trace']['stages'][1]['parent_id'] = 'missing'
    row['materials'][0]['rejected_candidates'] = 3
    row['checkpoints'][1]['elapsed_ms'] = 250
    row['source']['sha256'] = 'not-a-sha'
    problems = SibamboPerf.validate(row)
    assert problems.any? { |e| e.include?('absent/self parent') }
    assert problems.any? { |e| e.include?('rejected more candidates') }
    assert problems.any? { |e| e.include?('out of order') || e.include?('beyond wall_ms') }
    assert problems.any? { |e| e.include?('source.sha256') }
  end

  def test_exclusive_stage_time_avoids_parent_child_double_count
    spans = SibamboPerf.stage_exclusive(synthetic)
    assert_equal [['capture', 35.0], ['image_rep', 65.0], ['compile', 100.0]], spans
    assert_equal 110.0, SibamboPerf.max_gap(synthetic)
  end

  def test_repeated_native_cohort_percentiles_and_matched_speedup
    before = [native, native]
    before[0]['run_id'] = 'before-1'
    before[0]['outcome']['wall_ms'] = 400
    before[1]['run_id'] = 'before-2'
    before[1]['export']['replicate'] = 2
    before[1]['outcome']['wall_ms'] = 500
    after = Marshal.load(Marshal.dump(before))
    after[0]['outcome']['wall_ms'] = 300
    after[1]['outcome']['wall_ms'] = 400
    summary = SibamboPerf.report(before)
    assert_equal 2, summary[:qualified_native_rows]
    assert_equal 1, summary[:cohorts].length
    assert_in_delta 450, summary[:cohorts].first.dig(:wall_ms, :p50), 0.0001
    assert_in_delta 495, summary[:cohorts].first.dig(:wall_ms, :p95), 0.0001
    comparison = SibamboPerf.compare(before, after)
    assert_equal 1, comparison[:paired].size
    assert comparison[:paired].first[:repeated]
    assert_in_delta 22.222, comparison[:paired].first[:speedup_pct], 0.001
    after.each { |row| row['environment']['host_id'] = 'other-host' }
    assert_empty SibamboPerf.compare(before, after)[:paired]
  end

  def test_cli_validates_fixture_but_does_not_print_native_success
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, 'validate', FIXTURE)
    assert status.success?, stderr
    data = JSON.parse(stdout)
    assert_equal 1, data.fetch('valid_rows')
    assert_equal 0, data.fetch('qualified_native_rows')
    assert_equal 1, data.fetch('synthetic_rows')
  end
end
