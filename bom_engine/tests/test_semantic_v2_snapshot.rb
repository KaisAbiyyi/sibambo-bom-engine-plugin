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

  def test_document_rejects_mutable_top_level_collections
    error = assert_raises(ArgumentError) do
      snapshot::Document.new(
        model_id: MODEL_ID,
        occurrences: [],
        definitions: [].freeze,
        primitives: [].freeze,
        materials: [].freeze,
        evidence: [].freeze,
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

  def test_document_rejects_duplicate_primitive_keys
    primitive = polygon
    error = assert_raises(ArgumentError) do
      document(primitives: [primitive, primitive].freeze)
    end

    assert_match(/duplicate primitive key/, error.message)
  end

  def test_document_rejects_unresolved_definition_ownership
    missing_definition = snapshot::PolygonFragment.new(
      key: [INSTANCE_ID, FACE_ID].freeze,
      definition_uuid: '60000000-0000-4000-8000-000000000006',
      source_uuid: FACE_ID,
      loops: [loop_record].freeze,
      front_material_uuid: nil,
      back_material_uuid: nil,
      normal: [0.0, 0.0, 1.0].freeze,
      area_m2: 1.0,
      construction_hints: [].freeze
    )

    error = assert_raises(ArgumentError) do
      document(primitives: [missing_definition].freeze)
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
        occurrences: [occurrence].freeze,
        definitions: [definition].freeze,
        primitives: [primitive].freeze,
        materials: [].freeze,
        evidence: [].freeze,
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
    assert_equal [FACE_ID], primitive.loops.first.adjacent_primitive_keys.first
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
      kind: 'surface_normal',
      value: [0.0, 0.0, 1.0].freeze,
      source: 'face_geometry'
    )
    label = snapshot::LabelEvidence.new(
      target_key: [INSTANCE_ID].freeze,
      label: 'Pintu Utama',
      source: 'attached_text',
      role: 'door',
      classification_policy: 'label_first',
      aliases: ['Pintu Utama'].freeze,
      explicit: true
    )
    exclusion = snapshot::ExclusionEvidence.new(
      target_key: [INSTANCE_ID, FACE_ID].freeze,
      eligible: false,
      excluded: true,
      reasons: ['hidden'].freeze
    )

    [material, hint, label, exclusion].each { |record| assert record.frozen? }
    assert label.explicit
    assert_equal ['hidden'], exclusion.reasons
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
      kind: 'survey',
      value: hint_value,
      source: 'fixture'
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
        kind: 'unsupported',
        value: Object.new,
        source: 'fixture'
      )
    end

    assert_match(/unsupported snapshot value/, error.message)
  end

  private

  def snapshot
    BOMEngine::SemanticV2::Snapshot
  end

  def document(primitives: [polygon].freeze)
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
      occurrences: [occurrence].freeze,
      definitions: [definition].freeze,
      primitives: primitives,
      materials: [].freeze,
      evidence: [].freeze,
      diagnostics: [].freeze
    )
  end

  def polygon
    snapshot::PolygonFragment.new(
      key: [INSTANCE_ID, FACE_ID].freeze,
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

  def loop_record
    snapshot::Loop.new(
      kind: 'outer',
      vertices: [
        [0.0, 0.0, 0.0].freeze,
        [1.0, 0.0, 0.0].freeze,
        [1.0, 1.0, 0.0].freeze
      ].freeze,
      edge_source_uuids: [].freeze,
      adjacent_primitive_keys: [[FACE_ID].freeze].freeze
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
end
