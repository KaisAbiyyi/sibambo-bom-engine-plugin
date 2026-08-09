# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../semantic_v2'
require_relative '../clean_analysis' if File.exist?(File.expand_path('../clean_analysis.rb', __dir__))

class CleanAnalysisCompilerTest < Minitest::Test
  UUIDS = (1..200).map { |index| format('00000000-0000-4000-8000-%012x', index) }.freeze

  def test_merges_adjacent_coplanar_wall_fragments_without_triangle_data
    first_key = [uuid(1), uuid(10)].freeze
    second_key = [uuid(1), uuid(11)].freeze
    first = polygon(
      definition_uuid: uuid(1),
      source_uuid: uuid(10),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0],
      adjacent_keys: [second_key]
    )
    second = polygon(
      definition_uuid: uuid(1),
      source_uuid: uuid(11),
      points: [[1, 0, 0], [2, 0, 0], [2, 0, 1], [1, 0, 1]],
      normal: [0, -1, 0],
      adjacent_keys: [first_key]
    )
    wall_label = label(
      target_key: [].freeze,
      target_kind: 'occurrence',
      label: 'Dinding Utama',
      role: 'wall'
    )

    result = compile(document(root_primitives: [first, second], evidence: [wall_label]))

    refute_nil result
    assert_equal 'bom_engine_clean_v1', result.dig('format', 'identifier')
    assert_equal 1, result.fetch('surfaces').length
    surface = result.fetch('surfaces').first
    assert_equal 'wall', surface.fetch('type')
    assert_equal 4, surface.fetch('outer').length
    assert_in_delta 2.0, surface.fetch('area_m2'), 1.0e-9
    assert_equal 2, surface.fetch('source_count')
    assert_equal 0, result.dig('diagnostics', 'counts', 'raw_triangle_indices_serialized')
    refute deep_key?(result, 'triangles')
    refute deep_key?(result, 'faces')
  end

  def test_classifies_unlabelled_horizontal_surfaces_from_normals
    floor = polygon(
      definition_uuid: uuid(1),
      source_uuid: uuid(12),
      points: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]],
      normal: [0, 0, 1]
    )
    ceiling = polygon(
      definition_uuid: uuid(1),
      source_uuid: uuid(13),
      points: [[0, 0, 3], [0, 2, 3], [2, 2, 3], [2, 0, 3]],
      normal: [0, 0, -1]
    )

    result = compile(document(root_primitives: [floor, ceiling]))

    refute_nil result
    assert_equal %w[ceiling floor], result.fetch('surfaces').map { |surface| surface.fetch('type') }.sort
    assert_equal %w[geometry_hint geometry_hint], result.fetch('surfaces').map { |surface| surface.dig('classification', 'method') }.sort
  end

  def test_excludes_sree_entourage_without_serializing_its_geometry
    floor = polygon(
      definition_uuid: uuid(1),
      source_uuid: uuid(14),
      points: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]],
      normal: [0, 0, 1]
    )
    sree_face = polygon(
      definition_uuid: uuid(2),
      source_uuid: uuid(15),
      points: circle_points(64),
      normal: [0, 0, 1],
      area_m2: 3.0
    )
    sree_occurrence = occurrence(path: [uuid(30)], definition_uuid: uuid(2))
    sree_label = label(
      target_key: [uuid(30)].freeze,
      target_kind: 'occurrence',
      label: 'Sree',
      role: nil
    )

    result = compile(
      document(
        root_primitives: [floor],
        extra_definitions: [definition(uuid(2), 'component', [sree_face])],
        extra_primitives: [sree_face],
        extra_occurrences: [sree_occurrence],
        evidence: [sree_label]
      )
    )

    refute_nil result
    assert_equal [], result.fetch('fallback_geometry')
    assert_equal 1, result.fetch('excluded_objects').length
    assert_equal 'Sree', result.dig('excluded_objects', 0, 'name')
    assert_equal 'entourage', result.dig('excluded_objects', 0, 'category')
    assert_equal 'analysis_irrelevant', result.dig('excluded_objects', 0, 'reason')
    assert_equal 4, result.dig('diagnostics', 'counts', 'raw_vertices_serialized')
    assert_equal 1, result.dig('diagnostics', 'counts', 'excluded_object_count')
  end

  def test_keeps_explicit_openings_and_unknown_objects_as_compact_components
    door_face = polygon(
      definition_uuid: uuid(3),
      source_uuid: uuid(16),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 2], [0, 0, 2]],
      normal: [0, -1, 0],
      area_m2: 2.0
    )
    unknown_face = polygon(
      definition_uuid: uuid(4),
      source_uuid: uuid(17),
      points: circle_points(32),
      normal: [0, 0, 1],
      area_m2: 1.0
    )
    door_path = [uuid(31)].freeze
    unknown_path = [uuid(32)].freeze

    result = compile(
      document(
        extra_definitions: [
          definition(uuid(3), 'component', [door_face]),
          definition(uuid(4), 'component', [unknown_face])
        ],
        extra_primitives: [door_face, unknown_face],
        extra_occurrences: [
          occurrence(path: door_path, definition_uuid: uuid(3), translation: [1, 2, 0]),
          occurrence(path: unknown_path, definition_uuid: uuid(4), translation: [5, 6, 0])
        ],
        evidence: [
          label(target_key: door_path, target_kind: 'occurrence', label: 'Pintu Utama', role: 'door'),
          label(target_key: unknown_path, target_kind: 'occurrence', label: 'Custom Module', role: nil)
        ]
      )
    )

    refute_nil result
    assert_equal %w[door unknown], result.fetch('components').map { |component| component.fetch('category') }.sort
    assert_equal %w[omitted omitted], result.fetch('components').map { |component| component.dig('geometry', 'status') }.sort
    assert_equal %w[clean_analysis_profile clean_analysis_profile], result.fetch('components').map { |component| component.dig('geometry', 'reason') }.sort
    assert_equal [1, 1], result.fetch('components').map { |component| component.dig('geometry', 'source_count') }.sort
    assert_equal [], result.fetch('surfaces')
    assert_equal [], result.fetch('fallback_geometry')
  end

  def test_contextual_geometry_hints_do_not_promote_slab_edges_and_secondary_horizontal_faces
    full_wall = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(20),
      points: [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]], normal: [0, -1, 0]
    )
    thin_slab_edge = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(21),
      points: [[0, 1, 2.8], [4, 1, 2.8], [4, 1, 3.0], [0, 1, 3.0]], normal: [0, -1, 0]
    )
    sparse_end_cap = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(22),
      points: [[0, 0, 0], [0, 4, 0], [0, 4, 0.2], [0, 0.2, 0.2], [0, 0.2, 3], [0, 0, 3]], normal: [1, 0, 0]
    )
    primary_floor = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(23),
      points: [[0, 0, 0.2], [4, 0, 0.2], [4, 4, 0.2], [0, 4, 0.2]], normal: [0, 0, 1]
    )
    upper_slab_top = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(24),
      points: [[0, 0, 3], [4, 0, 3], [4, 1, 3], [0, 1, 3]], normal: [0, 0, 1]
    )
    floor_underside = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(25),
      points: [[0, 0, 0], [0, 4, 0], [4, 4, 0], [4, 0, 0]], normal: [0, 0, -1]
    )
    primary_ceiling = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(26),
      points: [[0, 0, 2.8], [0, 1, 2.8], [4, 1, 2.8], [4, 0, 2.8]], normal: [0, 0, -1]
    )

    untyped_label = label(
      target_key: [uuid(1), uuid(21)].freeze,
      target_kind: 'primitive',
      label: 'Partition A',
      role: nil
    )
    result = compile(document(
      root_primitives: [
        full_wall, thin_slab_edge, sparse_end_cap, primary_floor,
        upper_slab_top, floor_underside, primary_ceiling
      ],
      evidence: [untyped_label]
    ))

    counts = result.fetch('surfaces').group_by { |surface| surface.fetch('type') }
                   .transform_values(&:length)
    assert_equal({
      'wall' => 1,
      'floor' => 1,
      'ceiling' => 1,
      'other_architectural_surface' => 4
    }, counts)
    reasons = result.fetch('surfaces').map { |surface| surface.dig('classification', 'reason') }
    assert_includes reasons, 'thin_or_fragmentary_vertical_region'
    assert_includes reasons, 'secondary_upward_region'
    assert_includes reasons, 'secondary_downward_region'
  end

  def test_merges_coplanar_fragments_when_shared_edge_segmentation_differs
    first_key = [uuid(1), uuid(27)].freeze
    second_key = [uuid(1), uuid(28)].freeze
    first = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(27),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 2], [0, 0, 2]],
      normal: [0, -1, 0], adjacent_keys: [second_key]
    )
    second = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(28),
      points: [[1, 0, 0], [2, 0, 0], [2, 0, 2], [1, 0, 2], [1, 0, 1]],
      normal: [0, -1, 0], adjacent_keys: [first_key]
    )
    wall_label = label(target_key: [].freeze, target_kind: 'occurrence', label: 'Dinding', role: 'wall')

    result = compile(document(root_primitives: [first, second], evidence: [wall_label]))

    assert_equal 1, result.fetch('surfaces').length
    assert_equal 4, result.dig('surfaces', 0, 'outer').length
    assert_in_delta 4.0, result.dig('surfaces', 0, 'area_m2'), 1.0e-9
    assert_equal 2, result.dig('surfaces', 0, 'source_count')
  end

  def test_merges_unambiguous_coplanar_t_edge_contact
    first_key = [uuid(1), uuid(29)].freeze
    second_key = [uuid(1), uuid(30)].freeze
    first = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(29),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 2], [0, 0, 2]],
      normal: [0, -1, 0], adjacent_keys: [second_key]
    )
    second = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(30),
      points: [[1, 0, 0.5], [2, 0, 0.5], [2, 0, 1.5], [1, 0, 1.5]],
      normal: [0, -1, 0], adjacent_keys: [first_key]
    )
    wall_label = label(target_key: [].freeze, target_kind: 'occurrence', label: 'Dinding', role: 'wall')

    result = compile(document(root_primitives: [first, second], evidence: [wall_label]))

    assert_equal 1, result.fetch('surfaces').length
    assert_equal 8, result.dig('surfaces', 0, 'outer').length
    assert_in_delta 3.0, result.dig('surfaces', 0, 'area_m2'), 1.0e-9
  end

  def test_invalid_architectural_fragment_becomes_explicit_unresolved_fallback
    collinear = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(35),
      points: [[0, 0, 0], [1, 0, 0], [2, 0, 0]],
      normal: [0, 1, 0], area_m2: 0.0
    )

    result = compile(document(root_primitives: [collinear]))

    assert_equal [], result.fetch('surfaces')
    assert_equal 1, result.fetch('fallback_geometry').length
    assert_equal 'unresolved', result.dig('fallback_geometry', 0, 'status')
    assert_equal 'invalid_surface', result.dig('fallback_geometry', 0, 'reason')
    assert_equal 1, result.dig('fallback_geometry', 0, 'source_count')
    assert_equal 1, result.dig('diagnostics', 'counts', 'unresolved_fragment_count')
  end

  def test_definition_face_labels_are_scoped_to_each_repeated_occurrence
    shared_face = polygon(
      definition_uuid: uuid(5),
      source_uuid: uuid(18),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    first_path = [uuid(33)].freeze
    second_path = [uuid(34)].freeze
    target_key = [uuid(5), uuid(18)].freeze
    first_label = attached_face_label(
      target_key: target_key,
      occurrence_path: first_path,
      annotation_uuid: uuid(70),
      label: 'Dinding Occurrence A',
      role: 'wall'
    )
    second_label = attached_face_label(
      target_key: target_key,
      occurrence_path: second_path,
      annotation_uuid: uuid(71),
      label: 'Atap Occurrence B',
      role: 'roof'
    )

    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [shared_face])],
        extra_primitives: [shared_face],
        extra_occurrences: [
          occurrence(path: first_path, definition_uuid: uuid(5)),
          occurrence(path: second_path, definition_uuid: uuid(5), translation: [2, 0, 0])
        ],
        evidence: [first_label, second_label]
      )
    )

    assert_equal %w[roof wall], result.fetch('surfaces').map { |surface| surface.fetch('type') }.sort
    assert_equal ['Atap Occurrence B', 'Dinding Occurrence A'], result.fetch('surfaces').map { |surface| surface.dig('classification', 'label') }.sort
  end

  private

  def compile(snapshot_document)
    return nil unless defined?(BOMEngine::CleanAnalysis)

    BOMEngine::CleanAnalysis.compile(snapshot_document)
  end

  def snapshot
    BOMEngine::SemanticV2::Snapshot
  end

  def uuid(index)
    UUIDS.fetch(index)
  end

  def document(root_primitives: [], extra_definitions: [], extra_primitives: [],
               extra_occurrences: [], evidence: [])
    root_definition = definition(uuid(1), 'model', root_primitives)
    root_occurrence = occurrence(path: [].freeze, definition_uuid: uuid(1))
    snapshot::Document.new(
      model_id: uuid(1),
      scope: snapshot::ExtractionScope.new(
        mode: 'selection',
        root_source_uuids: [uuid(90)].freeze,
        context_occurrence_uuid_path: [].freeze,
        root_definition_uuid: uuid(1),
        extraction_policy_id: 'clean-analysis-test/1.0.0'
      ),
      model_context: snapshot::ModelContext.new(
        true_north_xy: [0.0, 1.0].freeze,
        context_transform: identity_transform
      ),
      occurrences: ([root_occurrence] + extra_occurrences).freeze,
      definitions: ([root_definition] + extra_definitions).freeze,
      primitives: (root_primitives + extra_primitives).freeze,
      materials: [].freeze,
      evidence: evidence.freeze,
      foreign_source_provenance: [].freeze,
      diagnostics: [].freeze
    )
  end

  def definition(source_uuid, kind, primitives)
    snapshot::Definition.new(
      source_uuid: source_uuid,
      kind: kind,
      primitive_keys: primitives.map(&:key).freeze
    )
  end

  def occurrence(path:, definition_uuid:, translation: [0, 0, 0])
    transform = identity_transform.dup
    transform[12] = translation[0].to_f
    transform[13] = translation[1].to_f
    transform[14] = translation[2].to_f
    snapshot::Occurrence.new(
      uuid_path: path.freeze,
      definition_uuid: definition_uuid,
      transform: transform.freeze
    )
  end

  def polygon(definition_uuid:, source_uuid:, points:, normal:, adjacent_keys: [], area_m2: nil)
    outer = snapshot::Loop.new(
      kind: 'outer',
      vertices: points.map { |point| point.map(&:to_f).freeze }.freeze,
      edge_source_uuids: points.each_index.map { |index| uuid(100 + ((source_uuid[-2, 2].to_i(16) + index) % 90)) }.freeze,
      adjacent_primitive_keys: adjacent_keys.freeze
    )
    snapshot::PolygonFragment.new(
      key: [definition_uuid, source_uuid].freeze,
      definition_uuid: definition_uuid,
      source_uuid: source_uuid,
      loops: [outer].freeze,
      front_material_uuid: nil,
      back_material_uuid: nil,
      normal: normal.map(&:to_f).freeze,
      area_m2: area_m2 || polygon_area(points),
      construction_hints: [].freeze
    )
  end

  def label(target_key:, target_kind:, label:, role:)
    snapshot::LabelEvidence.new(
      target_key: target_key,
      target_kind: target_kind,
      label: label,
      source: 'instance_name',
      role: role,
      classification_policy: 'label_first',
      aliases: [label].freeze,
      explicit: true,
      primary: true
    )
  end

  def attached_face_label(target_key:, occurrence_path:, annotation_uuid:, label:, role:)
    snapshot::LabelEvidence.new(
      target_key: target_key,
      target_kind: 'primitive',
      label: label,
      source: 'attached_text',
      role: role,
      classification_policy: 'label_first',
      aliases: [label].freeze,
      explicit: true,
      annotation_source_uuid: annotation_uuid,
      target_occurrence_uuid_path: occurrence_path,
      primary: true
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

  def polygon_area(points)
    return 1.0 if points.length > 8

    vectors = points.each_with_index.map do |point, index|
      following = points[(index + 1) % points.length]
      [
        point[1] * following[2] - point[2] * following[1],
        point[2] * following[0] - point[0] * following[2],
        point[0] * following[1] - point[1] * following[0]
      ]
    end
    sums = vectors.transpose.map { |axis| axis.inject(0.0, :+) }
    Math.sqrt(sums.inject(0.0) { |total, value| total + value**2 }) / 2.0
  end

  def circle_points(count)
    count.times.map do |index|
      angle = 2.0 * Math::PI * index / count
      [Math.cos(angle), Math.sin(angle), 0.0]
    end
  end

  def deep_key?(value, key)
    case value
    when Hash
      value.key?(key) || value.values.any? { |child| deep_key?(child, key) }
    when Array
      value.any? { |child| deep_key?(child, key) }
    else
      false
    end
  end
end
