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
    assert_equal 'pass', visual[:validation_status]
    assert_equal [], visual[:missing_evidence]
    assert_operator visual[:bomc_bytes], :>, 0
    assert_operator visual[:ratio], :<=, 0.90
    assert_operator visual[:encode_time_ms], :>=, 0
    assert_operator visual[:decode_time_ms], :>=, 0
    assert visual[:invariants][:semantics_pass]
    assert visual[:invariants][:scenes_pass]
    assert visual[:invariants][:clip_planes_pass]
    assert visual[:invariants][:protected_topology_pass]
    geometry_frontiers = visual[:metrics][:geometry_candidate_frontiers]
    assert_kind_of Hash, geometry_frontiers
    assert_operator geometry_frontiers[:positions].first[:candidates].length, :>, 1
    assert_operator geometry_frontiers[:positions].first[:pareto_candidate_ids].length, :>, 1

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

  def test_validation_failure_never_passes
    validator = BOMEngine::BOMCValidator
    original = validator.method(:validate!)
    validator.define_singleton_method(:validate!) { |*| raise 'controlled fidelity failure' }
    result = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(@tiny_fixture, skp_bytes: 100_000)
    result.fetch(:profiles).each_value do |row|
      assert_equal 'validation_failed', row.fetch(:status)
      assert_equal 'failed', row.fetch(:validation_status)
      assert_nil row.fetch(:metrics).fetch(:position_max_error_m)
      assert_equal false, row.fetch(:invariants).fetch(:protected_topology_pass)
      assert_include row.fetch(:missing_evidence), 'validation: controlled fidelity failure'
    end
  ensure
    validator.define_singleton_method(:validate!, original) if original
  end

  def test_missing_required_fixture_is_explicitly_incomplete
    corpus_path = File.join(@temp_dir, 'corpus.json')
    File.write(corpus_path, JSON.generate({
      schema_version: 2,
      items: [{
        id: 'required-but-missing',
        category: 'negative-case',
        model_eval_fixture: 'fixtures/does-not-exist.json',
        required_for_release: true
      }]
    }))

    results = BOMEngine::BOMCProfileBenchmark.run_corpus(corpus_path)
    assert_equal 1, results.length
    fixture = results.first
    assert_equal 'incomplete', fixture[:status]
    assert_include fixture[:missing_evidence], 'model_eval_fixture: fixtures/does-not-exist.json'
    assert_equal [:exact, :research, :visual], fixture[:profiles].keys.sort
    fixture[:profiles].each_value do |row|
      assert_equal 'incomplete', row[:status]
      assert_equal 'not_run', row[:validation_status]
      assert_nil row.dig(:metrics, :position_max_error_m)
    end

    report = BOMEngine::BOMCProfileBenchmark.generate_report(results)
    assert_equal 'incomplete', report[:certification_status]
    assert_nothing_raised { BOMEngine::BOMCProfileBenchmark.render_markdown(report) }
  end

  def test_missing_required_source_feature_is_incomplete_not_pass
    result = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(
      @tiny_fixture,
      skp_bytes: 100_000,
      expected_features: { textures: 1, scenes: 1 }
    )

    result[:profiles].each_value do |row|
      assert_equal 'incomplete', row[:status]
      assert_equal 'pass', row[:validation_status]
      assert_include row[:missing_evidence], 'source_textures: expected >= 1, got 0'
      assert_include row[:missing_evidence], 'source_scenes: expected >= 1, got 0'
    end
    assert_equal 'incomplete', result[:status]
  end

  def test_same_scene_count_with_different_visibility_mask_fails
    scene_fixture = File.join(@temp_dir, 'scene-mask.json')
    graph = JSON.parse(File.read(@tiny_fixture))
    graph['scenes'] = [{
      'id' => 'scene:test',
      'name' => 'Test',
      'camera' => {
        'eye_m' => [1, 2, 3],
        'target_m' => [0, 0, 0],
        'up' => [0, 0, 1],
        'field_of_view_degrees' => 35,
        'aspect_ratio' => 1.5
      },
      'visibility' => {
        'visible_tag_ids' => ['tag:0'],
        'hidden_tag_ids' => []
      }
    }]
    File.write(scene_fixture, JSON.generate(graph))

    decoder = BOMEngine::BOMCDecoder
    original = decoder.method(:decode)
    decoder.define_singleton_method(:decode) do |bytes|
      decoded = original.call(bytes)
      decoded[:scenes][0][:visibility][:visible_tag_indices] = []
      decoded
    end

    result = BOMEngine::BOMCProfileBenchmark.benchmark_fixture(scene_fixture, skp_bytes: 100_000)
    result.fetch(:profiles).each_value do |row|
      assert_equal 'validation_failed', row[:status]
      assert_equal 'failed', row[:validation_status]
      assert_equal false, row.dig(:invariants, :scenes_pass)
      assert_include row[:missing_evidence], 'scenes: identity or visibility mismatch'
    end
  ensure
    decoder.define_singleton_method(:decode, original) if original
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

  def test_summarize_bundle_for_git_compacts_frontiers
    results = [
      BOMEngine::BOMCProfileBenchmark.benchmark_fixture(@tiny_fixture, name: 'tiny_test', category: 'tiny', skp_bytes: 100_000)
    ]
    report = BOMEngine::BOMCProfileBenchmark.generate_report(results)
    raw_frontiers = report[:fixtures].first.dig(:profiles, :visual, :metrics, :geometry_candidate_frontiers)
    assert_kind_of Hash, raw_frontiers
    assert_operator raw_frontiers[:positions].first[:candidates].length, :>, 1

    compact = BOMEngine::BOMCProfileBenchmark.summarize_bundle_for_git(report)

    # Original report remains untouched
    assert_operator report[:fixtures].first.dig(:profiles, :visual, :metrics, :geometry_candidate_frontiers, :positions).first[:candidates].length, :>, 1

    # Compact report has summarized metrics
    compact_frontiers = compact[:fixtures].first.dig(:profiles, :visual, :metrics, :geometry_candidate_frontiers)
    assert_kind_of Hash, compact_frontiers
    assert_kind_of Hash, compact_frontiers[:positions]
    assert_equal 1, compact_frontiers[:positions][:mesh_count]
    assert_operator compact_frontiers[:positions][:total_candidates], :>, 1
    assert_operator compact_frontiers[:positions][:total_pareto_candidates], :>, 1
    assert_nil compact_frontiers[:positions][:candidates]
  end

  def test_8082541_baseline_manifest_pins_pair_and_artifact_digests
    manifest_path = File.join(@root, 'bom_engine', 'benchmarks', 'baselines', '8082541', 'manifest.json')
    manifest = JSON.parse(File.read(manifest_path))

    assert_equal 'incomplete', manifest['certification_status']
    assert_equal '8082541d852cd68b9874231e41c6b9c967c74d26', manifest.dig('source_revisions', 'producer', 'sha')
    assert_equal 'd49270130502ce676c0ba5a9a7bb13f1e913c1c8', manifest.dig('source_revisions', 'consumer', 'sha')
    assert_equal false, manifest.dig('checkout', 'path_protection_disabled')

    manifest.fetch('artifacts').each do |artifact|
      assert_match(/\A[0-9a-f]{64}\z/, artifact.fetch('sha256'))
    end
    corpus = manifest.fetch('artifacts').find { |artifact| artifact['id'] == 'fail-closed-profile-corpus' }
    corpus_path = File.join(@root, corpus.fetch('path'))
    assert_equal corpus.fetch('bytes'), File.size(corpus_path)
    assert_equal corpus.fetch('sha256'), Digest::SHA256.file(corpus_path).hexdigest
  end

  def test_evolution_corpus_manifest_structure_and_integrity
    corpus_path = File.join(@root, 'bom_engine', 'benchmarks', 'evolution-corpus.json')
    assert File.file?(corpus_path), 'evolution-corpus.json must exist'

    corpus = JSON.parse(File.read(corpus_path), symbolize_names: true)
    assert_equal 3, corpus[:schema_version]
    assert_equal 'sibambo-evolution-corpus-v3', corpus[:corpus_id]
    assert_kind_of Hash, corpus[:analytical_tolerances]
    assert_equal [:exact, :research, :visual], corpus[:analytical_tolerances].keys.sort

    categories = corpus[:items].map { |i| i[:category] }
    expected_categories = ['tiny', 'small-textured', 'medium-architectural', 'complex-architectural', 'texture-heavy', 'scene-heavy', 'section-cut-heavy']
    assert_equal expected_categories.sort, categories.sort

    corpus[:items].each do |item|
      assert item[:id], 'item must have id'
      assert item[:category], 'item must have category'
      assert item[:provenance], 'item must have provenance'
      assert ['unit_synthetic', 'sketchup_capture'].include?(item.dig(:provenance, :kind)), 'provenance kind must be unit_synthetic or sketchup_capture'
      assert item[:skp_path], 'item must have skp_path'
      assert_match(/\A[0-9a-f]{64}\z/, item[:skp_sha256], 'item must have valid skp_sha256')
      assert item[:model_eval_fixture], 'item must have model_eval_fixture'
      assert_match(/\A[0-9a-f]{64}\z/, item[:fixture_sha256], 'item must have valid fixture_sha256')
      assert_equal ['exact', 'research', 'visual'], item[:supported_profiles].sort
      assert item[:minimum_source_counts], 'item must have minimum_source_counts'
      assert item[:visual_classification], 'item must have visual_classification'
      assert ['A', 'B', 'C'].include?(item.dig(:visual_classification, :visual_class)), 'visual_class must be A, B, or C'
      assert [true, false].include?(item.dig(:visual_classification, :mixed_material)), 'mixed_material must be boolean'

      fixture_full = File.join(@root, item[:model_eval_fixture])
      assert File.file?(fixture_full), "model_eval_fixture must exist on disk: #{item[:model_eval_fixture]}"
      assert_equal item[:fixture_sha256], Digest::SHA256.file(fixture_full).hexdigest, "fixture_sha256 mismatch for #{item[:id]}"
    end

    # Verify texture assets integrity
    assert_kind_of Array, corpus[:texture_assets]
    assert_equal 4, corpus[:texture_assets].length
    corpus[:texture_assets].each do |tex|
      tex_path = File.join(@root, tex[:path])
      assert File.file?(tex_path), "texture file must exist on disk: #{tex[:path]}"
      assert_equal tex[:sha256], Digest::SHA256.file(tex_path).hexdigest, "texture sha256 mismatch for #{tex[:id]}"
    end

    # Verify baseline captures
    assert_kind_of Array, corpus[:verified_baseline_captures]
    rumah_l = corpus[:verified_baseline_captures].select { |c| c[:model] == 'RUMAH L' }
    assert_equal 3, rumah_l.length
    assert_equal ['exact', 'research', 'visual'], rumah_l.map { |c| c[:profile] }.sort

    rumah_g = corpus[:verified_baseline_captures].select { |c| c[:model] == 'RUMAH G' }
    assert_equal 3, rumah_g.length
    assert_equal 1, rumah_g.count { |c| c[:profile] == 'exact' && c[:availability] == 'local_untracked' }
    assert_equal 2, rumah_g.count { |c| ['research', 'visual'].include?(c[:profile]) && c[:availability] == 'missing' && c[:status] == 'incomplete' }
  end

  def test_evolution_corpus_runs_and_passes_all_profiles
    corpus_path = File.join(@root, 'bom_engine', 'benchmarks', 'evolution-corpus.json')
    results = BOMEngine::BOMCProfileBenchmark.run_corpus(corpus_path)
    assert_equal 7, results.length

    results.each do |r|
      assert_equal 'pass', r[:status], "fixture #{r[:id]} expected to pass, got #{r[:status]} (missing: #{r[:missing_evidence].inspect})"
      assert_equal 'pass', r[:validation_status]
      assert_empty r[:missing_evidence]
      [:exact, :research, :visual].each do |prof|
        assert_equal 'pass', r.dig(:profiles, prof, :status), "profile #{prof} for #{r[:id]} failed"
      end
    end

    report = BOMEngine::BOMCProfileBenchmark.generate_report(results)
    assert_equal 'ready', report[:certification_status]
    assert_equal 21, report.dig(:aggregates, :passed_runs)
    assert_equal 21, report.dig(:aggregates, :total_runs)
  end
end
