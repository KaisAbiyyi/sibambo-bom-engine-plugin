# frozen_string_literal: true

module CleanAnalysisCompletenessFixture
  UUIDS = (1..900).map { |index| format('10000000-0000-4000-8000-%012x', index) }.freeze

  def uuid(index)
    UUIDS.fetch(index)
  end

  def identity_transform
    [
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ].freeze
  end

  def occurrence(path:, definition_uuid:, translation: [0, 0, 0], transform: nil,
                 material_uuid: nil)
    transform ||= identity_transform.dup.tap do |matrix|
      matrix[12] = translation[0].to_f
      matrix[13] = translation[1].to_f
      matrix[14] = translation[2].to_f
    end
    snapshot::Occurrence.new(
      uuid_path: path.freeze,
      definition_uuid: definition_uuid,
      transform: transform.map(&:to_f).freeze,
      material_uuid: material_uuid
    )
  end

  def definition(source_uuid, primitives)
    snapshot::Definition.new(
      source_uuid: source_uuid,
      kind: 'component',
      primitive_keys: primitives.map(&:key).freeze
    )
  end

  def polygon(definition_uuid:, source_uuid:, points:, normal:, material_uuid: nil)
    loop = snapshot::Loop.new(
      kind: 'outer',
      vertices: points.map { |point| point.map(&:to_f).freeze }.freeze,
      edge_source_uuids: points.each_index.map { |index| uuid(700 + index) }.freeze,
      adjacent_primitive_keys: [].freeze
    )
    snapshot::PolygonFragment.new(
      key: [definition_uuid, source_uuid].freeze,
      definition_uuid: definition_uuid,
      source_uuid: source_uuid,
      loops: [loop].freeze,
      front_material_uuid: material_uuid,
      back_material_uuid: nil,
      normal: normal.map(&:to_f).freeze,
      area_m2: polygon_area(points),
      construction_hints: [].freeze
    )
  end

  def material(index)
    snapshot::Material.new(
      source_uuid: uuid(500 + index),
      name: "Material #{index}",
      rgba: [index % 256, (index * 3) % 256, (index * 7) % 256, 255].freeze,
      texture: nil
    )
  end

  def label(path, name, role = nil)
    snapshot::LabelEvidence.new(
      target_key: path.freeze,
      target_kind: 'occurrence',
      label: name,
      source: 'instance_name',
      role: role,
      classification_policy: 'label_first',
      aliases: [name].freeze,
      explicit: true,
      primary: true
    )
  end

  def document(root_primitives:, definitions:, primitives:, occurrences:, materials:, evidence:)
    root_definition = snapshot::Definition.new(
      source_uuid: uuid(1),
      kind: 'model',
      primitive_keys: root_primitives.map(&:key).freeze
    )
    snapshot::Document.new(
      model_id: uuid(1),
      scope: snapshot::ExtractionScope.new(
        mode: 'selection',
        root_source_uuids: [uuid(2)].freeze,
        context_occurrence_uuid_path: [].freeze,
        root_definition_uuid: uuid(1),
        extraction_policy_id: 'clean-completeness-test/1.0.0'
      ),
      model_context: snapshot::ModelContext.new(
        true_north_xy: [0.0, 1.0].freeze,
        context_transform: identity_transform
      ),
      occurrences: ([occurrence(path: [], definition_uuid: uuid(1))] + occurrences).freeze,
      definitions: ([root_definition] + definitions).freeze,
      primitives: (root_primitives + primitives).freeze,
      materials: materials.freeze,
      evidence: evidence.freeze,
      foreign_source_provenance: [].freeze,
      diagnostics: [].freeze
    )
  end

  def polygon_area(points)
    sums = [0.0, 0.0, 0.0]
    points.each_with_index do |point, index|
      following = points[(index + 1) % points.length]
      sums[0] += point[1] * following[2] - point[2] * following[1]
      sums[1] += point[2] * following[0] - point[0] * following[2]
      sums[2] += point[0] * following[1] - point[1] * following[0]
    end
    Math.sqrt(sums.inject(0.0) { |sum, value| sum + value**2 }) / 2.0
  end

  def snapshot
    SibamboHistory::V20260812_01::SemanticV2::Snapshot
  end
end
