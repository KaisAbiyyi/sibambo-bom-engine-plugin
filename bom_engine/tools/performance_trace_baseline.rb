# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require 'time'
require_relative '../performance_trace'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'

module BOMEngine
  module PerformanceTraceBaseline
    SCHEMA = 'sibambo-conversion-performance-baseline-v1'.freeze
    module_function

    def benchmark_fixture(id:, fixture_path:, source_skp_bytes:, repetitions: 7, warmup: 1, face_amplification: 1)
      graph = JSON.parse(File.binread(fixture_path).force_encoding(Encoding::UTF_8), symbolize_names: true)
      graph = amplify_faces(graph, Integer(face_amplification)) if Integer(face_amplification) > 1
      base_path = File.dirname(fixture_path)
      warmup.to_i.times { run_once(graph, base_path, source_skp_bytes, enabled: false) }

      off_runs = []
      on_runs = []
      Integer(repetitions).times do |index|
        pair = index.even? ? [false, true] : [true, false]
        pair.each do |enabled|
          row = run_once(graph, base_path, source_skp_bytes, enabled: enabled)
          (enabled ? on_runs : off_runs) << row
        end
      end

      all_shas = (off_runs + on_runs).map { |row| row[:sha256] }.uniq
      all_sizes = (off_runs + on_runs).map { |row| row[:bytes] }.uniq
      raise "#{id}: trace changed BOMC SHA" unless all_shas.length == 1
      raise "#{id}: trace changed BOMC byte size" unless all_sizes.length == 1

      off_median = median(off_runs.map { |row| row[:elapsed_ms] })
      on_median = median(on_runs.map { |row| row[:elapsed_ms] })
      overhead = off_median.positive? ? ((on_median - off_median) * 100.0 / off_median) : 0.0
      representative = on_runs.min_by { |row| (row[:elapsed_ms] - on_median).abs }

      {
        id: id,
        fixture_path: File.expand_path(fixture_path),
        source_skp_bytes: source_skp_bytes,
        face_amplification: Integer(face_amplification),
        repetitions: Integer(repetitions),
        trace_off: summarize_runs(off_runs, off_median),
        trace_on: summarize_runs(on_runs, on_median),
        overhead_percent: overhead.round(3),
        representative_trace: representative.fetch(:trace)
      }
    end

    def run_once(graph, base_path, source_skp_bytes, enabled:)
      trace = PerformanceTrace.new(
        enabled: enabled,
        metadata: { workload: 'bomc-visual-detached-fixture' },
        resource_sampling: :selected
      )
      result = nil
      started = monotonic
      PerformanceTrace.with(trace) do
        result = PerformanceTrace.stage(:baseline_workload) do
          packed = BOMCWriter.pack(
            graph,
            profile: :visual,
            source_skp_bytes: Integer(source_skp_bytes || 0),
            base_path: base_path,
            sparse: true,
            compact_directory: true,
            compression_level: 6
          )
          profiled = PerformanceTrace.stage(:decode_readback, counts: { bytes: packed[:bytes].bytesize }) do
            BOMCDecoder.profile(packed[:bytes])
          end
          profiled.fetch(:timings).each do |phase, milliseconds|
            PerformanceTrace.increment("decoder_#{phase}", milliseconds) if milliseconds.is_a?(Numeric)
          end
          validation = PerformanceTrace.stage(:fidelity_validation) do
            BOMCValidator.validate_profile!(source: graph, decoded: profiled.fetch(:model), profile: :visual, base_path: base_path)
          end
          raise 'fixture fidelity validation did not pass' unless validation[:passed] == true
          { sha256: packed[:sha256], bytes: packed[:bytes].bytesize }
        end
      end
      elapsed_ms = (monotonic - started) * 1000.0
      receipt = trace.finish(status: :success)
      {
        elapsed_ms: elapsed_ms.round(3),
        sha256: result.fetch(:sha256),
        bytes: result.fetch(:bytes),
        trace: receipt
      }
    end

    def run(argv)
      root = File.expand_path('../..', __dir__)
      workspace_root = File.expand_path('..', root)
      options = {
        repetitions: 7,
        warmup: 1,
        output: File.join(workspace_root, 'outputs', '2026-10-15-evolution-conversion-performance', 'step1-pure-ruby-baseline.json'),
        native_receipt: File.join(workspace_root, 'outputs', '2026-10-15-evolution-profile-parity', 'native-qualification', 'mg2-rumah-l-e4-visual-a8e93d2c-receipt.json')
      }
      OptionParser.new do |parser|
        parser.on('--repetitions N', Integer) { |value| options[:repetitions] = value }
        parser.on('--warmup N', Integer) { |value| options[:warmup] = value }
        parser.on('--output PATH') { |value| options[:output] = File.expand_path(value) }
        parser.on('--native-receipt PATH') { |value| options[:native_receipt] = File.expand_path(value) }
      end.parse!(argv)

      fixtures = [
        ['small-textured-house2', File.join(root, 'bom_engine', 'benchmarks', 'fixtures', 'small-textured-house2.json'), 440_016],
        ['scene-heavy-sboost2', File.join(root, 'bom_engine', 'benchmarks', 'fixtures', 'scene-heavy-sboost2.json'), 3_363_219],
        ['section-cut-heavy-rumah-l', File.join(root, 'bom_engine', 'benchmarks', 'fixtures', 'section-cut-heavy-rumah-l.json'), 33_035_617]
      ]
      rows = fixtures.map do |id, path, bytes|
        warn "[PERF] #{id}"
        benchmark_fixture(id: id, fixture_path: path, source_skp_bytes: bytes, repetitions: options[:repetitions], warmup: options[:warmup])
      end
      overhead_probe = benchmark_fixture(
        id: 'trace-overhead-probe-house2-x256',
        fixture_path: fixtures.first[1],
        source_skp_bytes: fixtures.first[2],
        repetitions: options[:repetitions],
        warmup: options[:warmup],
        face_amplification: 256
      )
      native = read_legacy_native_baseline(options[:native_receipt])
      bundle = {
        schema: SCHEMA,
        generated_at: Time.now.utc.iso8601,
        ruby: { version: RUBY_VERSION, platform: RUBY_PLATFORM },
        methodology: {
          workload: 'Visual BOMC detached fixture pack + full decode/readback + profile validation',
          ordering: 'alternating trace-off/trace-on pairs',
          trace_overhead_target_percent: 3.0,
          native_host_note: 'No SketchUp process is launched by this benchmark.'
        },
        fixtures: rows,
        trace_overhead_probe: overhead_probe,
        native_rumah_l_pre_observability: native,
        ranked_stage_hotspots: rank_hotspots(rows),
        native_decomposition_status: native ? 'blocked_until_one_instrumented_native_export' : 'legacy_native_baseline_missing'
      }
      FileUtils.mkdir_p(File.dirname(options[:output]))
      File.write(options[:output], JSON.pretty_generate(sanitize(bundle)) + "\n", encoding: 'UTF-8')
      puts options[:output]
      rows.each do |row|
        puts format('%s off=%.3fms on=%.3fms overhead=%+.3f%% sha=%s',
          row[:id], row.dig(:trace_off, :median_ms), row.dig(:trace_on, :median_ms), row[:overhead_percent], row.dig(:trace_on, :sha256))
      end
      puts format('%s off=%.3fms on=%.3fms overhead=%+.3f%% sha=%s',
        overhead_probe[:id], overhead_probe.dig(:trace_off, :median_ms), overhead_probe.dig(:trace_on, :median_ms),
        overhead_probe[:overhead_percent], overhead_probe.dig(:trace_on, :sha256))
      0
    end

    def amplify_faces(graph, factor)
      copy = Marshal.load(Marshal.dump(graph))
      Array(copy[:meshes]).each_with_index do |mesh, mesh_index|
        originals = Array(mesh[:faces])
        mesh[:faces] = factor.times.flat_map do |replica|
          originals.map.with_index do |face, face_index|
            duplicated = Marshal.load(Marshal.dump(face))
            duplicated[:id] = "#{face[:id] || face[:stable_id] || "face-#{face_index}"}:perf#{mesh_index}:#{replica}"
            duplicated
          end
        end
      end
      copy
    end
    private_class_method :amplify_faces

    def read_legacy_native_baseline(path)
      return nil unless path && File.file?(path)
      parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))
      row = Array(parsed['rows']).find { |entry| entry['engine'] == 'e4' && entry['profile'] == 'visual' }
      return nil unless row
      {
        receipt_path: File.expand_path(path),
        source_name: row['source_name'],
        source_bytes: row['source_bytes'],
        source_sha256: row['source_sha256'],
        producer_source_tree_sha256: row['source_tree_sha256'],
        artifact_bytes: row['artifact_bytes'],
        artifact_sha256: row['artifact_sha256'],
        ratio_to_source: row['ratio_to_source'],
        export_duration_ms: row['export_duration_ms'],
        status: row['status'],
        stage_breakdown: nil,
        stage_breakdown_reason: 'This export predates PerformanceTrace and cannot be retroactively decomposed without inventing timings.'
      }
    end

    def rank_hotspots(rows)
      totals = Hash.new { |hash, key| hash[key] = [] }
      rows.each do |row|
        Array(row.dig(:representative_trace, :stages)).each do |stage|
          next unless stage[:duration_ms].is_a?(Numeric)
          totals[stage[:name]] << stage[:duration_ms]
        end
      end
      totals.map do |name, values|
        { stage: name, median_representative_duration_ms: median(values).round(3), sample_count: values.length }
      end.sort_by { |row| -row[:median_representative_duration_ms] }.first(10)
    end

    def summarize_runs(runs, median_ms)
      {
        median_ms: median_ms.round(3),
        min_ms: runs.map { |row| row[:elapsed_ms] }.min.round(3),
        max_ms: runs.map { |row| row[:elapsed_ms] }.max.round(3),
        sha256: runs.first.fetch(:sha256),
        bytes: runs.first.fetch(:bytes)
      }
    end

    def median(values)
      sorted = values.compact.map(&:to_f).sort
      return 0.0 if sorted.empty?
      middle = sorted.length / 2
      sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def sanitize(value)
      case value
      when Hash then value.each_with_object({}) { |(key, child), out| out[key] = sanitize(child) }
      when Array then value.map { |child| sanitize(child) }
      when Float
        return 'Infinity' if value.infinite? == 1
        return '-Infinity' if value.infinite? == -1
        return 'NaN' if value.nan?
        value.round(6)
      else value
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

exit(BOMEngine::PerformanceTraceBaseline.run(ARGV)) if __FILE__ == $PROGRAM_NAME
