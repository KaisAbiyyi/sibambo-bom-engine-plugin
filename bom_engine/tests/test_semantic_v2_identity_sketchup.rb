# frozen_string_literal: true

# Run in the SketchUp Ruby Console:
# load 'D:/projects/sibambo/bom_engine_plugin-semantic-v2-m1/bom_engine/tests/test_semantic_v2_identity_sketchup.rb'

require_relative '../semantic_v2'
require_relative '../semantic_v2/identity_coordinator'

module BOMEngine
  module Tests
    module SemanticV2IdentitySketchupTest
      module_function

      COORDINATOR = BOMEngine::SemanticV2::IdentityCoordinator

      def run
        raise 'SketchUp API is unavailable' unless defined?(Sketchup)

        model = Sketchup.active_model
        assert_disposable_model!(model)
        disposable_fixture = true
        created = []
        definitions = []
        failures = []

        root = in_operation(model, 'BOM Engine identity runtime fixture') do
          item = model.entities.add_group
          item.name = "BOM Engine Semantic v2 identity fixture #{Time.now.to_f}"
          created << item
          item
        end

        face = in_operation(model, 'BOM Engine identity face fixture') do
          root.entities.add_face([0, 0, 0], [24, 0, 0], [24, 24, 0], [0, 24, 0])
        end
        initial = persist(model, [root])
        root_id = initial.source_uuid_for(root)
        face_id = initial.source_uuid_for(face)

        clean = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 're-export keeps IDs and requires no model write') do
          !clean.write_required? && clean.source_uuid_for(root) == root_id &&
            clean.source_uuid_for(face) == face_id
        end

        in_operation(model, 'BOM Engine identity move fixture') do
          root.transform!(Geom::Transformation.translation([120, 0, 0]))
          root.name = 'renamed after identity assignment'
        end
        moved = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 'move and rename do not enter occurrence identity') do
          moved.occurrence_uuid_for(root) == root_id
        end

        in_operation(model, 'BOM Engine identity vertex edit fixture') do
          vertex = face.vertices.first
          root.entities.transform_by_vectors([vertex], [Geom::Vector3d.new(0, 0, 6)])
        end
        edited = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 'vertex edit preserves the source UUID') do
          edited.source_uuid_for(face) == face_id
        end

        copied_root = in_operation(model, 'BOM Engine identity copy fixture') do
          copy = root.copy
          created << copy
          copy
        end
        copied = COORDINATOR.plan(model: model, roots: [copied_root, root])
        check(failures, 'copy keeps the registry-owned original and re-identifies the copy') do
          copied.source_uuid_for(root) == root_id &&
            copied.source_uuid_for(copied_root) != root_id
        end
        COORDINATOR.send(:commit!, model: model, plan: copied)

        definition, first_instance, second_instance = component_fixture(model, root, definitions)
        shared = persist(model, [root])
        first_id = shared.occurrence_uuid_for(first_instance)
        second_id = shared.occurrence_uuid_for(second_instance)
        definition_id = shared.source_uuid_for(definition)
        definition_face = definition.entities.grep(Sketchup::Face).first
        definition_face_id = shared.source_uuid_for(definition_face)

        duplicate = in_operation(model, 'BOM Engine identity duplicate fixture') do
          root.entities.add_instance(definition, first_instance.transformation)
        end
        duplicated = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 'duplicated instance gets a distinct occurrence token') do
          duplicated.occurrence_uuid_for(duplicate) != first_id
        end
        COORDINATOR.send(:commit!, model: model, plan: duplicated)

        in_operation(model, 'BOM Engine identity shared definition edit') do
          definition_face.pushpull(4)
        end
        definition_edit = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 'shared definition edit preserves definition and existing occurrences') do
          definition_edit.source_uuid_for(definition) == definition_id &&
            definition_edit.occurrence_uuid_for(first_instance) == first_id &&
            definition_edit.occurrence_uuid_for(second_instance) == second_id &&
            definition_edit.source_uuid_for(definition_face) == definition_face_id
        end

        nested, nested_face = nested_fixture(model, root)
        nested_plan = persist(model, [root])
        nested_id = nested_plan.source_uuid_for(nested)
        nested_face_id = nested_plan.source_uuid_for(nested_face)
        in_operation(model, 'BOM Engine identity nested edit') do
          nested.entities.add_line([0, 0, 0], [0, 0, 12])
        end
        nested_edit = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 'nested group edit preserves existing nested identities') do
          nested_edit.source_uuid_for(nested) == nested_id &&
            nested_edit.source_uuid_for(nested_face) == nested_face_id
        end

        doomed = in_operation(model, 'BOM Engine identity delete fixture') do
          root.entities.add_group
        end
        doomed_plan = persist(model, [root])
        doomed_id = doomed_plan.source_uuid_for(doomed)
        replacement = in_operation(model, 'BOM Engine identity recreate fixture') do
          doomed.erase!
          root.entities.add_group
        end
        recreated = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 'delete and recreate allocates a new source identity') do
          recreated.source_uuid_for(replacement) != doomed_id
        end

        explode_group, explode_face = explode_fixture(model, root)
        explode_plan = persist(model, [root])
        explode_group_id = explode_plan.source_uuid_for(explode_group)
        explode_face_id = explode_plan.source_uuid_for(explode_face)
        exploded_entities = in_operation(model, 'BOM Engine identity explode fixture') do
          explode_group.explode
        end
        exploded_face = exploded_entities.grep(Sketchup::Face).first
        after_explode = COORDINATOR.plan(model: model, roots: [root])
        check(failures, 'explode preserves surviving geometry but retires the container occurrence') do
          exploded_face && after_explode.source_uuid_for(exploded_face) == explode_face_id &&
            after_explode.source_uuid_for(exploded_face) != explode_group_id
        end

        report(failures)
      ensure
        cleanup(model, created, definitions) if model && disposable_fixture
      end

      def component_fixture(model, root, definitions)
        in_operation(model, 'BOM Engine identity component fixture') do
          definition = model.definitions.add("BOM Engine identity shared definition #{Time.now.to_f}")
          definitions << definition
          definition.entities.add_face([0, 0, 0], [12, 0, 0], [12, 12, 0], [0, 12, 0])
          first = root.entities.add_instance(definition, Geom::Transformation.translation([36, 0, 0]))
          second = root.entities.add_instance(definition, Geom::Transformation.translation([60, 0, 0]))
          [definition, first, second]
        end
      end

      def assert_disposable_model!(model)
        safe = model && model.path.to_s.empty? && model.entities.empty? && !model.modified?
        return if safe

        raise 'Identity runtime test refused: use a new, empty, unmodified SketchUp model'
      end

      def nested_fixture(model, root)
        in_operation(model, 'BOM Engine identity nested fixture') do
          nested = root.entities.add_group
          face = nested.entities.add_face([0, 0, 0], [6, 0, 0], [6, 6, 0], [0, 6, 0])
          [nested, face]
        end
      end

      def explode_fixture(model, root)
        in_operation(model, 'BOM Engine identity explode group fixture') do
          group = root.entities.add_group
          face = group.entities.add_face([0, 0, 0], [8, 0, 0], [8, 8, 0], [0, 8, 0])
          [group, face]
        end
      end

      def persist(model, roots)
        plan = COORDINATOR.plan(model: model, roots: roots)
        COORDINATOR.send(:commit!, model: model, plan: plan)
        plan
      end

      def in_operation(model, name)
        model.start_operation(name, true)
        value = yield
        model.commit_operation
        value
      rescue Exception
        model.abort_operation
        raise
      end

      def cleanup(model, created, definitions)
        in_operation(model, 'BOM Engine identity runtime cleanup') do
          created.reverse_each { |entity| entity.erase! if entity.respond_to?(:valid?) && entity.valid? }
          definitions.reverse_each do |definition|
            model.definitions.remove(definition) if definition.respond_to?(:valid?) && definition.valid?
          end
        end
      rescue StandardError => error
        warn "BOM Engine identity cleanup failed: #{error.message}"
      end

      def check(failures, name)
        passed = yield
        puts "  #{passed ? 'PASS' : 'FAIL'} #{name}"
        failures << name unless passed
      rescue StandardError => error
        puts "  FAIL #{name}: #{error.class}: #{error.message}"
        failures << name
      end

      def report(failures)
        raise "Semantic v2 identity runtime failures: #{failures.join('; ')}" unless failures.empty?

        puts 'Semantic v2 identity SketchUp tests: ALL PASSED'
        true
      end
    end
  end
end

BOMEngine::Tests::SemanticV2IdentitySketchupTest.run if defined?(Sketchup)
