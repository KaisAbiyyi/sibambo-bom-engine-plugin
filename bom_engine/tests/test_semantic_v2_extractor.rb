# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../semantic_v2/extractor'
require_relative 'support/semantic_v2_fixtures'

class SemanticV2ExtractorTest < Minitest::Test
  include BOMEngine::Tests::SemanticV2Fixtures

  def setup
    @fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture
  end

  def test_extracts_loose_nested_and_repeated_geometry_in_one_read_only_traversal
    progress = []
    result = extract(progress: ->(message) { progress << message })

    assert_instance_of BOMEngine::SemanticV2::Snapshot::Document, result
    assert_equal MODEL_ID, result.model_id
    assert_equal 3, result.definitions.length
    assert_equal 3, result.occurrences.length
    assert_equal 1, result.definitions.count { |definition| definition.source_uuid == SHARED_DEFINITION_ID }
    assert_equal [[FIRST_INSTANCE_ID], [SECOND_INSTANCE_ID]],
                 result.occurrences.select { |item| item.definition_uuid == SHARED_DEFINITION_ID }.map(&:uuid_path)
    translations = result.occurrences
                         .select { |item| item.definition_uuid == SHARED_DEFINITION_ID }
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
    assert_includes fragment.loops.first.adjacent_primitive_keys,
                    [SHARED_DEFINITION_ID, ADJACENT_FACE_ID]
    assert_equal MATERIAL_ID, fragment.front_material_uuid
    assert_equal MATERIAL_ID, result.materials.first.source_uuid
    assert_equal [120, 121, 122, 255], result.materials.first.rgba
    group_occurrence = result.occurrences.find { |item| item.uuid_path == [GROUP_INSTANCE_ID] }
    assert_equal MATERIAL_ID, group_occurrence.material_uuid
    assert_equal 'surface_normal', fragment.construction_hints.first.kind
    assert_equal 12.0 * 0.00064516, fragment.area_m2
    refute_respond_to fragment, :triangles
  end

  def test_records_hidden_and_policy_exclusions_instead_of_discarding_evidence
    result = extract
    exclusions = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::ExclusionEvidence)

    hidden = exclusions.find { |item| item.target_key.last == HIDDEN_FACE_ID }
    policy = exclusions.find { |item| item.target_key.last == POLICY_FACE_ID }
    assert_equal ['hidden'], hidden.reasons
    assert_equal ['policy_excluded'], policy.reasons
    refute hidden.eligible
    assert hidden.excluded
    refute_includes result.primitives.map(&:source_uuid), HIDDEN_FACE_ID
    refute_includes result.primitives.map(&:source_uuid), POLICY_FACE_ID
  end

  def test_preserves_attached_text_as_explicit_evidence_and_role_as_inferred_evidence
    result = extract
    labels = result.evidence.grep(BOMEngine::SemanticV2::Snapshot::LabelEvidence)
    attached = labels.find { |item| item.target_key == [FIRST_INSTANCE_ID] && item.explicit }
    inferred = labels.find { |item| item.target_key == [FIRST_INSTANCE_ID] && !item.explicit }

    assert_equal 'Pintu Utama', attached.label
    assert_equal 'attached_text', attached.source
    assert_equal 'label_first', attached.classification_policy
    assert_equal 'door', inferred.role
    assert_equal 'role_inference', inferred.source
    assert_nil inferred.label
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

  def test_unplanned_material_uses_deterministic_appearance_identity_only
    @fixture.identity_plan.forget(@fixture.material)

    initial = extract
    repeated = extract

    material_uuid = initial.materials.first.source_uuid
    assert_match BOMEngine::SemanticV2::IdentityRegistry::UUID_PATTERN, material_uuid
    assert_equal material_uuid, repeated.materials.first.source_uuid
    assert_includes initial.diagnostics, 'material.virtual_appearance_identity'
    assert_equal material_uuid,
                 initial.occurrences.find { |item| item.uuid_path == [GROUP_INSTANCE_ID] }.material_uuid
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
      face_policy: ->(face) { !face.policy_excluded }
    }
  end
end
