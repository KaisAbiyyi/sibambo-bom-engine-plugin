# frozen_string_literal: true
# BOMC Profile Benchmark Tool — Legacy Baseline Measurement Harness
# Measures current standard, compact, and maximum_lossless behavior as legacy baseline only.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative '../bomc_format'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'
require_relative '../bomc_size_gate'

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
          value
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

    def run(argv)
      options = {
        fixtures: [],
        skp_bytes: nil,
        skp_path: nil,
        corpus: nil,
        output: nil,
        markdown: nil,
        stdout: false
      }

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: ruby bom_engine/tools/bomc_profile_benchmark.rb [options]'

        opts.on('--fixture PATH', 'Path to Model-Eval JSON fixture') do |path|
          options[:fixtures] << File.expand_path(path)
        end

        opts.on('--skp-bytes BYTES', Integer, 'Explicit source SKP byte size') do |bytes|
          options[:skp_bytes] = bytes
        end

        opts.on('--skp PATH', 'Path to paired source SKP file') do |path|
          options[:skp_path] = File.expand_path(path)
        end

        opts.on('--corpus PATH', 'Path to corpus manifest JSON') do |path|
          options[:corpus] = File.expand_path(path)
        end

        opts.on('--output PATH', 'Path to write JSON benchmark report') do |path|
          options[:output] = File.expand_path(path)
        end

        opts.on('--markdown PATH', 'Path to write Markdown benchmark report') do |path|
          options[:markdown] = File.expand_path(path)
        end

        opts.on('--stdout', 'Print JSON output to stdout') do
          options[:stdout] = true
        end
      end

      parser.parse!(argv)

      if options[:fixtures].empty? && options[:corpus].nil?
        default_corpus = File.expand_path('../benchmarks/profile-corpus.json', __dir__)
        options[:corpus] = default_corpus if File.file?(default_corpus)
      end

      results = []

      if options[:corpus] && File.file?(options[:corpus])
        manifest = JSON.parse(File.read(options[:corpus]), symbolize_names: true)
        root = File.expand_path('../..', __dir__)
        Array(manifest[:items]).each do |item|
          fixture_rel = item[:model_eval_fixture]
          next unless fixture_rel
          fixture_path = File.join(root, fixture_rel)
          next unless File.file?(fixture_path)

          skp_path = item[:skp_path] ? File.join(root, item[:skp_path]) : nil
          skp_bytes = skp_path && File.file?(skp_path) ? File.size(skp_path) : nil

          result = benchmark_fixture(
            fixture_path,
            name: item[:id] || File.basename(fixture_path, '.*'),
            skp_bytes: skp_bytes,
            skp_path: skp_path
          )
          results << result
        end
      end

      options[:fixtures].each do |fixture_path|
        raise "Fixture file not found: #{fixture_path}" unless File.file?(fixture_path)

        skp_path = options[:skp_path]
        skp_bytes = options[:skp_bytes] || (skp_path && File.file?(skp_path) ? File.size(skp_path) : nil)

        result = benchmark_fixture(
          fixture_path,
          name: File.basename(fixture_path, '.*'),
          skp_bytes: skp_bytes,
          skp_path: skp_path
        )
        results << result
      end

      payload = if results.length == 1
                  results.first
                else
                  {
                    schema_version: 1,
                    producer_sha: producer_sha,
                    report_type: 'multi_fixture_summary',
                    fixtures: results
                  }
                end

      clean_payload = sanitize_for_json(payload)
      json_str = JSON.pretty_generate(clean_payload)

      if options[:output]
        FileUtils.mkdir_p(File.dirname(options[:output]))
        File.open(options[:output], 'wb') { |f| f.write(json_str) }
        warn "Wrote benchmark JSON: #{options[:output]}"
      end

      if options[:markdown]
        md_str = render_markdown_report(results)
        FileUtils.mkdir_p(File.dirname(options[:markdown]))
        File.open(options[:markdown], 'w:UTF-8') { |f| f.write(md_str) }
        warn "Wrote benchmark Markdown: #{options[:markdown]}"
      end

      puts json_str if options[:stdout] || (options[:output].nil? && options[:markdown].nil?)

      clean_payload
    end

    def benchmark_fixture(fixture_path, name: nil, skp_bytes: nil, skp_path: nil)
      raise "Fixture not found: #{fixture_path}" unless File.file?(fixture_path)

      raw_json = File.binread(fixture_path)
      graph = JSON.parse(raw_json.force_encoding(Encoding::UTF_8), symbolize_names: true)
      base_path = File.dirname(fixture_path)

      effective_skp_bytes = skp_bytes
      if effective_skp_bytes.nil? && skp_path && File.file?(skp_path)
        effective_skp_bytes = File.size(skp_path)
      end

      source_info = if effective_skp_bytes
                      { path: skp_path, bytes: effective_skp_bytes, available: true }
                    else
                      { path: nil, bytes: nil, available: false, reason: :unsaved_or_missing }
                    end

      # Evaluate legacy size gate strategies (standard, compact, maximum_lossless)
      attempts = []
      best_candidate = nil

      BOMCSizeGate::STRATEGIES.each do |strategy|
        pack_res = BOMCWriter.pack(
          graph,
          profile: :production,
          base_path: base_path,
          sparse: true,
          compact_directory: true,
          compression_level: strategy[:compression_level],
          minimal_metadata: strategy[:minimal_metadata]
        )

        cand_size = pack_res[:bytes].bytesize
        status = BOMCSizeGate.evaluate(candidate_bytes: cand_size, source_info: source_info)

        attempt = {
          strategy: strategy[:name].to_s,
          candidate_bytes: cand_size,
          status: status.to_s,
          compression_level: strategy[:compression_level],
          minimal_metadata: strategy[:minimal_metadata]
        }
        attempts << attempt

        if best_candidate.nil? || cand_size < best_candidate[:candidate_bytes]
          best_candidate = {
            strategy: strategy[:name],
            candidate_bytes: cand_size,
            pack_res: pack_res,
            status: status
          }
        end

        break if (status == :pass || status == :unavailable) && best_candidate
      end

      selected = best_candidate[:pack_res]
      selected_metrics = selected[:metrics] || {}

      candidate_bytes = selected[:bytes].bytesize
      ratio = effective_skp_bytes && effective_skp_bytes > 0 ? (candidate_bytes.to_f / effective_skp_bytes).round(4) : nil
      legacy_status = if effective_skp_bytes.nil?
                        'unavailable'
                      elsif candidate_bytes < effective_skp_bytes
                        'pass'
                      else
                        'over_budget'
                      end

      sections_map = {}
      (selected_metrics[:sections] || {}).each do |sec_name, sec_val|
        sections_map[sec_name.to_s] = {
          raw_bytes: sec_val[:raw_bytes],
          stored_bytes: sec_val[:stored_bytes],
          codec: sec_val[:codec],
          count: sec_val[:count]
        }
      end

      codec_metrics = {
        positions: selected_metrics[:positions] || [],
        normals: selected_metrics[:normals] || {},
        uv: selected_metrics[:uv] || [],
        transforms: selected_metrics[:transforms] || {},
        topology: selected_metrics[:topology] || {},
        adaptive_indices: selected_metrics[:adaptive_indices] || {}
      }

      texture_metrics = selected_metrics[:textures] || {
        source_references: 0,
        unique: 0,
        deduplicated: 0,
        bytes: 0,
        encodings: {}
      }

      {
        schema_version: 1,
        producer_sha: producer_sha,
        source: {
          name: name || File.basename(fixture_path, '.*'),
          fixture_path: fixture_path,
          skp_bytes: effective_skp_bytes || 0
        },
        legacy: {
          candidate_bytes: candidate_bytes,
          ratio: ratio,
          status: legacy_status,
          strategy: best_candidate[:strategy].to_s,
          attempts: attempts
        },
        sections: sections_map,
        codec_metrics: codec_metrics,
        texture_metrics: {
          source_references: texture_metrics[:source_references] || 0,
          unique: texture_metrics[:unique] || 0,
          deduplicated: texture_metrics[:deduplicated] || 0,
          bytes: texture_metrics[:bytes] || 0,
          encodings: texture_metrics[:encodings] || {}
        },
        coverage: selected_metrics[:coverage] || {},
        appearance: selected_metrics[:appearance] || {}
      }
    end

    def render_markdown_report(results)
      md = []
      md << '# BOMC Profile Benchmark: Legacy Baseline Report'
      md << ''
      md << "**Producer SHA:** `#{producer_sha}`  "
      md << "**Timestamp:** #{Time.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}  "
      md << "**Fixtures Measured:** #{results.length}"
      md << ''
      md << '---'
      md << ''
      md << '## Legacy Baseline Summary Table'
      md << ''
      md << '| Fixture | SKP Bytes | Legacy Strategy | BOMC Bytes | Ratio vs SKP | Legacy Status | Textures (Unique / Bytes) |'
      md << '|---|---|---|---|---|---|---|'

      results.each do |r|
        src = r[:source]
        leg = r[:legacy]
        tex = r[:texture_metrics]
        skp_display = src[:skp_bytes] > 0 ? format_bytes(src[:skp_bytes]) : 'N/A'
        bomc_display = format_bytes(leg[:candidate_bytes])
        ratio_display = leg[:ratio] ? "#{((leg[:ratio]) * 100).round(1)}%" : 'N/A'
        tex_display = "#{tex[:unique]} / #{format_bytes(tex[:bytes])}"

        md << "| #{src[:name]} | #{skp_display} | `#{leg[:strategy]}` | #{bomc_display} | #{ratio_display} | `#{leg[:status]}` | #{tex_display} |"
      end

      md << ''
      md << '---'
      md << ''
      md << '## Detailed Fixture Breakdown'
      md << ''

      results.each do |r|
        src = r[:source]
        leg = r[:legacy]
        md << "### #{src[:name]}"
        md << ''
        md << "- **Source Fixture:** `#{src[:fixture_path]}`"
        md << "- **SKP Size:** #{src[:skp_bytes] > 0 ? format_bytes(src[:skp_bytes]) : 'Not specified'}"
        md << "- **Legacy Result:** #{format_bytes(leg[:candidate_bytes])} (`#{leg[:strategy]}`, status: `#{leg[:status]}`, ratio: #{leg[:ratio] ? "#{(leg[:ratio] * 100).round(1)}%" : 'N/A'})"
        md << ''
        md << '#### Section Breakdown'
        md << ''
        md << '| Section | Raw Bytes | Stored Bytes | Codec | Count |'
        md << '|---|---|---|---|---|'
        (r[:sections] || {}).each do |name, sec|
          codec_name = case sec[:codec]
                       when 0 then 'STORE'
                       when 1 then 'DEFLATE'
                       else sec[:codec].to_s
                       end
          md << "| `#{name}` | #{format_bytes(sec[:raw_bytes])} | #{format_bytes(sec[:stored_bytes])} | #{codec_name} | #{sec[:count]} |"
        end
        md << ''
        md << '#### Codec Metrics'
        md << ''
        normals = r.dig(:codec_metrics, :normals) || {}
        md << "- **Normals Codec:** #{normals[:codec] || 'N/A'} (#{normals[:count] || 0} items, #{format_bytes(normals[:stored_bytes] || 0)})"
        transforms = r.dig(:codec_metrics, :transforms) || {}
        md << "- **Transforms:** #{transforms[:count] || 0} transforms, #{transforms[:uniform_scale_count] || 0} uniform scale"
        topology = r.dig(:codec_metrics, :topology) || {}
        md << "- **Topology Saved Bytes:** #{format_bytes(topology[:saved_bytes] || 0)}"
        md << ''
      end

      md.join("\n")
    end

    def format_bytes(bytes)
      return '0 B' if bytes.nil? || bytes == 0
      units = ['B', 'KB', 'MB', 'GB']
      exp = (Math.log(bytes) / Math.log(1024)).to_i
      exp = [exp, units.length - 1].min
      if exp == 0
        "#{bytes} B"
      else
        formatted = (bytes.to_f / (1024**exp)).round(2)
        "#{formatted} #{units[exp]} (#{bytes.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} B)"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  BOMEngine::BOMCProfileBenchmark.run(ARGV)
end
