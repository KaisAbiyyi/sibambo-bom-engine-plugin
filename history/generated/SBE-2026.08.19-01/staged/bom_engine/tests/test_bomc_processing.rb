# Run with standalone Ruby:
#   ruby bom_engine/tests/test_bomc_processing.rb

require_relative '../bomc_processing'
require_relative '../bomc_writer'

module SibamboHistory
  module V20260819_01
  module Tests
    module BOMCProcessingTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        test_preset_contracts
        test_dual_budget_and_adaptation
        test_cancellation
        test_scheduling_does_not_change_work
        test_scheduling_does_not_change_bomc
        puts 'BOMC Processing Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Processing Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def test_preset_contracts
        light = BOMCProcessing.settings(:light)
        assert(light == { mode: :light, max_items: 64, max_ms: 10.0, min_items: 1, max_items_limit: 512 }, 'Light preset has the literal public contract')
        assert(BOMCProcessing.settings(:balanced)[:max_ms] == 24.0, 'Balanced is the default 24 ms budget')
        assert(BOMCProcessing.settings(:fast)[:max_ms] == 60.0, 'Fast uses a bounded 60 ms budget')
        custom = BOMCProcessing.settings(:custom, custom: { max_items: 99_999, max_ms: 999, min_items: -4, max_items_limit: 999_999 })
        assert(custom[:max_ms] == 100.0, 'Custom time budget is clamped to the responsiveness ceiling')
        assert(custom[:max_items] <= custom[:max_items_limit] && custom[:min_items] >= 1, 'Custom item bounds are normalized')
      end

      def test_dual_budget_and_adaptation
        now = 0.0
        events = []
        controller = BOMCProcessing::Controller.new(
          settings: BOMCProcessing.settings(:light),
          clock: -> { now },
          on_yield: ->(event) { events << event },
          cancelled: -> { false }
        )
        controller.checkpoint(stage: :scan, processed: 0, total: 200)
        now = 0.011
        controller.checkpoint(stage: :scan, processed: 1, total: 200)
        assert(events.length == 1 && events[0][:reason] == :time, 'elapsed-time budget yields before the item target')
        assert(controller.target_items < 64, 'over-budget slice proportionally reduces the next item target')

        now = 0.012
        start_target = controller.target_items
        controller.checkpoint(stage: :scan, processed: 1 + start_target, total: 200)
        assert(events[-1][:reason] == :items, 'item budget yields even when time remains')
        assert(controller.target_items <= (start_target * 1.5).ceil, 'fast slice grows the item target by at most fifty percent')
        assert(controller.target_items <= BOMCProcessing.settings(:light)[:max_items_limit], 'adaptive target remains inside preset bounds')
      end

      def test_cancellation
        checks = 0
        controller = BOMCProcessing::Controller.new(
          settings: BOMCProcessing.settings(:balanced),
          clock: -> { 0.0 },
          on_yield: ->(_event) {},
          cancelled: -> { checks += 1; checks >= 3 }
        )
        controller.checkpoint(stage: :encode, processed: 1, total: 4)
        controller.checkpoint(stage: :encode, processed: 2, total: 4)
        error = nil
        begin
          controller.checkpoint(stage: :encode, processed: 3, total: 4)
        rescue BOMCProcessing::Cancelled => caught
          error = caught
        end
        assert(checks == 3 && !error.nil?, 'cancellation is checked at every checkpoint')
      end

      def test_scheduling_does_not_change_work
        light_result, light_events = run_work(:light)
        fast_result, fast_events = run_work(:fast)
        assert(light_result == fast_result, 'preset scheduling does not change ordered work results')
        assert(light_events > fast_events, 'Light yields more frequently than Fast for the same work')
      end

      def run_work(mode)
        now = 0.0
        events = 0
        controller = BOMCProcessing::Controller.new(
          settings: BOMCProcessing.settings(mode),
          clock: -> { now },
          on_yield: ->(_event) { events += 1 },
          cancelled: -> { false }
        )
        values = []
        2_000.times do |index|
          values << ((index * 17) % 101)
          now += 0.0001
          controller.checkpoint(stage: :work, processed: index + 1, total: 2_000)
        end
        [values, events]
      end

      def test_scheduling_does_not_change_bomc
        settings = [
          BOMCProcessing.settings(:custom, custom: { min_items: 1, max_items: 1, max_items_limit: 1, max_ms: 100 }),
          BOMCProcessing.settings(:light), BOMCProcessing.settings(:balanced), BOMCProcessing.settings(:fast),
          BOMCProcessing.settings(:custom, custom: { max_items: 32_768, max_items_limit: 32_768, max_ms: 100 })
        ]
        shas = settings.map do |preset|
          now = 0.0
          controller = BOMCProcessing::Controller.new(
            settings: preset,
            clock: -> { now }, on_yield: ->(_event) {}, cancelled: -> { false }
          )
          BOMCWriter.pack(
            deterministic_graph,
            checkpoint: lambda do |**event|
              now += 0.0001
              controller.checkpoint(**event)
            end
          )[:sha256]
        end
        assert(shas.uniq.length == 1, 'batch=1, Light, Balanced, Fast, and huge batch produce identical BOMC SHA256')
      end

      def deterministic_graph
        identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        definitions = [{ id: 'root-definition', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] }]
        nodes = [{ id: 'root-node', kind: 'root', name: 'Root', owner_definition_id: nil, definition_id: 'root-definition', transform_id: 0, visible: true }]
        transforms = [identity]
        100.times do |index|
          nodes << { id: "node-#{index}", kind: 'component_instance', name: 'Repeated', owner_definition_id: 'root-definition', definition_id: 'root-definition', transform_id: 0, visible: true }
          definitions[0][:node_ids] << "node-#{index}"
        end
        { source: {}, materials: [], tags: [], meshes: [], definitions: definitions, nodes: nodes, transforms: transforms }
      end
    end
  end
end

exit(SibamboHistory::V20260819_01::Tests::BOMCProcessingTest.run ? 0 : 1)

end # SibamboHistory
