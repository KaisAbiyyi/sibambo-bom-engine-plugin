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
          outside_neighbor = fixture.entities.add_face([2, 0, 0], [3, 0, 0], [3, 2, 0], [2, 2, 0])
          hidden = fixture.entities.add_face([4, 0, 0], [5, 0, 0], [5, 1, 0], [4, 1, 0])
          hidden.hidden = true
          policy_excluded = fixture.entities.add_face([6, 0, 0], [7, 0, 0], [7, 1, 0], [6, 1, 0])
          loose.set_attribute(
            'BOMEngine.Physical',
            'assembly',
            ['masonry', ['brick', 0.12]]
          )

          shared = model.definitions.add('Semantic v2 Shared Door')
          shared_face = shared.entities.add_face([0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0])
          front_material = model.materials.add('Semantic v2 Concrete')
          front_material.color = Sketchup::Color.new(120, 121, 122)
          alternate_material = model.materials.add('Semantic v2 Concrete Alternate')
          alternate_material.color = Sketchup::Color.new(120, 121, 122)
          shared_face.material = front_material
          inner = shared.entities.add_face([1, 1, 0], [1, 3, 0], [3, 3, 0], [3, 1, 0])
          inner.erase! if inner && !inner.deleted?
          first = fixture.entities.add_instance(shared, Geom::Transformation.translation([10, 0, 0]))
          first.name = 'Pintu cadangan'
          second = fixture.entities.add_instance(shared, Geom::Transformation.translation([20, 0, 0]))

          nested = fixture.entities.add_group
          nested.name = 'Nested Group'
          nested.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
          nested.material = alternate_material
          nested_child = nested.entities.add_instance(
            shared,
            Geom::Transformation.translation([1, 0, 0])
          )

          parent_definition = model.definitions.add('Semantic v2 Repeated Parent')
          parent_child = parent_definition.entities.add_instance(
            shared,
            Geom::Transformation.translation([1, 0, 0])
          )
          parent_a = fixture.entities.add_instance(
            parent_definition,
            Geom::Transformation.translation([0, 8, 0])
          )
          parent_b = fixture.entities.add_instance(
            parent_definition,
            Geom::Transformation.translation([0, 16, 0])
          )

          roots = fixture.entities.to_a
          first_text = build_attached_text(
            model,
            [fixture, parent_a, parent_child],
            shared_face,
            'Pintu Utama'
          )
          second_text = build_attached_text(
            model,
            [fixture, parent_a, parent_child],
            shared_face,
            'Jendela Samping'
          )
          extraction_roots = roots + [second_text, first_text]
          plan = SemanticV2::IdentityCoordinator.plan(model: model, roots: extraction_roots)
          before_uuid = loose.get_attribute('BOMEngine.SemanticV2', 'source_uuid', nil)
          parent_transform = Geom::Transformation.translation([2, 0, 0])
          snapshot = SemanticV2::Extractor.extract(
            model: model,
            roots: extraction_roots,
            parent_transform: parent_transform,
            identity_plan: plan,
            settings: {
              include_hidden: false,
              face_policy: ->(face) { !face.equal?(policy_excluded) },
              face_policy_rule_id: 'fixture.policy_excluded',
              scope_mode: 'selection',
              context_path: [fixture],
              extraction_policy_id: 'fixture-extraction/1.0.0',
              construction_attribute_allowlist: {
                'BOMEngine.Physical' => ['assembly']
              }
            }
          )

          assert(snapshot.primitives.any? { |item| item.source_uuid == plan.source_uuid_for(loose) }, 'loose face extracted')
          assert(snapshot.definitions.count { |item| item.source_uuid == plan.source_uuid_for(shared) } == 1, 'shared definition stored once')
          shared_occurrences = snapshot.occurrences.select { |item| item.definition_uuid == plan.source_uuid_for(shared) }
          assert(shared_occurrences.length == 5, 'repeated and nested instances have separate occurrences')
          assert(shared_occurrences.map(&:uuid_path).uniq.length == 5, 'occurrences use UUID paths')
          nested_path = [
            plan.occurrence_uuid_for(fixture),
            plan.occurrence_uuid_for(nested),
            plan.occurrence_uuid_for(nested_child)
          ]
          assert(shared_occurrences.any? { |item| item.uuid_path == nested_path }, 'genuinely nested UUID occurrence path extracted')
          assert(snapshot.occurrences.any? { |item| item.definition_uuid == plan.source_uuid_for(nested.definition) }, 'nested group occurrence extracted')
          group_definition = snapshot.definitions.find { |item| item.source_uuid == plan.source_uuid_for(nested.definition) }
          assert(group_definition.kind == 'group', 'SketchUp group definition classified through group?')
          root_path = [plan.occurrence_uuid_for(fixture)]
          root_occurrence = snapshot.occurrences.find { |item| item.uuid_path == root_path }
          assert(root_occurrence && root_occurrence.transform[12] == 0.0508, 'active context path and parent transform represented by root occurrence')
          assert(snapshot.scope.context_occurrence_uuid_path == root_path, 'active context UUID path recorded in scope')
          assert(snapshot.scope.root_definition_uuid == plan.source_uuid_for(fixture.definition), 'actual active-context definition owns loose roots')
          polygon = snapshot.primitives.find { |item| item.source_uuid == plan.source_uuid_for(shared_face) }
          assert(polygon.loops.count { |loop| loop.kind == 'hole' } == 1, 'face hole preserved')
          exclusions = snapshot.evidence.grep(SemanticV2::Snapshot::ExclusionEvidence)
          assert(exclusions.any? { |item| item.target_key.last == plan.source_uuid_for(hidden) && item.reasons.include?('hidden') }, 'hidden exclusion preserved')
          assert(exclusions.any? { |item| item.target_key.last == plan.source_uuid_for(policy_excluded) && item.rule_ids.include?('fixture.policy_excluded') }, 'policy exclusion preserves stable rule ID')
          labels = snapshot.evidence.grep(SemanticV2::Snapshot::LabelEvidence)
          target_path = [
            plan.occurrence_uuid_for(fixture),
            plan.occurrence_uuid_for(parent_a),
            plan.occurrence_uuid_for(parent_child)
          ]
          sibling_path = [
            plan.occurrence_uuid_for(fixture),
            plan.occurrence_uuid_for(parent_b),
            plan.occurrence_uuid_for(parent_child)
          ]
          attached_labels = labels.select { |item| item.source == 'attached_text' }
          assert(attached_labels.all? { |item| item.target_occurrence_uuid_path == target_path }, 'nested labels retain their complete target occurrence path')
          assert(attached_labels.none? { |item| item.target_key == sibling_path }, 'nested label does not leak to repeated sibling occurrence')
          assert(attached_labels.map(&:annotation_source_uuid).compact.length == 2, 'attached labels retain annotation source UUIDs')
          construction = snapshot.evidence.grep(SemanticV2::Snapshot::ConstructionHint)
          assert(construction.any? { |item| item.source_uuid == plan.source_uuid_for(loose) && item.dictionary == 'BOMEngine.Physical' && item.attribute_key == 'assembly' }, 'allowlisted physical construction attributes preserved')
          material_ids = snapshot.materials.map(&:source_uuid)
          assert(material_ids.include?(plan.source_uuid_for(front_material)), 'front material consumes planned source UUID')
          assert(material_ids.include?(plan.source_uuid_for(alternate_material)), 'override material consumes distinct planned source UUID')

          selected = SemanticV2::Extractor.extract(
            model: model,
            roots: [loose],
            parent_transform: Geom::Transformation.new,
            identity_plan: plan,
            settings: {
              include_hidden: false,
              scope_mode: 'selection',
              context_path: [fixture],
              extraction_policy_id: 'fixture-extraction/1.0.0'
            }
          )
          selected_loop = selected.primitives.fetch(0).loops.fetch(0)
          assert(selected_loop.edge_source_uuids.length == selected_loop.vertices.length, 'selected face retains one source UUID per edge segment')
          boundaries = selected.evidence.grep(SemanticV2::Snapshot::AdjacencyBoundary)
          assert(boundaries.any? { |item| item.adjacent_source_uuid == plan.source_uuid_for(outside_neighbor) && item.boundary_type == 'out_of_scope_adjacency' }, 'unselected incident face becomes typed out-of-scope adjacency')

          first_context = SemanticV2::Extractor.extract(
            model: model,
            roots: parent_definition.entities,
            parent_transform: parent_a.transformation,
            identity_plan: plan,
            settings: {
              include_hidden: false,
              scope_mode: 'selection',
              context_path: [fixture, parent_a],
              extraction_policy_id: 'fixture-extraction/1.0.0'
            }
          )
          second_context = SemanticV2::Extractor.extract(
            model: model,
            roots: parent_definition.entities,
            parent_transform: parent_b.transformation,
            identity_plan: plan,
            settings: {
              include_hidden: false,
              scope_mode: 'selection',
              context_path: [fixture, parent_b],
              extraction_policy_id: 'fixture-extraction/1.0.0'
            }
          )
          assert(first_context.scope.context_occurrence_uuid_path != second_context.scope.context_occurrence_uuid_path, 'edited repeated occurrences retain distinct context paths')
          assert(first_context.primitives.map(&:key) == second_context.primitives.map(&:key), 'active-context occurrences share definition-local primitive keys')
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

      def build_attached_text(model, instances, face, label)
        edge = face.edges.first
        path = Sketchup::InstancePath.new(instances + [edge])
        transform = instances.inject(Geom::Transformation.new) do |combined, instance|
          combined * instance.transformation
        end
        point = edge.start.position.transform(transform)
        model.entities.add_text(
          label,
          [path, point],
          Geom::Vector3d.new(4, 4, 4)
        )
      end

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition

        puts "PASS: #{message}"
      end
    end
  end
end

BOMEngine::Tests::SemanticV2ExtractorSketchupTest.run
