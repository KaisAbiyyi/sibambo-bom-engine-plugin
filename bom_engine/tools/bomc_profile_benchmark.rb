# frozen_string_literal: true
# BOMC Profile Benchmark Tool (Batch 14)
# Comprehensive evaluation of exact, research, and visual profiles across the corpus.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'time'
require_relative '../bomc_format'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'
require_relative '../bomc_profile'
require_relative '../tools/export_fidelity_manifest'

module BOMEngine
  module BOMCProfileBenchmark
    PINNED_PRODUCER_SHA = '529daa3b3e31a15751765023dc14ff59061f531d'

    module_function

    def producer_sha
      sha = `git rev-parse HEAD 2>nul`.strip rescue ''
      sha.empty? ? PINNED_PRODUCER_SHA : sha
    end

    def sanitize_for_json(value)
      case value
      when Float
        if value.infinite?
          value.positive? ? 'Infinity' : '-Infinity'
        elsif value.nan?
          'NaN'
        else
          value.round(6)
        end
      when Hash
        value.each_with_object({}) do |(k, v), h|
          h[k] = sanitize_for_json(v)
        end
      when Array
        value.map { |v| sanitize_for_json(v) }
      else
        value
      end
    end

    def benchmark_fixture(fixture_path, name: nil, category: nil, skp_bytes: nil, skp_path: nil, expected_features: nil, require_source_skp: false)
      raise "Fixture not found: #{fixture_path}" unless File.file?(fixture_path)

      raw_json = File.binread(fixture_path)
      graph = JSON.parse(raw_json.force_encoding(Encoding::UTF_8), symbolize_names: true)
      base_path = File.dirname(fixture_path)

      effective_skp_bytes = skp_bytes
      if effective_skp_bytes.nil? && skp_path && File.file?(skp_path)
        effective_skp_bytes = File.size(skp_path)
      end

      profiles_results = {}

      [:exact, :research, :visual].each do |profile|
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pack_res = BOMCWriter.pack(
          graph,
          profile: profile,
          base_path: base_path,
          source_skp_bytes: effective_skp_bytes
        )
        encode_time_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(2)

        bomc_bytes = pack_res[:bytes].bytesize
        ratio = effective_skp_bytes && effective_skp_bytes > 0 ? (bomc_bytes.to_f / effective_skp_bytes).round(4) : nil

        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        decoded = BOMCDecoder.decode(pack_res[:bytes])
        decode_time_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000.0).round(2)

        # Differential validation
        validation = nil
        validation_error = nil
        begin
          validation = BOMCValidator.validate!(graph, decoded)
        rescue StandardError => e
          validation_error = e.message
        end

        # Fidelity manifest check
        normalized = BOMEngine::BOMC::ModelAdapter.normalize(graph, base_path: base_path)
        manifest_raw = ExportFidelityManifest.build_manifest_from_normalized(
          normalized,
          profile: profile.to_s
        )

        scenes_pass = scenes_match?(normalized[:scenes], decoded[:scenes])
        clip_planes_pass = clip_planes_match?(normalized[:clip_planes], decoded[:clip_planes])
        validator_pass = positive_validation?(validation) && validation_error.nil?
        validation_pass = validator_pass && scenes_pass && clip_planes_pass
        missing_evidence = []
        missing_evidence << "validation: #{validation_error}" if validation_error
        missing_evidence << 'validation: incomplete positive result' if validation_error.nil? && !validator_pass
        missing_evidence << 'scenes: identity or visibility mismatch' unless scenes_pass
        missing_evidence << 'clip_planes: identity mismatch' unless clip_planes_pass
        missing_evidence.concat(required_evidence_gaps(normalized, expected_features, require_source_skp, effective_skp_bytes))

        positions_err = validation_pass ? validation[:positions] : nil
        normals_err = validation_pass ? validation[:normals] : nil
        uv_err = validation_pass ? validation[:uv] : nil
        transforms_err = validation_pass ? validation[:transforms] : nil

        # Check hard budgets
        status = if !validation_pass
          'validation_failed'
        elsif !missing_evidence.empty?
          'incomplete'
        elsif profile == :exact
          'pass'
        elsif ratio && ratio <= 0.90
          'pass'
        else
          'over_budget'
        end

        profiles_results[profile] = {
          profile: profile.to_s,
          status: status,
          validation_status: validation_pass ? 'pass' : 'failed',
          missing_evidence: missing_evidence,
          bomc_bytes: bomc_bytes,
          ratio: ratio,
          encode_time_ms: encode_time_ms,
          decode_time_ms: decode_time_ms,
          metrics: {
            position_max_error_m: positions_err && positions_err[:max_error_m],
            position_p95_error_m: positions_err && positions_err[:p95_error_m],
            position_rms_error_m: positions_err && positions_err[:rms_error_m],
            normal_max_error_deg: normals_err && normals_err[:max_angular_error_deg],
            uv_max_error: uv_err && uv_err[:max_error],
            transform_max_error: transforms_err && transforms_err[:max_error],
            geometry_candidate_frontiers: pack_res.dig(:metrics, :geometry_candidate_frontiers)
          },
          invariants: {
            semantics_pass: validator_pass && validation.dig(:instances, :exact) == true,
            scenes_pass: scenes_pass,
            clip_planes_pass: clip_planes_pass,
            protected_topology_pass: validator_pass && validation.dig(:topology, :exact) == true
          },
          counts: {
            materials: decoded[:materials].length,
            tags: decoded[:tags].length,
            meshes: decoded[:meshes].length,
            faces: decoded[:meshes].inject(0) { |sum, m| sum + m[:faces].length },
            triangles: decoded[:meshes].inject(0) { |sum, m| sum + m[:faces].inject(0) { |s, f| s + f[:triangles].length / 3 } },
            instances: decoded[:instances].length,
            definitions: decoded[:definitions].length,
            textures: decoded[:textures].length,
            scenes: decoded[:scenes].length,
            clip_planes: decoded[:clip_planes].length
          }
        }
      end

      statuses = profiles_results.values.map { |row| row[:status] }
      fixture_status = if statuses.include?('validation_failed')
        'validation_failed'
      elsif statuses.include?('incomplete')
        'incomplete'
      elsif statuses.all? { |status| status == 'pass' }
        'pass'
      else
        'failed'
      end

      {
        id: name || File.basename(fixture_path, '.*'),
        category: category || 'general',
        status: fixture_status,
        validation_status: profiles_results.values.all? { |row| row[:validation_status] == 'pass' } ? 'pass' : 'failed',
        missing_evidence: profiles_results.values.flat_map { |row| row[:missing_evidence] }.uniq,
        fixture_path: fixture_path,
        skp_path: skp_path,
        source_skp_bytes: effective_skp_bytes,
        profiles: profiles_results
      }
    end

    def positive_validation?(validation)
      validation.is_a?(Hash) &&
        validation.dig(:counts, :exact) == true &&
        validation.dig(:materials, :exact) == true &&
        validation.dig(:tags, :exact) == true &&
        validation.dig(:definitions, :exact) == true &&
        validation.dig(:instances, :exact) == true &&
        validation.dig(:fallback, :exact) == true &&
        validation.dig(:topology, :exact) == true &&
        validation.dig(:positions, :passed) == true &&
        validation.dig(:normals, :passed) == true &&
        validation.dig(:uv, :passed) == true &&
        validation.dig(:transforms, :passed) == true &&
        validation.dig(:areas, :passed) == true &&
        validation.dig(:visual_edges, :exact) == true &&
        validation.dig(:textures, :exact) == true &&
        validation.dig(:coverage, :unaccounted) == 0
    end

    def scenes_match?(source_scenes, decoded_scenes)
      source = Array(source_scenes)
      decoded = Array(decoded_scenes)
      return decoded.empty? || (decoded.length == 1 && decoded[0][:source] == 'legacy-synthetic') if source.empty?
      return false unless source.length == decoded.length

      visibility_keys = [
        :visible_tag_indices, :hidden_tag_indices,
        :visible_node_indices, :hidden_node_indices,
        :visible_face_indices, :hidden_face_indices,
        :visible_edge_indices, :hidden_edge_indices
      ]
      source.each_with_index.all? do |scene, index|
        row = decoded[index]
        row && scene[:stable_id].to_s == row[:id].to_s && visibility_keys.all? do |key|
          Array(scene.dig(:visibility, key)) == Array(row.dig(:visibility, key))
        end
      end
    end

    def clip_planes_match?(source_planes, decoded_planes)
      source = Array(source_planes)
      decoded = Array(decoded_planes)
      return false unless source.length == decoded.length

      source.each_with_index.all? do |plane, index|
        row = decoded[index]
        row && plane[:stable_id].to_s == (row[:stable_id] || row[:id]).to_s
      end
    end

    def required_evidence_gaps(normalized, expected_features, require_source_skp, source_skp_bytes)
      gaps = []
      gaps << 'source_skp: missing' if require_source_skp && (!source_skp_bytes || source_skp_bytes <= 0)
      expected = expected_features || {}
      counts = source_feature_counts(normalized)
      expected.each do |key, minimum|
        actual = counts[key.to_sym]
        gaps << "source_#{key}: expected >= #{minimum}, got #{actual || 0}" if actual.nil? || actual < minimum.to_i
      end
      gaps
    end

    def source_feature_counts(normalized)
      materials = Array(normalized[:materials])
      instances = Array(normalized[:instances])
      meshes = Array(normalized[:meshes])
      texture_hashes = materials.map { |row| row.dig(:texture, :sha256) }
      texture_hashes.concat(instances.map { |row| row.dig(:fallback, :texture, :sha256) })
      {
        materials: materials.length,
        tags: Array(normalized[:tags]).length,
        meshes: meshes.length,
        faces: meshes.sum { |mesh| Array(mesh[:faces]).length },
        instances: instances.length,
        definitions: Array(normalized[:definitions]).length,
        textures: texture_hashes.compact.uniq.length,
        scenes: Array(normalized[:scenes]).length,
        clip_planes: Array(normalized[:clip_planes]).length
      }
    end

    def empty_profile_row(profile, status:, missing_evidence:)
      {
        profile: profile.to_s,
        status: status,
        validation_status: 'not_run',
        missing_evidence: missing_evidence,
        bomc_bytes: nil,
        ratio: nil,
        encode_time_ms: nil,
        decode_time_ms: nil,
        metrics: {
          position_max_error_m: nil,
          position_p95_error_m: nil,
          position_rms_error_m: nil,
          normal_max_error_deg: nil,
          uv_max_error: nil,
          transform_max_error: nil,
          geometry_candidate_frontiers: nil
        },
        invariants: {
          semantics_pass: false,
          scenes_pass: false,
          clip_planes_pass: false,
          protected_topology_pass: false
        },
        counts: nil
      }
    end

    def missing_fixture_result(item, fixture_rel)
      missing = ["model_eval_fixture: #{fixture_rel || 'not declared'}"]
      status = item[:required_for_release] == false ? 'skipped' : 'incomplete'
      profiles = [:exact, :research, :visual].each_with_object({}) do |profile, rows|
        rows[profile] = empty_profile_row(profile, status: status, missing_evidence: missing)
      end
      {
        id: item[:id],
        category: item[:category] || 'general',
        status: status,
        validation_status: 'not_run',
        missing_evidence: missing,
        fixture_path: fixture_rel,
        skp_path: item[:skp_path],
        source_skp_bytes: nil,
        profiles: profiles
      }
    end

    def run_corpus(corpus_manifest_path)
      manifest = JSON.parse(File.read(corpus_manifest_path), symbolize_names: true)
      root = File.expand_path('../..', __dir__)
      results = []

      Array(manifest[:items]).each do |item|
        fixture_rel = item[:model_eval_fixture]
        unless fixture_rel
          results << missing_fixture_result(item, fixture_rel)
          next
        end

        # Resolve fixture path in plugin or in model-eval
        fixture_path = File.join(root, fixture_rel)
        unless File.file?(fixture_path)
          fixture_path = File.expand_path(File.join(root, '..', 'model-eval', fixture_rel))
        end
        unless File.file?(fixture_path)
          results << missing_fixture_result(item, fixture_rel)
          next
        end

        skp_rel = item[:skp_path]
        skp_path = File.join(root, skp_rel) if skp_rel
        if skp_path && !File.file?(skp_path)
          skp_path = File.expand_path(File.join(root, '..', 'model-eval', skp_rel))
        end
        skp_bytes = skp_path && File.file?(skp_path) ? File.size(skp_path) : nil

        warn "[BENCHMARK] Running fixture: #{item[:id]} (#{item[:category]})..."
        res = benchmark_fixture(
          fixture_path,
          name: item[:id],
          category: item[:category],
          skp_bytes: skp_bytes,
          skp_path: skp_path,
          expected_features: item[:minimum_source_counts],
          require_source_skp: item[:required_for_release] == true
        )
        results << res
      end

      results
    end

    def generate_report(results)
      visual_ratios = results.map { |r| r.dig(:profiles, :visual, :ratio) }.compact.sort
      research_ratios = results.map { |r| r.dig(:profiles, :research, :ratio) }.compact.sort
      exact_ratios = results.map { |r| r.dig(:profiles, :exact, :ratio) }.compact.sort

      visual_times = results.map { |r| r.dig(:profiles, :visual, :encode_time_ms) }.compact.sort
      total_runs = results.length * 3
      passed_runs = results.inject(0) do |sum, r|
        sum + r[:profiles].values.count { |p| p[:status] == 'pass' }
      end

      median = ->(arr) { arr.empty? ? 0 : arr[arr.length / 2] }
      mean = ->(arr) { arr.empty? ? 0 : (arr.sum / arr.length.to_f).round(4) }
      p95 = ->(arr) { arr.empty? ? 0 : arr[(arr.length * 0.95).floor] }

      aggregates = {
        total_fixtures: results.length,
        total_runs: total_runs,
        passed_runs: passed_runs,
        incomplete_fixtures: results.count { |row| row[:status] != 'pass' },
        visual_profile: {
          min_ratio: visual_ratios.first,
          median_ratio: median.call(visual_ratios),
          mean_ratio: mean.call(visual_ratios),
          p95_ratio: p95.call(visual_ratios),
          worst_ratio: visual_ratios.last,
          median_encode_time_ms: median.call(visual_times),
          max_position_error_m: results.map { |r| r.dig(:profiles, :visual, :metrics, :position_max_error_m) }.compact.max,
          max_normal_error_deg: results.map { |r| r.dig(:profiles, :visual, :metrics, :normal_max_error_deg) }.compact.max,
          max_uv_error: results.map { |r| r.dig(:profiles, :visual, :metrics, :uv_max_error) }.compact.max,
          max_transform_error: results.map { |r| r.dig(:profiles, :visual, :metrics, :transform_max_error) }.compact.max
        },
        research_profile: {
          min_ratio: research_ratios.first,
          median_ratio: median.call(research_ratios),
          mean_ratio: mean.call(research_ratios),
          p95_ratio: p95.call(research_ratios),
          worst_ratio: research_ratios.last,
          max_position_error_m: results.map { |r| r.dig(:profiles, :research, :metrics, :position_max_error_m) }.compact.max,
          max_normal_error_deg: results.map { |r| r.dig(:profiles, :research, :metrics, :normal_max_error_deg) }.compact.max,
          max_uv_error: results.map { |r| r.dig(:profiles, :research, :metrics, :uv_max_error) }.compact.max,
          max_transform_error: results.map { |r| r.dig(:profiles, :research, :metrics, :transform_max_error) }.compact.max
        },
        exact_profile: {
          min_ratio: exact_ratios.first,
          median_ratio: median.call(exact_ratios),
          mean_ratio: mean.call(exact_ratios),
          p95_ratio: p95.call(exact_ratios),
          worst_ratio: exact_ratios.last
        }
      }

      {
        schema_version: '1.2.0',
        producer_sha: producer_sha,
        timestamp: Time.now.utc.iso8601,
        certification_status: results.all? { |row| row[:status] == 'pass' } ? 'ready' : 'incomplete',
        missing_evidence: results.flat_map { |row| row[:missing_evidence] || [] }.uniq,
        aggregates: aggregates,
        fixtures: results
      }
    end

    def render_markdown(bundle)
      agg = bundle[:aggregates]
      v_agg = agg[:visual_profile]
      r_agg = agg[:research_profile]
      e_agg = agg[:exact_profile]

      lines = []
      lines << '# BOMC 1.2 Three-Profile Corpus Benchmark Report'
      lines << ''
      lines << "- **Producer SHA:** `#{bundle[:producer_sha]}`"
      lines << "- **Generated At:** #{bundle[:timestamp]}"
      lines << "- **Total Fixtures:** #{agg[:total_fixtures]}"
      lines << "- **Certification Status:** **#{bundle[:certification_status].to_s.upcase}**"
      lines << "- **Profile Runs Passed:** #{agg[:passed_runs]}/#{agg[:total_runs]}"
      unless Array(bundle[:missing_evidence]).empty?
        lines << "- **Missing Evidence:** #{Array(bundle[:missing_evidence]).join('; ')}"
      end
      lines << ''
      lines << '## Aggregate Performance Summary'
      lines << ''
      lines << '| Profile | Target / Budget | Min Ratio | Median Ratio | Mean Ratio | p95 Ratio | Worst Ratio | Max Pos Err (m) | Max Normal Err (deg) | Invariants Pass |'
      lines << '|---|---|---|---|---|---|---|---|---|---|'
      lines << "| **Visual** (Recommended) | ~60% target / 90% hard | #{format_percent(v_agg[:min_ratio])} | #{format_percent(v_agg[:median_ratio])} | #{format_percent(v_agg[:mean_ratio])} | #{format_percent(v_agg[:p95_ratio])} | #{format_percent(v_agg[:worst_ratio])} | #{format_metric(v_agg[:max_position_error_m])} | #{format_metric(v_agg[:max_normal_error_deg])} | #{profile_invariant_summary(bundle, :visual)} |"
      lines << "| **Research** (Bounded) | 90% hard ceiling | #{format_percent(r_agg[:min_ratio])} | #{format_percent(r_agg[:median_ratio])} | #{format_percent(r_agg[:mean_ratio])} | #{format_percent(r_agg[:p95_ratio])} | #{format_percent(r_agg[:worst_ratio])} | #{format_metric(r_agg[:max_position_error_m])} | #{format_metric(r_agg[:max_normal_error_deg])} | #{profile_invariant_summary(bundle, :research)} |"
      lines << "| **Exact** (Reference) | No size guarantee | #{format_percent(e_agg[:min_ratio])} | #{format_percent(e_agg[:median_ratio])} | #{format_percent(e_agg[:mean_ratio])} | #{format_percent(e_agg[:p95_ratio])} | #{format_percent(e_agg[:worst_ratio])} | #{format_metric(results_metric_max(bundle, :exact, :position_max_error_m))} | #{format_metric(results_metric_max(bundle, :exact, :normal_max_error_deg))} | #{profile_invariant_summary(bundle, :exact)} |"
      lines << ''
      lines << '## Corpus Fixture Breakdown'
      lines << ''
      lines << '| Fixture | Category | SKP Size | Visual BOMC (Ratio) | Research BOMC (Ratio) | Exact BOMC (Ratio) | Textures | Scenes | Triangles |'
      lines << '|---|---|---|---|---|---|---|---|---|'

      bundle[:fixtures].each do |f|
        skp_str = format_bytes(f[:source_skp_bytes])
        v_res = f[:profiles][:visual]
        r_res = f[:profiles][:research]
        e_res = f[:profiles][:exact]

        v_str = format_profile_result(v_res)
        r_str = format_profile_result(r_res)
        e_str = format_profile_result(e_res)

        counts = v_res[:counts] || {}
        lines << "| `#{f[:id]}` | #{f[:category]} | #{skp_str} | #{v_str} | #{r_str} | #{e_str} | #{format_metric(counts[:textures])} | #{format_metric(counts[:scenes])} | #{format_metric(counts[:triangles])} |"
      end

      lines << ''
      lines << '## Evidence Notes'
      lines << ''
      lines << '- A profile passes only when validator output is positive, scene/clip evidence matches, and its size budget applies.'
      lines << '- Missing required fixtures or source features keep certification incomplete; missing metrics remain null.'
      lines << ''

      lines.join("\n")
    end

    def format_percent(value)
      value.nil? ? '-' : "#{(value * 100).round(1)}%"
    end

    def format_metric(value)
      value.nil? ? '-' : value
    end

    def format_profile_result(row)
      return '-' unless row
      ratio = format_percent(row[:ratio])
      "#{format_bytes(row[:bomc_bytes])} (#{ratio}; #{row[:status]})"
    end

    def profile_invariant_summary(bundle, profile)
      rows = bundle[:fixtures].map { |fixture| fixture.dig(:profiles, profile) }.compact
      passed = rows.count do |row|
        row[:invariants].is_a?(Hash) && row[:invariants].values.all? { |value| value == true }
      end
      "#{passed}/#{rows.length}"
    end

    def results_metric_max(bundle, profile, metric)
      bundle[:fixtures].map { |fixture| fixture.dig(:profiles, profile, :metrics, metric) }.compact.max
    end

    def format_bytes(bytes)
      return '-' if bytes.nil?
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "#{(bytes / 1024.0).round(1)} KB"
      else
        "#{(bytes / (1024.0 * 1024.0)).round(2)} MB"
      end
    end

    def run(argv)
      corpus_path = File.expand_path('../benchmarks/profile-corpus.json', __dir__)
      results = run_corpus(corpus_path)
      bundle = generate_report(results)

      json_out = File.expand_path('../benchmarks/results/bomc-profile-benchmark.json', __dir__)
      md_out = File.expand_path('../benchmarks/results/BOMC_PROFILE_BENCHMARK.md', __dir__)

      FileUtils.mkdir_p(File.dirname(json_out))
      File.write(json_out, JSON.pretty_generate(sanitize_for_json(bundle)))
      File.write(md_out, render_markdown(bundle))

      puts "[BENCHMARK-COMPLETE] Wrote #{json_out} and #{md_out}"
      bundle[:certification_status] == 'ready' ? 0 : 2
    end
  end
end

exit(BOMEngine::BOMCProfileBenchmark.run(ARGV)) if __FILE__ == $PROGRAM_NAME
