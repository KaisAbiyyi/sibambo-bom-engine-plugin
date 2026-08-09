# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../semantic_v2/snapshot'

class SemanticV2SnapshotTest < Minitest::Test
  MODEL_ID = '10000000-0000-4000-8000-000000000001'
  DEFINITION_ID = '20000000-0000-4000-8000-000000000002'
  INSTANCE_ID = '30000000-0000-4000-8000-000000000003'
  FACE_ID = '40000000-0000-4000-8000-000000000004'
  MATERIAL_ID = '50000000-0000-4000-8000-000000000005'
  SECOND_FACE_ID = '60000000-0000-4000-8000-000000000006'
  ANNOTATION_ID = 'a0000000-0000-4000-8000-00000000000a'
  EDGE_IDS = [
    '70000000-0000-4000-8000-000000000007',
    '80000000-0000-4000-8000-000000000008',
    '90000000-0000-4000-8000-000000000009'
  ].freeze

  def test_document_rejects_mutable_top_level_collections
    error = assert_raises(ArgumentError) do
      snapshot::Document.new(
        model_id: MODEL_ID,
        scope: scope_record,
        model_context: model_context_record,
        occurrences: [],
        definitions: [].freeze,
        primitives: [].freeze,
        materials: [].freeze,
        evidence: [].freeze,
        foreign_source_provenance: [].freeze,
        diagnostics: [].freeze
      )
    end

    assert_match(/occurrences must be frozen/, error.message)
  end

  def test_occurrence_rejects_non_uuid_path_components
    error = assert_raises(ArgumentError) do
      snapshot::Occurrence.new(
        uuid_path: ['Nested Group', 7].freeze,
        definition_uuid: DEFINITION_ID,
        transform: identity_transform
      )
    end

    assert_match(/uuid_path.*UUID/, error.message)
  end

  def test_scope_rejects_any_noncanonical_reconstruction_policy_identity
    error = assert_raises(ArgumentError) do
      snapshot::ExtractionScope.new(
        mode: 'selection',
        root_source_uuids: [INSTANCE_ID].freeze,
        context_occurrence_uuid_path: [INSTANCE_ID].freeze,
        root_definition_uuid: DEFINITION_ID,
        extraction_policy_id: 'fixture-extraction/1.0.0',
        reconstruction_policy_id: 'wrong-policy/9.9.9'
      )
    end

    assert_match(/bom-semantic-reconstruction\/1\.0\.0/, error.message)
  end

  def test_document_rejects_duplicate_primitive_keys
    primitive = polygon
    error = assert_raises(ArgumentError) do
      document(primitives: [primitive, primitive].freeze)
    end

    assert_match(/duplicate primitive key/, error.message)
  end

  def test_loop_requires_one_source_uuid_for_each_edge_segment
    error = assert_raises(ArgumentError) do
      loop_record(edge_source_uuids: EDGE_IDS.first(2).freeze)
    end

    assert_match(/one source UUID per edge segment/, error.message)
  end

  def test_document_rejects_dangling_primitive_adjacency_references
    dangling_loop = loop_record(
      adjacent_primitive_keys: [[DEFINITION_ID, SECOND_FACE_ID].freeze].freeze
    )
    primitive = polygon(loops: [dangling_loop].freeze)

    error = assert_raises(ArgumentError) do
      document(primitives: [primitive].freeze)
    end

    assert_match(/unresolved primitive adjacency/, error.message)
  end

  def test_definition_local_primitive_keys_require_exact_owner_prefix_and_face_suffix
    wrong_prefix = [INSTANCE_ID, FACE_ID].freeze
    too_long = [DEFINITION_ID, INSTANCE_ID, FACE_ID].freeze

    [wrong_prefix, too_long].each do |key|
      error = assert_raises(ArgumentError) do
        snapshot::PolygonFragment.new(
          key: key,
          definition_uuid: DEFINITION_ID,
          source_uuid: FACE_ID,
          loops: [loop_record].freeze,
          front_material_uuid: nil,
          back_material_uuid: nil,
          normal: [0.0, 0.0, 1.0].freeze,
          area_m2: 1.0,
          construction_hints: [].freeze
        )
      end

      assert_match(/definition-local primitive key/, error.message)
    end

    error = assert_raises(ArgumentError) do
      snapshot::Definition.new(
        source_uuid: DEFINITION_ID,
        kind: 'component',
        primitive_keys: [wrong_prefix].freeze
      )
    end
    assert_match(/definition-local primitive key/, error.message)
  end

  def test_occurrence_fragment_key_composes_occurrence_path_with_shared_definition_local_key
    primitive = polygon(key: [DEFINITION_ID, FACE_ID].freeze)
    first = snapshot::Occurrence.new(
      uuid_path: [INSTANCE_ID].freeze,
      definition_uuid: DEFINITION_ID,
      transform: identity_transform
    )
    second_id = '60000000-0000-4000-8000-000000000006'
    second = snapshot::Occurrence.new(
      uuid_path: [second_id].freeze,
      definition_uuid: DEFINITION_ID,
      transform: identity_transform
    )

    assert_equal [INSTANCE_ID, DEFINITION_ID, FACE_ID],
                 snapshot.occurrence_fragment_key(occurrence: first, primitive: primitive)
    assert_equal [second_id, DEFINITION_ID, FACE_ID],
                 snapshot.occurrence_fragment_key(occurrence: second, primitive: primitive)

    unresolved = snapshot::Occurrence.new(
      uuid_path: [INSTANCE_ID].freeze,
      definition_uuid: second_id,
      transform: identity_transform
    )
    assert_raises(ArgumentError) do
      snapshot.occurrence_fragment_key(occurrence: unresolved, primitive: primitive)
    end
  end

  def test_document_rejects_unresolved_definition_ownership
    missing_definition_id = '60000000-0000-4000-8000-000000000006'
    missing_definition = snapshot::PolygonFragment.new(
      key: [missing_definition_id, FACE_ID].freeze,
      definition_uuid: missing_definition_id,
      source_uuid: FACE_ID,
      loops: [loop_record].freeze,
      front_material_uuid: nil,
      back_material_uuid: nil,
      normal: [0.0, 0.0, 1.0].freeze,
      area_m2: 1.0,
      construction_hints: [].freeze
    )

    error = assert_raises(ArgumentError) do
      declared_definition = snapshot::Definition.new(
        source_uuid: DEFINITION_ID,
        kind: 'component',
        primitive_keys: [].freeze
      )
      root_occurrence = snapshot::Occurrence.new(
        uuid_path: [INSTANCE_ID].freeze,
        definition_uuid: DEFINITION_ID,
        transform: identity_transform
      )
      snapshot::Document.new(
        model_id: MODEL_ID,
        scope: scope_record,
        model_context: model_context_record,
        occurrences: [root_occurrence].freeze,
        definitions: [declared_definition].freeze,
        primitives: [missing_definition].freeze,
        materials: [].freeze,
        evidence: [].freeze,
        foreign_source_provenance: [].freeze,
        diagnostics: [].freeze
      )
    end

    assert_match(/unresolved definition ownership/, error.message)
  end

  def test_document_rejects_primitive_not_claimed_by_its_definition
    primitive = polygon
    definition = snapshot::Definition.new(
      source_uuid: DEFINITION_ID,
      kind: 'component',
      primitive_keys: [].freeze
    )
    occurrence = snapshot::Occurrence.new(
      uuid_path: [INSTANCE_ID].freeze,
      definition_uuid: DEFINITION_ID,
      transform: identity_transform
    )

    error = assert_raises(ArgumentError) do
      snapshot::Document.new(
        model_id: MODEL_ID,
        scope: scope_record,
        model_context: model_context_record,
        occurrences: [occurrence].freeze,
        definitions: [definition].freeze,
        primitives: [primitive].freeze,
        materials: [].freeze,
        evidence: [].freeze,
        foreign_source_provenance: [].freeze,
        diagnostics: [].freeze
      )
    end

    assert_match(/unresolved definition ownership/, error.message)
  end

  def test_records_are_deeply_immutable_and_polygon_loops_are_authoritative
    result = document
    primitive = result.primitives.first

    assert result.frozen?
    assert result.occurrences.frozen?
    assert result.definitions.first.frozen?
    assert primitive.frozen?
    assert primitive.loops.first.vertices.frozen?
    assert_equal EDGE_IDS, primitive.loops.first.edge_source_uuids
    assert_empty primitive.loops.first.adjacent_primitive_keys
    refute_respond_to primitive, :triangles
    refute_respond_to result, :to_h
    refute_respond_to snapshot, :serialize
  end

  def test_all_neutral_evidence_record_types_remain_value_objects
    material = snapshot::Material.new(
      source_uuid: MATERIAL_ID,
      name: 'Concrete',
      rgba: [120, 121, 122, 255].freeze,
      texture: nil
    )
    hint = snapshot::ConstructionHint.new(
      target_key: [INSTANCE_ID, FACE_ID].freeze,
      source_uuid: FACE_ID,
      dictionary: 'BOMEngine.Physical',
      attribute_key: 'assembly',
      value: { 'system' => 'masonry' }
    )
    label = snapshot::LabelEvidence.new(
      target_key: [INSTANCE_ID].freeze,
      label: 'Pintu Utama',
      source: 'attached_text',
      role: 'door',
      classification_policy: 'label_first',
      aliases: ['Pintu Utama'].freeze,
      explicit: true,
      annotation_source_uuid: ANNOTATION_ID,
      target_occurrence_uuid_path: [INSTANCE_ID].freeze,
      target_kind: 'occurrence'
    )
    exclusion = snapshot::ExclusionEvidence.new(
      target_key: [INSTANCE_ID, FACE_ID].freeze,
      target_kind: 'primitive',
      source_uuid: FACE_ID,
      eligible: false,
      excluded: true,
      reasons: ['hidden'].freeze,
      rule_ids: ['visibility.entity_hidden'].freeze
    )

    [material, hint, label, exclusion].each { |record| assert record.frozen? }
    assert label.explicit
    assert_equal ['hidden'], exclusion.reasons
  end

  def test_attached_text_requires_complete_annotation_provenance
    error = assert_raises(ArgumentError) do
      snapshot::LabelEvidence.new(
        target_key: [INSTANCE_ID].freeze,
        label: 'Pintu Utama',
        source: 'attached_text',
        role: nil,
        classification_policy: 'label_first',
        aliases: ['Pintu Utama'].freeze,
        explicit: true,
        target_kind: 'occurrence'
      )
    end

    assert_match(/attached_text.*annotation.*occurrence path/, error.message)
  end

  def test_eligibility_evidence_rejects_missing_or_contradictory_exclusion_details
    missing = assert_raises(ArgumentError) do
      snapshot::ExclusionEvidence.new(
        target_key: [DEFINITION_ID, SECOND_FACE_ID].freeze,
        target_kind: 'primitive',
        source_uuid: SECOND_FACE_ID,
        eligible: false,
        excluded: true,
        reasons: [].freeze,
        rule_ids: [].freeze
      )
    end
    assert_match(/excluded evidence requires/, missing.message)

    contradictory = assert_raises(ArgumentError) do
      snapshot::ExclusionEvidence.new(
        target_key: [DEFINITION_ID, FACE_ID].freeze,
        target_kind: 'primitive',
        source_uuid: FACE_ID,
        eligible: true,
        excluded: false,
        reasons: ['hidden'].freeze,
        rule_ids: ['visibility.entity_hidden'].freeze
      )
    end
    assert_match(/eligible evidence cannot carry/, contradictory.message)
  end

  def test_visibility_summary_remains_unknown_when_observations_are_incomplete
    unknown = snapshot::VisibilityEvidence.new(
      target_key: [INSTANCE_ID].freeze,
      target_kind: 'occurrence',
      source_uuid: INSTANCE_ID,
      hidden: nil,
      visible: nil,
      tag_visible: nil
    )
    partial = snapshot::VisibilityEvidence.new(
      target_key: [INSTANCE_ID].freeze,
      target_kind: 'occurrence',
      source_uuid: INSTANCE_ID,
      hidden: false,
      visible: true,
      tag_visible: nil
    )

    assert_nil unknown.observed_visible
    assert_nil partial.observed_visible
  end

  def test_document_rejects_dangling_resolvable_evidence_targets
    dangling = [
      snapshot::ConstructionHint.new(
        target_key: [DEFINITION_ID, SECOND_FACE_ID].freeze,
        source_uuid: SECOND_FACE_ID,
        dictionary: 'BOMEngine.Physical',
        attribute_key: 'assembly',
        value: 'masonry'
      ),
      snapshot::LabelEvidence.new(
        target_key: [SECOND_FACE_ID].freeze,
        label: 'Dangling',
        source: 'instance_name',
        role: nil,
        classification_policy: 'label_first',
        aliases: ['Dangling'].freeze,
        explicit: true,
        target_kind: 'occurrence'
      ),
      snapshot::VisibilityEvidence.new(
        target_key: [SECOND_FACE_ID].freeze,
        target_kind: 'occurrence',
        source_uuid: SECOND_FACE_ID,
        hidden: false,
        visible: true,
        tag_visible: true
      ),
      snapshot::ExclusionEvidence.new(
        target_key: [SECOND_FACE_ID].freeze,
        target_kind: 'occurrence',
        source_uuid: SECOND_FACE_ID,
        eligible: true,
        excluded: false,
        reasons: [].freeze,
        rule_ids: [].freeze
      )
    ]

    dangling.each do |evidence|
      error = assert_raises(ArgumentError) { document(evidence: [evidence].freeze) }
      assert_match(/unresolved .* evidence target/, error.message)
    end
  end

  def test_document_rejects_construction_source_that_does_not_own_the_target_primitive
    mismatch = snapshot::ConstructionHint.new(
      target_key: [DEFINITION_ID, FACE_ID].freeze,
      source_uuid: SECOND_FACE_ID,
      dictionary: 'BOMEngine.Physical',
      attribute_key: 'assembly',
      value: 'masonry'
    )

    error = assert_raises(ArgumentError) { document(evidence: [mismatch].freeze) }
    assert_match(/construction.*target\/source correspondence/, error.message)
  end

  def test_model_context_and_foreign_rebase_provenance_are_typed_and_immutable
    provenance = snapshot::ForeignSourceProvenance.new(
      source_uuid: ANNOTATION_ID,
      origin_model_id: MATERIAL_ID,
      destination_source_uuid: SECOND_FACE_ID
    )
    result = document(foreign_source_provenance: [provenance].freeze)

    assert_equal [0.0, 1.0], result.model_context.true_north_xy
    assert_equal identity_transform, result.model_context.context_transform
    assert_equal ANNOTATION_ID, result.foreign_source_provenance.fetch(0).source_uuid
    assert_equal MATERIAL_ID, result.foreign_source_provenance.fetch(0).origin_model_id
    assert_equal SECOND_FACE_ID,
                 result.foreign_source_provenance.fetch(0).destination_source_uuid
    assert result.model_context.frozen?
    assert result.model_context.true_north_xy.frozen?
    assert result.foreign_source_provenance.fetch(0).frozen?
  end

  def test_public_json_serialization_cannot_accept_the_private_snapshot
    error = assert_raises(TypeError) { JSON.generate(document) }

    assert_match(/private neutral snapshot/, error.message)
  end

  def test_supported_nested_values_are_defensively_copied_and_deeply_frozen
    filename = 'surface.png'.dup
    tag = 'masonry'.dup
    tags = [tag]
    metadata = { tags: tags }
    texture = { filename: filename, metadata: metadata }
    note = 'surveyed'.dup
    hint_value = { note: note, samples: [['A'.dup]] }

    material = snapshot::Material.new(
      source_uuid: MATERIAL_ID,
      name: 'Concrete',
      rgba: [120, 121, 122, 255].freeze,
      texture: texture
    )
    hint = snapshot::ConstructionHint.new(
      target_key: [INSTANCE_ID, FACE_ID].freeze,
      source_uuid: FACE_ID,
      dictionary: 'BOMEngine.Physical',
      attribute_key: 'survey',
      value: hint_value,
    )

    filename.replace('changed.png')
    tag.replace('changed')
    tags << 'late'
    metadata[:added] = true
    texture[:filename] = 'replaced.png'
    note.replace('changed')
    hint_value[:samples].first << 'B'
    hint_value[:added] = true

    assert_equal 'surface.png', material.texture[:filename]
    assert_equal ['masonry'], material.texture.dig(:metadata, :tags)
    assert_equal({ note: 'surveyed', samples: [['A']] }, hint.value)
    assert material.texture.frozen?
    assert material.texture[:filename].frozen?
    assert material.texture.dig(:metadata, :tags).frozen?
    assert material.texture.dig(:metadata, :tags).first.frozen?
    assert hint.value.frozen?
    assert hint.value[:samples].first.frozen?
    assert hint.value[:samples].first.first.frozen?
  end

  def test_snapshot_values_reject_unsupported_arbitrary_objects
    error = assert_raises(ArgumentError) do
      snapshot::ConstructionHint.new(
        target_key: [INSTANCE_ID, FACE_ID].freeze,
        source_uuid: FACE_ID,
        dictionary: 'BOMEngine.Physical',
        attribute_key: 'unsupported',
        value: Object.new,
      )
    end

    assert_match(/unsupported snapshot value/, error.message)
  end

  private

  def snapshot
    BOMEngine::SemanticV2::Snapshot
  end

  def document(primitives: [polygon].freeze, evidence: [].freeze,
               foreign_source_provenance: [].freeze)
    definition = snapshot::Definition.new(
      source_uuid: DEFINITION_ID,
      kind: 'component',
      primitive_keys: primitives.map(&:key).freeze
    )
    occurrence = snapshot::Occurrence.new(
      uuid_path: [INSTANCE_ID].freeze,
      definition_uuid: DEFINITION_ID,
      transform: identity_transform
    )
    snapshot::Document.new(
      model_id: MODEL_ID,
      scope: scope_record,
      model_context: model_context_record,
      occurrences: [occurrence].freeze,
      definitions: [definition].freeze,
      primitives: primitives,
      materials: [].freeze,
      evidence: evidence,
      foreign_source_provenance: foreign_source_provenance,
      diagnostics: [].freeze
    )
  end

  def polygon(key: [DEFINITION_ID, FACE_ID].freeze, loops: [loop_record].freeze)
    snapshot::PolygonFragment.new(
      key: key,
      definition_uuid: DEFINITION_ID,
      source_uuid: FACE_ID,
      loops: loops,
      front_material_uuid: nil,
      back_material_uuid: nil,
      normal: [0.0, 0.0, 1.0].freeze,
      area_m2: 1.0,
      construction_hints: [].freeze
    )
  end

  def loop_record(edge_source_uuids: EDGE_IDS, adjacent_primitive_keys: [].freeze)
    snapshot::Loop.new(
      kind: 'outer',
      vertices: [
        [0.0, 0.0, 0.0].freeze,
        [1.0, 0.0, 0.0].freeze,
        [1.0, 1.0, 0.0].freeze
      ].freeze,
      edge_source_uuids: edge_source_uuids,
      adjacent_primitive_keys: adjacent_primitive_keys
    )
  end

  def identity_transform
    [
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ].freeze
  end

  def scope_record
    snapshot::ExtractionScope.new(
      mode: 'selection',
      root_source_uuids: [INSTANCE_ID].freeze,
      context_occurrence_uuid_path: [INSTANCE_ID].freeze,
      root_definition_uuid: DEFINITION_ID,
      extraction_policy_id: 'fixture-extraction/1.0.0'
    )
  end

  def model_context_record
    snapshot::ModelContext.new(
      true_north_xy: [0.0, 1.0].freeze,
      context_transform: identity_transform
    )
  end
end
