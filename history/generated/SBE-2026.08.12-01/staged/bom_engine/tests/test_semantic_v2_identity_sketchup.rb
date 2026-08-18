# frozen_string_literal: true

# Run in the SketchUp Ruby Console:
# load 'D:/projects/sibambo/bom_engine_plugin-semantic-v2-m1/bom_engine/tests/test_semantic_v2_identity_sketchup.rb'

require_relative '../semantic_v2'
require_relative '../semantic_v2/identity_coordinator'
require 'tmpdir'

module SibamboHistory
  module V20260812_01
  module Tests
    module SemanticV2IdentitySketchupTest
      module_function

      COORDINATOR = SibamboHistory::V20260812_01::SemanticV2::IdentityCoordinator
      DICTIONARY = COORDINATOR::DICTIONARY
      FOREIGN_MODEL_ID = 'fa000000-0000-4000-8000-000000000001'
      FOREIGN_SOURCE_ID = 'fb000000-0000-4000-8000-000000000002'
      FOREIGN_DEFINITION_ID = 'fc000000-0000-4000-8000-000000000003'
      FOREIGN_FACE_ID = 'fd000000-0000-4000-8000-000000000004'
      FOREIGN_MATERIAL_ID = 'fe000000-0000-4000-8000-000000000005'

      def run
        raise 'SketchUp API is unavailable' unless defined?(Sketchup)

        model = Sketchup.active_model
        assert_disposable_model!(model)
        disposable_fixture = false
        created = []
        definitions = []
        materials = []
        temporary_files = []
        failures = []

        unless supported_runtime?
          error = begin
            COORDINATOR.plan(model: model, roots: [])
            nil
          rescue COORDINATOR::UnsupportedRuntimeError => caught
            caught
          end
          check(failures, 'pre-2020.1 runtime is rejected without blocking plugin load') do
            error && error.code == 'identity.unsupported_runtime.sketchup_before_2020_1'
          end
          return report(failures)
        end
        disposable_fixture = true

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
        material = in_operation(model, 'BOM Engine identity material PID fixture') do
          item = model.materials.add("BOM Engine identity material #{Time.now.to_f}")
          definition_face.material = item
          materials << item
          item
        end
        check(failures, 'required definition and material owners expose positive persistent IDs') do
          definition.persistent_id.to_i.positive? && material.persistent_id.to_i.positive?
        end

        foreign, foreign_definition, foreign_face, foreign_material = imported_foreign_fixture(
          model,
          root,
          definitions,
          materials,
          temporary_files
        )
        foreign_plan = COORDINATOR.plan(model: model, roots: [root])
        imported_sources = [
          [foreign, FOREIGN_SOURCE_ID],
          [foreign_definition, FOREIGN_DEFINITION_ID],
          [foreign_face, FOREIGN_FACE_ID],
          [foreign_material, FOREIGN_MATERIAL_ID]
        ]
        imported_provenance = imported_sources.map do |_entity, prior_source_uuid|
          foreign_plan.foreign_source_provenance.find do |item|
            item.source_uuid == prior_source_uuid && item.origin_model_id == FOREIGN_MODEL_ID
          end
        end
        check(failures, 'foreign .skp insertion rebases nested identity with typed provenance') do
          imported_sources.zip(imported_provenance).all? do |(entity, prior_source_uuid), provenance|
            foreign_plan.source_uuid_for(entity) != prior_source_uuid &&
              provenance &&
              provenance.destination_source_uuid == foreign_plan.source_uuid_for(entity)
          end
        end
        COORDINATOR.send(:commit!, model: model, plan: foreign_plan)

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
        cleanup(model, created, definitions, materials, temporary_files) if model && disposable_fixture
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

      def supported_runtime?
        parts = Sketchup.version.to_s.split('.').first(2).map(&:to_i)
        parts << 0 while parts.length < 2
        (parts <=> [20, 1]) >= 0
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

      def imported_foreign_fixture(model, root, definitions, materials, temporary_files)
        token = "#{Process.pid}-#{(Time.now.to_f * 1_000_000).to_i}"
        path = File.join(Dir.tmpdir, "bom-engine-semantic-v2-foreign-#{token}.skp")
        temporary_files << path
        source_definition = nil
        source_material = nil
        in_operation(model, 'BOM Engine identity foreign source fixture') do
          source_definition = model.definitions.add("BOM Engine foreign source #{token}")
          source_definition.set_attribute(DICTIONARY, 'source_uuid', FOREIGN_DEFINITION_ID)
          source_definition.set_attribute(DICTIONARY, 'origin_model_id', FOREIGN_MODEL_ID)
          source_group = source_definition.entities.add_group
          source_group.set_attribute(DICTIONARY, 'source_uuid', FOREIGN_SOURCE_ID)
          source_group.set_attribute(DICTIONARY, 'origin_model_id', FOREIGN_MODEL_ID)
          source_face = source_group.entities.add_face(
            [0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]
          )
          source_face.set_attribute(DICTIONARY, 'source_uuid', FOREIGN_FACE_ID)
          source_face.set_attribute(DICTIONARY, 'origin_model_id', FOREIGN_MODEL_ID)
          source_material = model.materials.add("BOM Engine foreign material #{token}")
          source_material.set_attribute(DICTIONARY, 'source_uuid', FOREIGN_MATERIAL_ID)
          source_material.set_attribute(DICTIONARY, 'origin_model_id', FOREIGN_MODEL_ID)
          source_face.material = source_material
        end
        saved = source_definition.save_as(path)
        raise 'failed to save disposable foreign .skp fixture' unless saved

        in_operation(model, 'BOM Engine remove foreign source fixture') do
          model.definitions.remove(source_definition)
          model.materials.remove(source_material) if source_material.valid?
        end
        loaded_definition = nil
        foreign_instance = nil
        in_operation(model, 'BOM Engine identity foreign .skp insertion fixture') do
          loaded_definition = model.definitions.load(path)
          foreign_instance = root.entities.add_instance(loaded_definition, Geom::Transformation.new)
        end
        definitions << loaded_definition
        loaded_group = loaded_definition.entities.grep(Sketchup::Group).first
        loaded_face = loaded_group.entities.grep(Sketchup::Face).first
        loaded_material = loaded_face.material
        materials << loaded_material if loaded_material
        [loaded_group, loaded_definition, loaded_face, loaded_material]
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

      def cleanup(model, created, definitions, materials, temporary_files)
        in_operation(model, 'BOM Engine identity runtime cleanup') do
          created.reverse_each { |entity| entity.erase! if entity.respond_to?(:valid?) && entity.valid? }
          materials.reverse_each do |material|
            model.materials.remove(material) if material.respond_to?(:valid?) && material.valid?
          end
          definitions.reverse_each do |definition|
            model.definitions.remove(definition) if definition.respond_to?(:valid?) && definition.valid?
          end
        end
        temporary_files.each { |path| File.delete(path) if File.file?(path) }
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

SibamboHistory::V20260812_01::Tests::SemanticV2IdentitySketchupTest.run if defined?(Sketchup)

end # SibamboHistory
