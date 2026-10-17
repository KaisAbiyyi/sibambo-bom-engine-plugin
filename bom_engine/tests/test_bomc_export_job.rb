# Pure-Ruby cooperative BOMC state-machine tests.

require 'fileutils'
require 'tmpdir'
require_relative '../bomc_export_job'
require_relative '../performance_trace'

module BOMEngine
  class ConversionJob
    class Cancelled < StandardError; end unless const_defined?(:Cancelled)
  end

  module Tests
    module BOMCExportJobTest
      module_function

      FakeModel = Struct.new(:path)

      class FinishFailureTrace < PerformanceTrace
        def finish(**_args)
          raise IOError, 'trace finalization failure'
        end
      end

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        test_ordered_state_machine
        test_performance_trace_receipt
        test_cleanup_on_cancellation
        puts 'BOMC Export Job Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Export Job Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def test_ordered_state_machine
        stages = []
        source_reads = 0
        cleared = 0
        graph = { coverage: { unaccounted: 0 }, marker: 'detached' }
        context = {
          clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
          on_yield: ->(event) { stages << event[:stage] },
          cancelled: -> { false },
          source_info: ->(_model) { source_reads += 1; { path: 'model.skp', bytes: 1_000, available: true } },
          snapshot: ->(_model, _checkpoint) { graph },
          compile: lambda do |detached, source, output, checkpoint|
            assert(detached.equal?(graph), 'compiler receives the one detached snapshot')
            assert(source[:bytes] == 1_000 && output.end_with?('.bomc'), 'compiler receives captured source size and output path')
            checkpoint.call(stage: :size_gate, processed: 1, total: 1, candidate_bytes: 700, force: true)
            { path: output, bytes: 'compiled'.b, candidate_bytes: 700, source_bytes: 1_000, savings_bytes: 300, status: :pass, strategy: :standard, metrics: { coverage: { unaccounted: 0 } } }
          end,
          validate: ->(result) { { unaccounted: result.dig(:metrics, :coverage, :unaccounted) } },
          graph_cleared: -> { cleared += 1 },
          cleanup: -> {}
        }
        result = BOMCExportJob.run(
          model: FakeModel.new('model.skp'),
          output_path: 'result.bomc',
          settings: BOMCProcessing.settings(:balanced),
          context: context
        )
        ordered_unique = stages.each_with_object([]) { |stage, list| list << stage unless list[-1] == stage }
        assert(ordered_unique == BOMCExportJob::STAGES, 'state events follow the complete public stage order')
        assert(source_reads == 1, 'saved source path and size are captured exactly once')
        assert(result[:status] == :pass && result[:savings_bytes] == 300, 'strict size-gate result propagates to completion')
        assert(cleared == 1, 'detached graph reference is cleared in ensure')
      end

      def test_cleanup_on_cancellation
        cleaned = 0
        cleared = 0
        context = {
          clock: -> { 0.0 }, on_yield: ->(_event) {}, cancelled: -> { false },
          source_info: ->(_model) { { path: nil, bytes: nil, available: false } },
          snapshot: ->(_model, _checkpoint) { { marker: 'detached' } },
          compile: ->(_graph, _source, _output, _checkpoint) { raise BOMCProcessing::Cancelled, 'cancelled' },
          validate: ->(_result) {},
          graph_cleared: -> { cleared += 1 },
          cleanup: -> { cleaned += 1 }
        }
        error = nil
        begin
          BOMCExportJob.run(
            model: FakeModel.new(''), output_path: 'cancelled.bomc',
            settings: BOMCProcessing.settings(:light), context: context
          )
        rescue BOMCProcessing::Cancelled => caught
          error = caught
        end
        assert(!error.nil?, 'cancellation propagates at a cooperative boundary')
        assert(cleaned == 1 && cleared == 1, 'cancellation cleans owned resources and detached graph')
      end

      def test_performance_trace_receipt
        receipts = []
        trace = PerformanceTrace.new(enabled: true, metadata: { engine: 'e4', profile: 'visual' })
        context = {
          clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
          on_yield: ->(_event) {}, cancelled: -> { false },
          performance_trace: trace,
          performance_receipt: ->(receipt) { receipts << receipt },
          source_info: ->(_model) { { path: 'model.skp', bytes: 1_000, sha256: 'a' * 64, available: true } },
          snapshot: ->(_model, _checkpoint) { { marker: 'detached' } },
          compile: ->(_graph, _source, output, _checkpoint) { { path: output, bytes: 'compiled'.b, sha256: 'b' * 64, candidate_bytes: 8, savings_bytes: 992, status: :pass, strategy: :standard, metrics: { coverage: { unaccounted: 0 } } } },
          validate: ->(_result, _graph) { { passed: true, report: { passed: true } } },
          publish: ->(_candidate, _validation, path) { { path: path, published: true } },
          cleanup: -> {}
        }
        result = BOMCExportJob.run(
          model: FakeModel.new('model.skp'), output_path: 'observed.bomc',
          settings: BOMCProcessing.settings(:balanced), context: context
        )
        receipt = receipts.fetch(0)
        names = receipt.fetch(:stages).map { |stage| stage[:name] }
        assert(receipts.length == 1 && receipt[:status] == 'success', 'successful export finalizes exactly one performance receipt')
        assert(%w[source_info snapshot compile validate publish].all? { |name| names.include?(name) }, 'top-level export phases are named spans')
        assert(result[:performance_trace].equal?(receipt), 'result exposes the same artifact-independent receipt to direct callers')
        assert(receipt.dig(:metadata, :source, :sha256) == 'a' * 64 && receipt.dig(:metadata, :artifact, :sha256) == 'b' * 64,
          'receipt binds timings to source and artifact identities')
        assert(receipt.dig(:metadata, :artifact, :strategy) == 'standard', 'receipt records the size-gate strategy alongside artifact identity')

        receipt_failure_context = context.merge(
          performance_trace: PerformanceTrace.new(enabled: true),
          performance_receipt: ->(_row) { raise IOError, 'telemetry disk failure' }
        )
        receipt_failure_result = BOMCExportJob.run(
          model: FakeModel.new('model.skp'), output_path: 'observed-receipt-failure.bomc',
          settings: BOMCProcessing.settings(:balanced), context: receipt_failure_context
        )
        assert(receipt_failure_result[:status] == :pass, 'performance receipt write failure cannot change a successful export result')
        assert(receipt_failure_result[:performance_receipt_error].to_s.include?('telemetry disk failure'),
          'receipt write failure remains observable without replacing the export result')

        finalized_cleanup = 0
        finalization_failure_context = context.merge(
          performance_trace: FinishFailureTrace.new(enabled: true),
          performance_receipt: ->(_row) { raise 'receipt callback must not run after finish failure' },
          cleanup: -> { finalized_cleanup += 1 }
        )
        finalization_failure_result = BOMCExportJob.run(
          model: FakeModel.new('model.skp'), output_path: 'observed-finalization-failure.bomc',
          settings: BOMCProcessing.settings(:balanced), context: finalization_failure_context
        )
        assert(finalization_failure_result[:status] == :pass, 'trace finalization failure cannot change a successful export result')
        assert(finalization_failure_result[:performance_receipt_error].to_s.include?('trace finalization failure'),
          'trace finalization failure remains observable on the successful export result')
        assert(finalized_cleanup == 1, 'trace finalization failure cannot skip export cleanup')

        cancelled_receipts = []
        cancelled_trace = PerformanceTrace.new(enabled: true)
        cancelled_context = context.merge(
          performance_trace: cancelled_trace,
          performance_receipt: ->(row) { cancelled_receipts << row },
          compile: ->(*_args) { raise BOMCProcessing::Cancelled, 'cancelled' },
          publish: nil
        )
        begin
          BOMCExportJob.run(
            model: FakeModel.new('model.skp'), output_path: 'cancelled-observed.bomc',
            settings: BOMCProcessing.settings(:balanced), context: cancelled_context
          )
        rescue BOMCProcessing::Cancelled
          nil
        end
        assert(cancelled_receipts.length == 1 && cancelled_receipts[0][:status] == 'cancelled', 'cancelled export still emits a finalized performance receipt')

        interactive_cancel_receipts = []
        interactive_cancel_context = context.merge(
          performance_trace: PerformanceTrace.new(enabled: true),
          performance_receipt: ->(row) { interactive_cancel_receipts << row },
          compile: ->(*_args) { raise ConversionJob::Cancelled, 'interactive cancel' },
          publish: nil
        )
        begin
          BOMCExportJob.run(
            model: FakeModel.new('model.skp'), output_path: 'interactive-cancelled.bomc',
            settings: BOMCProcessing.settings(:balanced), context: interactive_cancel_context
          )
        rescue ConversionJob::Cancelled
          nil
        end
        assert(interactive_cancel_receipts.fetch(0)[:status] == 'cancelled', 'real ConversionJob cancellation is recorded as cancelled rather than error')
      end
    end
  end
end

exit(BOMEngine::Tests::BOMCExportJobTest.run ? 0 : 1)
