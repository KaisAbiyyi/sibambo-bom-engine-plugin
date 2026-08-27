# Pure-Ruby cooperative BOMC state-machine tests.

require 'fileutils'
require 'tmpdir'
require_relative '../bomc_export_job'

module SibamboHistory
  module V20260827_01
  module Tests
    module BOMCExportJobTest
      module_function

      FakeModel = Struct.new(:path)

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        test_ordered_state_machine
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
            assert(source[:bytes] == 1_000 && output.end_with?('__SBE-2026.08.27-01.bomc'), 'compiler receives captured source size and output path')
            checkpoint.call(stage: :size_gate, processed: 1, total: 1, candidate_bytes: 700, force: true)
            { path: output, bytes: 'compiled'.b, candidate_bytes: 700, source_bytes: 1_000, savings_bytes: 300, status: :pass, strategy: :standard, metrics: { coverage: { unaccounted: 0 } } }
          end,
          validate: ->(result) { { unaccounted: result.dig(:metrics, :coverage, :unaccounted) } },
          graph_cleared: -> { cleared += 1 },
          cleanup: -> {}
        }
        result = BOMCExportJob.run(
          model: FakeModel.new('model.skp'),
          output_path: 'result__SBE-2026.08.27-01.bomc',
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
            model: FakeModel.new(''), output_path: 'cancelled__SBE-2026.08.27-01.bomc',
            settings: BOMCProcessing.settings(:light), context: context
          )
        rescue BOMCProcessing::Cancelled => caught
          error = caught
        end
        assert(!error.nil?, 'cancellation propagates at a cooperative boundary')
        assert(cleaned == 1 && cleared == 1, 'cancellation cleans owned resources and detached graph')
      end
    end
  end
end

exit(SibamboHistory::V20260827_01::Tests::BOMCExportJobTest.run ? 0 : 1)

end # SibamboHistory
