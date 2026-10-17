# Pure-Ruby performance telemetry contract tests.

trace_path = File.expand_path('../performance_trace.rb', __dir__)
raise 'FAIL: performance_trace.rb must exist' unless File.file?(trace_path)
require trace_path
require 'tmpdir'
require_relative '../bomc_size_gate'
require_relative '../bomc_writer'

module BOMEngine
  module Tests
    module PerformanceTraceTest
      module_function

      class Cancelled < StandardError; end
      class TranscodeCancelledError < StandardError; end

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        test_nested_stage_contract
        test_selected_nested_resource_sampling
        test_error_and_cancel_finalization
        test_disabled_trace_is_a_real_noop
        test_receipt_is_json_safe
        test_bomc_writer_trace_preserves_bytes
        test_source_hash_is_a_named_stage
        puts 'Performance Trace Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "Performance Trace Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def test_nested_stage_contract
        wall = sequence_clock([10.000, 10.010, 10.012, 10.018, 10.025, 10.030])
        cpu = sequence_clock([2.000, 2.004, 2.005, 2.008])
        gc_samples = [
          { count: 4, total_allocated_objects: 100, heap_live_slots: 50 },
          { count: 4, total_allocated_objects: 110, heap_live_slots: 56 },
          { count: 5, total_allocated_objects: 120, heap_live_slots: 58 },
          { count: 5, total_allocated_objects: 130, heap_live_slots: 60 }
        ]
        memory_samples = [
          { rss_bytes: 1_000, heap_bytes: 700 },
          { rss_bytes: 1_100, heap_bytes: 760 },
          { rss_bytes: 1_200, heap_bytes: 780 },
          { rss_bytes: 1_300, heap_bytes: 800 }
        ]
        trace = PerformanceTrace.new(
          enabled: true,
          clock: wall,
          cpu_clock: cpu,
          gc_sampler: -> { gc_samples.shift || gc_samples.last || {} },
          memory_sampler: -> { memory_samples.shift || memory_samples.last || {} },
          metadata: { engine: 'e4', profile: 'visual' }
        )

        trace.stage(:capture, counts: { entities: 12 }) do
          trace.increment(:scene_queries, 3)
          trace.stage(:scene_visibility, counts: { scenes: 2 }) { trace.increment(:scene_queries, 2) }
        end
        receipt = trace.finish(status: :success)
        capture, scene = receipt.fetch(:stages)

        assert(receipt[:schema] == PerformanceTrace::SCHEMA, 'receipt has a versioned schema')
        assert(capture[:id] != scene[:id] && scene[:parent_id] == capture[:id], 'nested stages carry stable parent IDs')
        assert(capture[:duration_ms] >= scene[:duration_ms] && scene[:duration_ms] >= 0.0, 'stage durations are monotonic and non-negative')
        assert(capture[:cpu_ms].is_a?(Numeric) && capture[:cpu_ms] >= 0.0, 'optional CPU duration is recorded when available')
        assert(capture.dig(:gc_delta, :total_allocated_objects).to_i >= 0, 'GC allocation delta is recorded')
        assert(capture.dig(:memory_delta, :rss_bytes).is_a?(Numeric), 'memory delta is recorded')
        assert(receipt.dig(:counters, :scene_queries) == 5, 'query counters aggregate across nested stages')
        assert(capture.dig(:counts, :entities) == 12 && scene.dig(:counts, :scenes) == 2, 'stage-specific counts remain attached to their stage')
        assert(receipt.dig(:metadata, :engine) == 'e4' && receipt.dig(:metadata, :profile) == 'visual', 'trace metadata is preserved outside artifact bytes')
      end

      def test_error_and_cancel_finalization
        trace = PerformanceTrace.new(enabled: true)
        begin
          trace.stage(:decode) { raise 'decode failed' }
        rescue RuntimeError
          nil
        end
        begin
          trace.stage(:validate) { raise Cancelled, 'cancelled' }
        rescue Cancelled
          nil
        end
        receipt = trace.finish(status: :cancelled, error: Cancelled.new('cancelled'))
        decode, validate = receipt.fetch(:stages)
        assert(decode[:status] == 'error' && decode[:error_class] == 'RuntimeError', 'failed span is finalized as error')
        assert(validate[:status] == 'cancelled', 'cancel exception finalizes its span as cancelled')
        assert(receipt[:status] == 'cancelled' && receipt[:error_class].end_with?('Cancelled'), 'top-level cancellation is explicit in the receipt')
        assert(PerformanceTrace.cancellation_error?(TranscodeCancelledError.new('stopped')), 'transcode cancellation variants are classified as cancellation')
      end

      def test_selected_nested_resource_sampling
        gc_value = 100
        memory_value = 1_000
        trace = PerformanceTrace.new(
          enabled: true,
          resource_sampling: :selected,
          gc_sampler: -> { gc_value += 10; { total_allocated_objects: gc_value } },
          memory_sampler: -> { memory_value += 100; { heap_bytes: memory_value } }
        )
        trace.stage(:outer) do
          trace.stage(:heavy_inner, sample_resources: true) { 1 + 1 }
        end
        receipt = trace.finish(status: :success)
        inner = receipt.fetch(:stages).find { |row| row[:name] == 'heavy_inner' }
        assert(inner.dig(:gc_delta, :total_allocated_objects) == 10, 'selected nested heavy stage records GC delta')
        assert(inner.dig(:memory_delta, :heap_bytes) == 100, 'selected nested heavy stage records memory delta')

        root_only = PerformanceTrace.new(enabled: true)
        root_only.stage(:outer) { root_only.stage(:heavy_inner, sample_resources: true) { 1 } }
        root_receipt = root_only.finish(status: :success)
        root_inner = root_receipt.fetch(:stages).find { |row| row[:name] == 'heavy_inner' }
        assert(root_inner[:gc_delta].nil? && root_inner[:memory_delta].nil?, 'default root sampling keeps nested resource sampling opt-in')
        assert(root_receipt.dig(:metadata, :resource_sampling) == 'root', 'receipt declares its resource sampling mode')
      end

      def test_disabled_trace_is_a_real_noop
        calls = 0
        bomb = -> { calls += 1; raise 'disabled trace sampled a clock' }
        trace = PerformanceTrace.new(enabled: false, clock: bomb, cpu_clock: bomb, gc_sampler: bomb, memory_sampler: bomb)
        value = trace.stage(:anything) do
          trace.increment(:work, 4)
          42
        end
        receipt = trace.finish(status: :success)
        assert(value == 42, 'disabled trace returns the wrapped operation result')
        assert(calls.zero?, 'disabled trace does not call clocks or samplers')
        assert(receipt[:enabled] == false && receipt[:stages].empty? && receipt[:counters].empty?, 'disabled receipt is an empty no-op record')
      end

      def test_receipt_is_json_safe
        trace = PerformanceTrace.new(enabled: true, metadata: { profile: :visual })
        trace.stage(:compile, details: { strategy: :standard }) { trace.increment(:sections, 3) }
        receipt = trace.finish(status: :success)
        json = PerformanceTrace.generate_json(receipt)
        parsed = JSON.parse(json)
        assert(parsed['schema'] == PerformanceTrace::SCHEMA, 'receipt serializes to standalone JSON')
        assert(parsed.dig('stages', 0, 'details', 'strategy') == 'standard', 'symbols are normalized for machine-readable JSON')
      end

      def test_bomc_writer_trace_preserves_bytes
        baseline = BOMCWriter.pack(deterministic_graph, profile: :exact)
        trace = PerformanceTrace.new(enabled: true)
        observed = nil
        PerformanceTrace.with(trace) do
          observed = BOMCWriter.pack(deterministic_graph, profile: :exact)
        end
        receipt = trace.finish(status: :success)
        names = receipt.fetch(:stages).map { |stage| stage[:name] }
        assert(observed[:sha256] == baseline[:sha256] && observed[:bytes] == baseline[:bytes], 'trace-on BOMC bytes are identical to trace-off bytes')
        assert(%w[normalize_graph candidate_generation section_creation compression candidate_hash].all? { |name| names.include?(name) },
          'BOMC writer exposes normalization, candidates, section creation, compression, and hash stages')
      end

      def test_source_hash_is_a_named_stage
        Dir.mktmpdir('performance-source') do |dir|
          path = File.join(dir, 'fixture.skp')
          File.binwrite(path, 'fixture-source')
          trace = PerformanceTrace.new(enabled: true)
          info = nil
          PerformanceTrace.with(trace) { info = BOMCSizeGate.source_info(path) }
          receipt = trace.finish(status: :success)
          stage = receipt.fetch(:stages).find { |row| row[:name] == 'source_hash' }
          assert(info[:sha256].to_s.length == 64, 'source hash still produces the normal source identity')
          assert(stage && stage.dig(:counts, :bytes) == File.size(path), 'source hashing reports bytes as a named stage count')
        end
      end

      def deterministic_graph
        {
          format: { name: 'BOM Engine Canonical', version: '3.0.0' },
          source: { file_name: 'trace-fixture.skp', model_name: 'Trace Fixture' },
          materials: [], tags: [],
          transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
          meshes: [],
          definitions: [{ id: 'definition-root', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] }],
          nodes: [{ id: 'node-root', kind: 'root', name: 'Root', definition_id: 'definition-root', transform_id: 0, visible: true }]
        }
      end
      private_class_method :deterministic_graph

      def sequence_clock(values)
        queue = values.dup
        last = queue.last || 0.0
        -> { queue.empty? ? last : queue.shift }
      end
      private_class_method :sequence_clock
    end
  end
end

exit(BOMEngine::Tests::PerformanceTraceTest.run ? 0 : 1)
