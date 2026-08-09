# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../semantic_v2/extractor'
require_relative 'support/semantic_v2_fixtures'

class SemanticV2ExtractorTest < Minitest::Test
  include BOMEngine::Tests::SemanticV2Fixtures

  SECOND_GROUP_INSTANCE_ID = '12000000-0000-4000-8000-000000000012'
  FIRST_ANNOTATION_ID = '13000000-0000-4000-8000-000000000013'
  SECOND_ANNOTATION_ID = '14000000-0000-4000-8000-000000000014'
  DEFINITION_ANNOTATION_ID = '15000000-0000-4000-8000-000000000015'
  DIRECT_FACE_ANNOTATION_ID = '16000000-0000-4000-8000-000000000016'

  def setup
    @fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture
  end

  def test_extracts_loose_nested_and_repeated_geometry_in_one_read_only_traversal
    progress = []
    result = extract(progress: ->(message) { progress << message })

    assert_instance_of BOMEngine::SemanticV2::Snapshot::Document, result
    assert_equal MODEL_ID, result.model_id
    assert_equal 3, result.definitions.length
    assert_equal 5, result.occurrences.length
    assert result.occurrences.any? { |item| item.uuid_path.empty? && item.definition_uuid == MODEL_ID }
    assert_equal 1, result.definitions.count { |definition| definition.source_uuid == SHARED_DEFINITION_ID }
    group_definition = result.definitions.find { |definition| definition.source_uuid == GROUP_DEFINITION_ID }
    assert_equal 'group', group_definition.kind
    shared_occurrences = result.occurrences.select { |item| item.definition_uuid == SHARED_DEFINITION_ID }
    assert_equal [[FIRST_INSTANCE_ID], [SECOND_INSTANCE_ID]],
                 shared_occurrences.select { |item| item.uuid_path.length == 1 }.map(&:uuid_path)
    assert_includes shared_occurrences.map(&:uuid_path), [GROUP_INSTANCE_ID, NESTED_INSTANCE_ID]
    translations = result.occurrences
                         .select { |item| item.definition_uuid == SHARED_DEFINITION_ID && item.uuid_path.length == 1 }
                         .map { |item| item.transform[12] }
    assert_equal [0.254, 0.508], translations
    assert_equal [[SHARED_DEFINITION_ID, SHARED_FACE_ID]],
                 result.primitives.select { |item| item.definition_uuid == SHARED_DEFINITION_ID }.map(&:key)
    assert_includes result.primitives.map(&:source_uuid), ROOT_FACE_ID
    assert_includes result.primitives.map(&:source_uuid), GROUP_FACE_ID
    refute_empty progress
    assert_empty @fixture.model.operation_calls
    assert_empty @fixture.model.writes
  end

  def test_preserves_holes_adjacency_appearance_and_construction_hints_without_triangles
    result = extract
    fragment = result.primitives.find { |item| item.source_uuid == SHARED_FACE_ID }

    assert_equal %w[outer hole], fragment.loops.map(&:kind)
    refute_includes fragment.loops.first.adjacent_primitive_keys,
                    [SHARED_DEFINITION_ID, ADJACENT_FACE_ID]
    assert_equal MATERIAL_ID, fragment.front_material_uuid
    assert_equal [MATERIAL_ID, SECOND_MATERIAL_ID], result.materials.map(&:source_uuid)
    assert_equal ['Concrete', 'Concrete Alternate'], result.materials.map(&:name)
    assert_equal [[120, 121, 122, 255], [120, 121, 122, 255]], result.materials.map(&:rgba)
    group_occurrence = result.occurrences.find { |item| item.uuid_path == [GROUP_INSTANCE_ID] }
    assert_equal SECOND_MATERIAL_ID, group_occurrence.material_uuid
    assert_empty fragment.construction_hints
    assert_equal 12.0 * 0.00064516, fragment.area_m2
    refute_respond_to fragment, :triangles
  end

  def test_extracts_only_allowlisted_construction_attributes_with_deeply_immutable_provenance
    assembly = {
      'system' => 'masonry',
      'layers' => [
        { 'material' => String.new('brick'), 'thickness_m' => 0.12 }
      ]
    }
    @fixture.root_face.set_attribute('BOMEngine.Physical', 'assembly', assembly)
    @fixture.root_face.set_attribute('BOMEngine.Physical', 'private_note', 'ignore me')

    result = extractor.extract(
      model: @fixture.model,
      roots: [@fixture.root_face],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(
        scope_mode: 'selection',
        construction_attribute_allowlist: {
          'BOMEngine.Physical' => ['assembly']
        }
      )
    )
    fragment = result.primitives.fetch(0)
    hint = fragment.construction_hints.fetch(0)

    assert_equal ROOT_FACE_ID, hint.source_uuid
    assert_equal 'BOMEngine.Physical', hint.dictionary
    assert_equal 'assembly', hint.attribute_key
    assert_equal assembly, hint.value
    assert_equal [MODEL_ID, ROOT_FACE_ID], hint.target_key
    pseudo_hint = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::ConstructionHint).any? do |item|
      item.respond_to?(:kind) && item.kind == 'surface_normal'
    end
    refute pseudo_hint
    refute_includes result.evidence.grep(BOMEngine::SemanticV2::Snapshot::ConstructionHint)
                                  .map(&:attribute_key), 'private_note'

    assembly.fetch('layers').first['material'].replace('changed')
    assembly.fetch('layers') << { 'material' => 'late' }
    assert_equal 'brick', hint.value.fetch('layers').first.fetch('material')
    assert_equal 1, hint.value.fetch('layers').length
    assert hint.value.frozen?
    assert hint.value.fetch('layers').frozen?
    assert hint.value.fetch('layers').first.frozen?
  end

  def test_selected_face_preserves_edge_identity_and_types_out_of_scope_adjacency
    @fixture.model.active_path = [@fixture.first_instance]
    result = extractor.extract(
      model: @fixture.model,
      roots: [@fixture.shared_face],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )
    fragment = result.primitives.fetch(0)
    outer = fragment.loops.find { |loop| loop.kind == 'outer' }

    assert_equal outer.vertices.length, outer.edge_source_uuids.length
    expected_edge_ids = @fixture.shared_face.loops.first.edges.map do |edge|
      @fixture.identity_plan.source_uuid_for(edge)
    end
    assert_equal expected_edge_ids, outer.edge_source_uuids
    assert_empty outer.adjacent_primitive_keys
    boundaries = result.evidence.grep(
      BOMEngine::SemanticV2::Snapshot::AdjacencyBoundary
    )
    outside = boundaries.find do |boundary|
      boundary.boundary_type == 'out_of_scope_adjacency' &&
        boundary.adjacent_source_uuid == ADJACENT_FACE_ID
    end
    refute_nil outside
    assert_equal fragment.key, outside.target_key
    assert_equal outer.edge_source_uuids.first, outside.edge_source_uuid
  end

  def test_selected_incident_faces_emit_only_resolved_order_stable_adjacency
    shared_edge = @fixture.shared_face.loops.first.edges.first
    @fixture.adjacent_face.loops.first.edges[0] = shared_edge
    @fixture.shared_definition.entities << @fixture.adjacent_face
    @fixture.model.active_path = [@fixture.first_instance]
    forward = extractor.extract(
      model: @fixture.model,
      roots: [@fixture.shared_face, @fixture.adjacent_face],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )
    reversed = extractor.extract(
      model: @fixture.model,
      roots: [@fixture.adjacent_face, @fixture.shared_face],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )

    shared_key = [SHARED_DEFINITION_ID, SHARED_FACE_ID]
    adjacent_key = [SHARED_DEFINITION_ID, ADJACENT_FACE_ID]
    shared = forward.primitives.find { |primitive| primitive.key == shared_key }
    adjacent = forward.primitives.find { |primitive| primitive.key == adjacent_key }
    assert_includes shared.loops.first.adjacent_primitive_keys, adjacent_key
    assert_includes adjacent.loops.first.adjacent_primitive_keys, shared_key
    assert_equal forward.primitives.map(&:key), reversed.primitives.map(&:key)
    assert_equal forward.primitives.flat_map { |primitive| primitive.loops.map(&:adjacent_primitive_keys) },
                 reversed.primitives.flat_map { |primitive| primitive.loops.map(&:adjacent_primitive_keys) }
  end

  def test_records_hidden_and_policy_exclusions_instead_of_discarding_evidence
    result = extract
    exclusions = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::ExclusionEvidence)
    visibility = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::VisibilityEvidence)

    hidden = exclusions.find { |item| item.target_key.last == HIDDEN_FACE_ID }
    policy = exclusions.find { |item| item.target_key.last == POLICY_FACE_ID }
    assert_equal ['hidden'], hidden.reasons
    assert_equal ['policy_excluded'], policy.reasons
    assert_equal ['visibility.entity_hidden'], hidden.rule_ids
    assert_equal ['fixture.face_policy'], policy.rule_ids
    hidden_visibility = visibility.find { |item| item.target_key.last == HIDDEN_FACE_ID }
    assert hidden_visibility.hidden
    refute hidden_visibility.observed_visible
    refute hidden.eligible
    assert hidden.excluded
    refute_includes result.primitives.map(&:source_uuid), HIDDEN_FACE_ID
    refute_includes result.primitives.map(&:source_uuid), POLICY_FACE_ID
  end

  def test_include_hidden_changes_eligibility_without_erasing_observed_visibility
    result = extractor.extract(
      model: @fixture.model,
      roots: [@fixture.hidden_face],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(include_hidden: true, scope_mode: 'selection')
    )
    visibility = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::VisibilityEvidence)
                       .find { |item| item.target_key.last == HIDDEN_FACE_ID }
    eligibility = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::ExclusionEvidence)
                        .find { |item| item.target_key.last == HIDDEN_FACE_ID }

    assert visibility.hidden
    refute visibility.visible
    assert visibility.tag_visible
    refute visibility.observed_visible
    assert eligibility.eligible
    refute eligibility.excluded
    assert_empty eligibility.reasons
    assert_empty eligibility.rule_ids
    assert_includes result.primitives.map(&:source_uuid), HIDDEN_FACE_ID
  end

  def test_preserves_attached_text_as_explicit_evidence_and_role_as_inferred_evidence
    result = extract
    labels = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::LabelEvidence)
    attached = labels.find { |item| item.target_key == [FIRST_INSTANCE_ID] && item.explicit }
    inferred = labels.find { |item| item.target_key == [FIRST_INSTANCE_ID] && !item.explicit }

    assert_equal 'Pintu Utama', attached.label
    assert_equal 'attached_text', attached.source
    assert_equal TEXT_ID, attached.annotation_source_uuid
    assert_equal [FIRST_INSTANCE_ID], attached.target_occurrence_uuid_path
    assert attached.primary
    assert_equal 'label_first', attached.classification_policy
    assert_equal 'door', inferred.role
    assert_equal 'role_inference', inferred.source
    assert_nil inferred.label
  end

  def test_nested_attached_labels_are_occurrence_correct_and_stably_ordered_by_annotation_uuid
    second_group = FakeInstance.new(
      definition: @fixture.group_instance.definition,
      transformation: FakeTransformation.translation(0, 10, 0),
      name: 'Second Nested Group',
      kind: 'group'
    )
    edge = @fixture.shared_face.loops.first.edges.first
    first_annotation = FakeText.new(
      text: 'Pintu Utama',
      path: [@fixture.group_instance, @fixture.nested_instance, edge]
    )
    second_annotation = FakeText.new(
      text: 'Jendela Samping',
      path: [@fixture.group_instance, @fixture.nested_instance, edge]
    )
    @fixture.identity_plan.remember(second_group, SECOND_GROUP_INSTANCE_ID)
    @fixture.identity_plan.remember(first_annotation, FIRST_ANNOTATION_ID)
    @fixture.identity_plan.remember(second_annotation, SECOND_ANNOTATION_ID)
    roots = [second_annotation, second_group, first_annotation, @fixture.group_instance]

    forward = extractor.extract(
      model: @fixture.model,
      roots: roots,
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )
    reversed = extractor.extract(
      model: @fixture.model,
      roots: roots.reverse,
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )

    target_path = [GROUP_INSTANCE_ID, NESTED_INSTANCE_ID]
    sibling_path = [SECOND_GROUP_INSTANCE_ID, NESTED_INSTANCE_ID]
    attached = forward.evidence.grep(BOMEngine::SemanticV2::Snapshot::LabelEvidence).select do |item|
      item.source == 'attached_text'
    end
    assert_equal [FIRST_ANNOTATION_ID, SECOND_ANNOTATION_ID],
                 attached.map(&:annotation_source_uuid)
    assert attached.all? { |item| item.target_occurrence_uuid_path == target_path }
    refute attached.any? { |item| item.target_key == sibling_path }
    primary = attached.find(&:primary)
    assert_equal FIRST_ANNOTATION_ID, primary.annotation_source_uuid
    assert_equal 'Pintu Utama', primary.label
    forward_shape = attached.map do |item|
      [item.target_key, item.annotation_source_uuid, item.label, item.primary, item.aliases]
    end
    reversed_shape = reversed.evidence.grep(BOMEngine::SemanticV2::Snapshot::LabelEvidence)
                             .select { |item| item.source == 'attached_text' }
                             .map do |item|
      [item.target_key, item.annotation_source_uuid, item.label, item.primary, item.aliases]
    end
    assert_equal forward_shape, reversed_shape
  end

  def test_unplanned_attached_annotation_is_rejected_instead_of_using_object_identity
    annotation = FakeText.new(
      text: 'Unplanned Label',
      path: [@fixture.first_instance, @fixture.shared_face.loops.first.edges.first]
    )

    assert_raises(KeyError) do
      extractor.extract(
        model: @fixture.model,
        roots: [@fixture.first_instance, annotation],
        parent_transform: FakeTransformation.identity,
        identity_plan: @fixture.identity_plan,
        settings: settings.merge(scope_mode: 'selection')
      )
    end
  end

  def test_definition_resident_attached_label_is_composed_for_each_parent_occurrence
    second_group = FakeInstance.new(
      definition: @fixture.group_instance.definition,
      transformation: FakeTransformation.translation(0, 10, 0),
      name: 'Second Nested Group',
      kind: 'group'
    )
    annotation = FakeText.new(
      text: 'Pintu Dalam',
      path: [@fixture.nested_instance, @fixture.shared_face.loops.first.edges.first]
    )
    @fixture.group_instance.definition.entities << annotation
    @fixture.identity_plan.remember(second_group, SECOND_GROUP_INSTANCE_ID)
    @fixture.identity_plan.remember(annotation, DEFINITION_ANNOTATION_ID)

    result = extractor.extract(
      model: @fixture.model,
      roots: [second_group, @fixture.group_instance],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )

    attached = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::LabelEvidence).select do |item|
      item.source == 'attached_text' && item.annotation_source_uuid == DEFINITION_ANNOTATION_ID
    end
    assert_equal [
      [GROUP_INSTANCE_ID, NESTED_INSTANCE_ID],
      [SECOND_GROUP_INSTANCE_ID, NESTED_INSTANCE_ID]
    ].sort, attached.map(&:target_occurrence_uuid_path).sort
    assert attached.all? { |item| item.target_key == item.target_occurrence_uuid_path }
  end

  def test_direct_face_attached_label_carries_the_active_occurrence_context
    annotation = FakeText.new(text: 'Panel Aktif', path: [@fixture.shared_face])
    @fixture.shared_definition.entities << annotation
    @fixture.identity_plan.remember(annotation, DIRECT_FACE_ANNOTATION_ID)
    @fixture.model.active_path = [@fixture.first_instance]

    result = extractor.extract(
      model: @fixture.model,
      roots: @fixture.shared_definition.entities,
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )

    attached = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::LabelEvidence).find do |item|
      item.annotation_source_uuid == DIRECT_FACE_ANNOTATION_ID
    end
    assert_equal [SHARED_DEFINITION_ID, SHARED_FACE_ID], attached.target_key
    assert_equal [FIRST_INSTANCE_ID], attached.target_occurrence_uuid_path
  end

  def test_identity_is_independent_of_names_root_order_and_transform_values
    initial = extract
    @fixture.first_instance.name = 'Renamed without identity effect'
    @fixture.first_instance.transformation = FakeTransformation.translation(30, 0, 0)
    reordered = extractor.extract(
      model: @fixture.model,
      roots: @fixture.roots.reverse,
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings
    )

    assert_equal initial.primitives.map(&:key).sort, reordered.primitives.map(&:key).sort
    assert_equal initial.occurrences.map(&:uuid_path).sort, reordered.occurrences.map(&:uuid_path).sort
    moved = reordered.occurrences.find { |item| item.uuid_path == [FIRST_INSTANCE_ID] }
    assert_equal 0.762, moved.transform[12]
  end

  def test_nonidentity_parent_transform_is_explicit_for_loose_and_instanced_geometry
    parent = FakeTransformation.new([
      0.0, 1.0, 0.0, 0.0,
      -1.0, 0.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      2.0, 0.0, 0.0, 1.0
    ])

    result = extractor.extract(
      model: @fixture.model,
      roots: @fixture.roots,
      parent_transform: parent,
      identity_plan: @fixture.identity_plan,
      settings: settings
    )

    root = result.occurrences.find { |item| item.uuid_path.empty? }
    refute_nil root
    assert_equal MODEL_ID, root.definition_uuid
    assert_equal [0.0, 1.0, 0.0, 0.0,
                  -1.0, 0.0, 0.0, 0.0,
                  0.0, 0.0, 1.0, 0.0,
                  0.0508, 0.0, 0.0, 1.0], root.transform
    loose = result.primitives.find { |item| item.source_uuid == ROOT_FACE_ID }
    assert_equal [0.0, 0.0, 0.0], loose.loops.first.vertices.first
    first = result.occurrences.find { |item| item.uuid_path == [FIRST_INSTANCE_ID] }
    assert_equal [0.0508, 0.254], [first.transform[12], first.transform[13]]
  end

  def test_scope_records_sorted_roots_policy_identity_and_model_context
    result = extract
    expected_roots = @fixture.roots.map do |root|
      @fixture.identity_plan.source_uuid_for(root)
    end.sort

    assert_equal 'model', result.scope.mode
    assert_equal expected_roots, result.scope.root_source_uuids
    assert_empty result.scope.context_occurrence_uuid_path
    assert_equal MODEL_ID, result.scope.root_definition_uuid
    assert_equal 'fixture-extraction-policy/1.0.0', result.scope.extraction_policy_id
    assert_nil result.scope.reconstruction_policy_id
    assert result.scope.frozen?
  end

  def test_callable_extraction_policy_requires_an_explicit_policy_identity
    unidentified = settings.dup
    unidentified.delete(:extraction_policy_id)

    error = assert_raises(ArgumentError) do
      extractor.extract(
        model: @fixture.model,
        roots: [@fixture.root_face],
        parent_transform: FakeTransformation.identity,
        identity_plan: @fixture.identity_plan,
        settings: unidentified.merge(scope_mode: 'selection')
      )
    end

    assert_match(/extraction_policy_id/, error.message)
  end

  def test_model_scope_rejects_partial_or_duplicate_root_claims
    partial = assert_raises(ArgumentError) do
      extractor.extract(
        model: @fixture.model,
        roots: [@fixture.root_face],
        parent_transform: FakeTransformation.identity,
        identity_plan: @fixture.identity_plan,
        settings: settings.merge(scope_mode: 'model')
      )
    end
    assert_match(/model scope requires all model roots/, partial.message)

    duplicate = assert_raises(ArgumentError) do
      extractor.extract(
        model: @fixture.model,
        roots: [@fixture.root_face, @fixture.root_face],
        parent_transform: FakeTransformation.identity,
        identity_plan: @fixture.identity_plan,
        settings: settings.merge(scope_mode: 'selection')
      )
    end
    assert_match(/duplicate extraction roots/, duplicate.message)
  end

  def test_model_scope_rejects_an_active_occurrence_context
    @fixture.model.active_path = [@fixture.first_instance]

    error = assert_raises(ArgumentError) do
      extractor.extract(
        model: @fixture.model,
        roots: @fixture.shared_definition.entities,
        parent_transform: FakeTransformation.identity,
        identity_plan: @fixture.identity_plan,
        settings: settings.merge(scope_mode: 'model')
      )
    end

    assert_match(/model scope requires an empty context/, error.message)
  end

  def test_active_context_rejects_roots_outside_the_edited_definition
    @fixture.model.active_path = [@fixture.first_instance]

    error = assert_raises(ArgumentError) do
      extractor.extract(
        model: @fixture.model,
        roots: [@fixture.root_face],
        parent_transform: FakeTransformation.identity,
        identity_plan: @fixture.identity_plan,
        settings: settings.merge(scope_mode: 'selection')
      )
    end

    assert_match(/active-context roots.*edited definition/, error.message)
  end

  def test_active_context_accepts_model_root_annotation_with_matching_absolute_path
    annotation = FakeText.new(
      text: 'Pintu Konteks',
      path: [
        @fixture.group_instance,
        @fixture.nested_instance,
        @fixture.shared_face.loops.first.edges.first
      ]
    )
    @fixture.identity_plan.remember(annotation, DIRECT_FACE_ANNOTATION_ID)
    @fixture.model.active_path = [@fixture.group_instance]

    result = extractor.extract(
      model: @fixture.model,
      roots: @fixture.group_instance.definition.entities + [annotation],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )

    attached = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::LabelEvidence).find do |item|
      item.annotation_source_uuid == DIRECT_FACE_ANNOTATION_ID
    end
    assert_equal [GROUP_INSTANCE_ID, NESTED_INSTANCE_ID], attached.target_key
    assert_equal attached.target_key, attached.target_occurrence_uuid_path
  end

  def test_definition_entities_are_walked_once_and_adjacency_is_resolved_after_extraction
    definition = @fixture.group_instance.definition
    entities = definition.entities
    reads = 0
    definition.define_singleton_method(:entities) do
      reads += 1
      entities
    end

    result = extractor.extract(
      model: @fixture.model,
      roots: [@fixture.group_instance],
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )

    assert_equal 1, reads
    assert result.primitives.any? { |primitive| primitive.source_uuid == GROUP_FACE_ID }
    assert result.primitives.any? { |primitive| primitive.source_uuid == SHARED_FACE_ID }
  end

  def test_snapshot_retains_true_north_context_transform_and_typed_foreign_provenance
    provenance_type = Struct.new(:source_uuid, :origin_model_id, :destination_source_uuid)
    @fixture.identity_plan.foreign_source_provenance = [
      provenance_type.new(TEXT_ID, SECOND_MATERIAL_ID, FIRST_ANNOTATION_ID)
    ].freeze
    @fixture.model.shadow_info['NorthAngle'] = 30.0

    result = extractor.extract(
      model: @fixture.model,
      roots: @fixture.roots,
      parent_transform: FakeTransformation.translation(2, 0, 0),
      identity_plan: @fixture.identity_plan,
      settings: settings
    )

    assert_in_delta 0.5, result.model_context.true_north_xy[0], 1.0e-12
    assert_in_delta Math.sqrt(3.0) / 2.0,
                    result.model_context.true_north_xy[1], 1.0e-12
    assert_equal 0.0508, result.model_context.context_transform[12]
    provenance = result.foreign_source_provenance.fetch(0)
    assert_instance_of BOMEngine::SemanticV2::Snapshot::ForeignSourceProvenance, provenance
    assert_equal TEXT_ID, provenance.source_uuid
    assert_equal SECOND_MATERIAL_ID, provenance.origin_model_id
    assert_equal FIRST_ANNOTATION_ID, provenance.destination_source_uuid
    assert provenance.frozen?
  end

  def test_active_context_uses_edited_occurrence_path_and_actual_definition_owner
    @fixture.model.active_path = [@fixture.first_instance]
    first = extractor.extract(
      model: @fixture.model,
      roots: @fixture.shared_definition.entities,
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )
    @fixture.model.active_path = [@fixture.second_instance]
    second = extractor.extract(
      model: @fixture.model,
      roots: @fixture.shared_definition.entities,
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings.merge(scope_mode: 'selection')
    )

    first_root = first.occurrences.find { |item| item.uuid_path == [FIRST_INSTANCE_ID] }
    second_root = second.occurrences.find { |item| item.uuid_path == [SECOND_INSTANCE_ID] }
    refute_nil first_root
    refute_nil second_root
    assert_equal SHARED_DEFINITION_ID, first_root.definition_uuid
    assert_equal SHARED_DEFINITION_ID, second_root.definition_uuid
    assert_equal [SHARED_DEFINITION_ID, SHARED_FACE_ID], first.primitives.fetch(0).key
    assert_equal first.primitives.fetch(0).key, second.primitives.fetch(0).key
    assert_equal [FIRST_INSTANCE_ID, SHARED_DEFINITION_ID, SHARED_FACE_ID],
                 BOMEngine::SemanticV2::Snapshot.occurrence_fragment_key(
                   occurrence: first_root,
                   primitive: first.primitives.fetch(0)
                 )
    assert_equal [SECOND_INSTANCE_ID, SHARED_DEFINITION_ID, SHARED_FACE_ID],
                 BOMEngine::SemanticV2::Snapshot.occurrence_fragment_key(
                   occurrence: second_root,
                   primitive: second.primitives.fetch(0)
                 )
  end

  def test_material_missing_from_virtual_identity_plan_is_rejected
    @fixture.identity_plan.forget(@fixture.material)

    assert_raises(KeyError) { extract }
  end

  def test_texture_dimensions_are_explicit_metric_values
    texture = Struct.new(:filename, :width, :height).new('surface.png', 10.0, 20.0)
    @fixture.material.texture = texture

    result = extract
    material = result.materials.find { |item| item.source_uuid == MATERIAL_ID }

    assert_equal 'surface.png', material.texture.fetch(:filename)
    assert_equal 0.254, material.texture.fetch(:width_m)
    assert_equal 0.508, material.texture.fetch(:height_m)
    refute material.texture.key?(:width)
    refute material.texture.key?(:height)
    assert material.texture.frozen?
  end

  private

  def extract(progress: nil)
    extractor.extract(
      model: @fixture.model,
      roots: @fixture.roots,
      parent_transform: FakeTransformation.identity,
      identity_plan: @fixture.identity_plan,
      settings: settings,
      progress: progress
    )
  end

  def extractor
    BOMEngine::SemanticV2::Extractor
  end

  def settings
    {
      include_hidden: false,
      face_policy: ->(face) { !face.policy_excluded },
      face_policy_rule_id: 'fixture.face_policy',
      scope_mode: 'model',
      extraction_policy_id: 'fixture-extraction-policy/1.0.0'
    }
  end
end
