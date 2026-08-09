# frozen_string_literal: true

# Run in a new, empty, unsaved SketchUp model:
#   load 'D:/projects/sibambo/bom_engine_plugin-semantic-v2-m1/bom_engine/tests/test_semantic_v2_extractor_sketchup.rb'

require_relative '../semantic_v2'

module BOMEngine
  module Tests
    module SemanticV2ExtractorSketchupTest
      AttachedText = Struct.new(:text, :target) do
        def attached_to
          [[target], Geom::Point3d.new(0, 0, 0)]
        end
      end

      module_function

      def run
        raise 'SketchUp API unavailable' unless defined?(Sketchup)

        model = Sketchup.active_model
        assert_disposable_model!(model)
        model.start_operation('Semantic v2 extractor runtime fixture', true)
        begin
          fixture = model.entities.add_group
          loose = fixture.entities.add_face([0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0])
          hidden = fixture.entities.add_face([3, 0, 0], [4, 0, 0], [4, 1, 0], [3, 1, 0])
          hidden.hidden = true
          policy_excluded = fixture.entities.add_face([5, 0, 0], [6, 0, 0], [6, 1, 0], [5, 1, 0])

          shared = model.definitions.add('Semantic v2 Shared Door')
          shared_face = shared.entities.add_face([0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0])
          inner = shared.entities.add_face([1, 1, 0], [1, 3, 0], [3, 3, 0], [3, 1, 0])
          inner.erase! if inner && !inner.deleted?
          first = fixture.entities.add_instance(shared, Geom::Transformation.translation([10, 0, 0]))
          first.name = 'Pintu cadangan'
          second = fixture.entities.add_instance(shared, Geom::Transformation.translation([20, 0, 0]))

          nested = fixture.entities.add_group
          nested.name = 'Nested Group'
          nested.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])

          roots = fixture.entities.to_a
          plan = SemanticV2::IdentityCoordinator.plan(model: model, roots: roots)
          before_uuid = loose.get_attribute('BOMEngine.SemanticV2', 'source_uuid', nil)
          extraction_roots = roots + [AttachedText.new('Pintu Utama', first)]
          snapshot = SemanticV2::Extractor.extract(
            model: model,
            roots: extraction_roots,
            parent_transform: Geom::Transformation.new,
            identity_plan: plan,
            settings: {
              include_hidden: false,
              face_policy: ->(face) { !face.equal?(policy_excluded) }
            }
          )

          assert(snapshot.primitives.any? { |item| item.source_uuid == plan.source_uuid_for(loose) }, 'loose face extracted')
          assert(snapshot.definitions.count { |item| item.source_uuid == plan.source_uuid_for(shared) } == 1, 'shared definition stored once')
          shared_occurrences = snapshot.occurrences.select { |item| item.definition_uuid == plan.source_uuid_for(shared) }
          assert(shared_occurrences.length == 2, 'repeated instances have separate occurrences')
          assert(shared_occurrences.map(&:uuid_path).uniq.length == 2, 'occurrences use UUID paths')
          assert(snapshot.occurrences.any? { |item| item.definition_uuid == plan.source_uuid_for(nested.definition) }, 'nested group occurrence extracted')
          polygon = snapshot.primitives.find { |item| item.source_uuid == plan.source_uuid_for(shared_face) }
          assert(polygon.loops.count { |loop| loop.kind == 'hole' } == 1, 'face hole preserved')
          exclusions = snapshot.evidence.grep(SemanticV2::Snapshot::ExclusionEvidence)
          assert(exclusions.any? { |item| item.target_key.last == plan.source_uuid_for(hidden) && item.reasons.include?('hidden') }, 'hidden exclusion preserved')
          assert(exclusions.any? { |item| item.target_key.last == plan.source_uuid_for(policy_excluded) && item.reasons.include?('policy_excluded') }, 'policy exclusion preserved')
          labels = snapshot.evidence.grep(SemanticV2::Snapshot::LabelEvidence)
          assert(labels.any? { |item| item.label == 'Pintu Utama' && item.explicit }, 'attached-text evidence preserved')
          assert(before_uuid.nil? && loose.get_attribute('BOMEngine.SemanticV2', 'source_uuid', nil).nil?, 'extraction remains read-only')
          puts 'Semantic v2 Extractor SketchUp Tests: ALL PASSED'
          true
        ensure
          model.abort_operation
        end
      end

      def assert_disposable_model!(model)
        safe = model && model.path.to_s.empty? && model.entities.empty? &&
               (!model.respond_to?(:modified?) || !model.modified?)
        raise 'Refusing to run extractor fixture in a non-disposable model' unless safe
      end

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition

        puts "PASS: #{message}"
      end
    end
  end
end

BOMEngine::Tests::SemanticV2ExtractorSketchupTest.run
