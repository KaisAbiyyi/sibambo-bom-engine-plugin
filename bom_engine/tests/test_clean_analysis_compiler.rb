# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../semantic_v2'
require_relative '../clean_analysis' if File.exist?(File.expand_path('../clean_analysis.rb', __dir__))

class CleanAnalysisCompilerTest < Minitest::Test
  UUIDS = (1..500).map { |index| format('00000000-0000-4000-8000-%012x', index) }.freeze

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

  def test_merges_three_coplanar_floor_splits_into_one_boundary
    first_key = [uuid(1), uuid(40)].freeze
    second_key = [uuid(1), uuid(41)].freeze
    third_key = [uuid(1), uuid(42)].freeze
    first = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(40),
      points: [[0, 0, 0], [1, 0, 0], [1, 2, 0], [0, 2, 0]],
      normal: [0, 0, 1], adjacent_keys: [second_key]
    )
    second = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(41),
      points: [[1, 0, 0], [2, 0, 0], [2, 2, 0], [1, 2, 0]],
      normal: [0, 0, 1], adjacent_keys: [first_key, third_key]
    )
    third = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(42),
      points: [[2, 0, 0], [3, 0, 0], [3, 2, 0], [2, 2, 0]],
      normal: [0, 0, 1], adjacent_keys: [second_key]
    )

    result = compile(document(root_primitives: [first, second, third]))

    assert_equal 1, result.fetch('surfaces').length
    surface = result.fetch('surfaces').first
    assert_equal 3, surface.fetch('source_count')
    assert_in_delta 6.0, surface.fetch('area_m2'), 1.0e-9
    assert_in_delta 6.0, result.dig('diagnostics', 'area_m2', 'source'), 1.0e-9
    assert_equal(
      [[0.0, 0.0, 0.0], [3.0, 0.0, 0.0], [3.0, 2.0, 0.0], [0.0, 2.0, 0.0]],
      surface.fetch('outer')
    )
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

  def test_preserves_one_floor_polygon_hole_without_emitting_a_second_surface
    outer = [[0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0]]
    hole = [[1, 1, 0], [2, 1, 0], [2, 2, 0], [1, 2, 0]]
    floor = polygon_with_hole(
      definition_uuid: uuid(1),
      source_uuid: uuid(43),
      outer: outer,
      hole: hole,
      normal: [0, 0, 1]
    )

    result = compile(document(root_primitives: [floor]))

    assert_equal 1, result.fetch('surfaces').length
    surface = result.fetch('surfaces').first
    assert_equal outer.map { |point| point.map(&:to_f) }, surface.fetch('outer')
    assert_equal [hole.map { |point| point.map(&:to_f) }], surface.fetch('holes')
    assert_in_delta 15.0, surface.fetch('area_m2'), 1.0e-9
    refute result.fetch('surfaces').any? { |candidate| candidate.fetch('outer') == surface.fetch('holes').first }
    assert_equal [], result.fetch('fallback_geometry')
    assert_equal 1, surface.fetch('source_count')
    assert_in_delta 15.0, result.dig('diagnostics', 'area_m2', 'source'), 1.0e-9
    assert_in_delta 15.0, result.dig('diagnostics', 'area_m2', 'resolved'), 1.0e-9
    assert_in_delta 0.0, result.dig('diagnostics', 'area_m2', 'unresolved'), 1.0e-9
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

  def test_keeps_single_use_openings_and_unknown_objects_as_renderable_definitions
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
    assert_empty result.fetch('components')
    assert_equal %w[door unknown], result.fetch('instances').map { |instance| instance.fetch('category') }.sort
    assert_equal 2, result.fetch('definitions').length
    assert_equal [1, 1], result.fetch('definitions').map { |item| item.dig('geometry', 'source_count') }.sort
    assert result.fetch('definitions').all? { |item| item.dig('geometry', 'surfaces').length == 1 }
    assert_equal [], result.fetch('surfaces')
    assert_equal [], result.fetch('fallback_geometry')
  end

  def test_serializes_repeated_component_definition_geometry_once_for_one_hundred_instances
    faces = 3.times.map do |index|
      polygon(
        definition_uuid: uuid(5),
        source_uuid: uuid(50 + index),
        points: [[index, 0, 0], [index + 1, 0, 0], [index + 1, 0, 1], [index, 0, 1]],
        normal: [0, -1, 0]
      )
    end
    occurrences = 100.times.map do |index|
      occurrence(
        path: [uuid(80 + index)],
        definition_uuid: uuid(5),
        translation: [index * 2, 0, 0]
      )
    end

    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', faces)],
        extra_primitives: faces,
        extra_occurrences: occurrences
      )
    )

    assert_equal 1, result.fetch('definitions').length
    retained = result.fetch('definitions').first
    assert_equal 3, retained.dig('geometry', 'surfaces').length
    assert_equal 100, result.fetch('instances').length
    assert_equal (0...100).map { |index| index * 2.0 },
                 result.fetch('instances').map { |item| item.fetch('transform')[12] }.sort
    refute deep_key?(result.fetch('instances'), 'outer')
    retained_geometry_bytes = JSON.generate(retained.fetch('geometry')).bytesize
    assert_operator JSON.generate(result).bytesize, :<, retained_geometry_bytes * 100
  end

  def test_shared_definition_surfaces_reuse_definition_local_vertex_indices
    first = polygon(
      definition_uuid: uuid(5),
      source_uuid: uuid(50),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    second = polygon(
      definition_uuid: uuid(5),
      source_uuid: uuid(51),
      points: [[1, 0, 0], [2, 0, 0], [2, 0, 1], [1, 0, 1]],
      normal: [0, -1, 0]
    )

    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [first, second])],
        extra_primitives: [first, second],
        extra_occurrences: [
          occurrence(path: [uuid(80)], definition_uuid: uuid(5)),
          occurrence(path: [uuid(81)], definition_uuid: uuid(5), translation: [3, 0, 0])
        ]
      )
    )

    geometry = result.dig('definitions', 0, 'geometry')
    assert_equal [
      [0.0, 0.0, 0.0], [1.0, 0.0, 0.0],
      [1.0, 0.0, 1.0], [0.0, 0.0, 1.0],
      [2.0, 0.0, 0.0], [2.0, 0.0, 1.0]
    ], geometry.fetch('vertices')
    assert_equal [[0, 1, 2, 3], [1, 4, 5, 2]],
                 geometry.fetch('surfaces').map { |surface| surface.fetch('outer') }
  end

  def test_vertex_pool_does_not_collapse_distinct_positions_within_tolerance
    first = polygon(
      definition_uuid: uuid(5), source_uuid: uuid(50),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    second = polygon(
      definition_uuid: uuid(5), source_uuid: uuid(51),
      points: [[0, 0.0000004, 0], [1, 0.0000004, 0],
               [1, 0.0000004, 1], [0, 0.0000004, 1]],
      normal: [0, -1, 0]
    )
    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [first, second])],
        extra_primitives: [first, second],
        extra_occurrences: [
          occurrence(path: [uuid(80)], definition_uuid: uuid(5)),
          occurrence(path: [uuid(81)], definition_uuid: uuid(5))
        ]
      )
    )

    vertices = result.dig('definitions', 0, 'geometry', 'vertices')
    assert_equal 8, vertices.length
    assert_equal [0.0, 0.0000004], vertices.map { |point| point[1] }.uniq.sort
  end

  def test_visual_definition_surfaces_keep_only_indexed_geometry
    face = polygon(
      definition_uuid: uuid(5),
      source_uuid: uuid(50),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [face])],
        extra_primitives: [face],
        extra_occurrences: [
          occurrence(path: [uuid(80)], definition_uuid: uuid(5)),
          occurrence(path: [uuid(81)], definition_uuid: uuid(5), translation: [3, 0, 0])
        ]
      )
    )

    retained = result.fetch('definitions').first
    assert_equal 'visual_architectural_detail', retained.fetch('retention')
    assert_equal %w[holes outer type], retained.dig('geometry', 'surfaces', 0).keys.sort
    assert_equal [0, 1, 2, 3], retained.dig('geometry', 'surfaces', 0, 'outer')
    assert_equal 4, retained.dig('geometry', 'vertices').length
    BOMEngine::CleanAnalysis::Writer.generate(result)
  end

  def test_many_visual_surfaces_share_one_deterministic_vertex_pool
    faces = 20.times.map do |index|
      polygon(
        definition_uuid: uuid(5),
        source_uuid: uuid(40 + index),
        points: [[index, 0, 0], [index + 1, 0, 0],
                 [index + 1, 0, 1], [index, 0, 1]],
        normal: [0, -1, 0]
      )
    end
    fixture = document(
      extra_definitions: [definition(uuid(5), 'component', faces)],
      extra_primitives: faces,
      extra_occurrences: [
        occurrence(path: [uuid(180)], definition_uuid: uuid(5)),
        occurrence(path: [uuid(181)], definition_uuid: uuid(5), translation: [30, 0, 0])
      ]
    )

    first = compile(fixture)
    second = compile(fixture)
    geometry = first.dig('definitions', 0, 'geometry')

    assert_equal 42, geometry.fetch('vertices').length
    assert_equal 80, geometry.fetch('surfaces').inject(0) { |sum, surface| sum + surface.fetch('outer').length }
    assert_equal JSON.generate(first), JSON.generate(second)
    BOMEngine::CleanAnalysis::Writer.generate(first)
  end

  def test_visual_definition_holes_use_the_same_vertex_pool
    outer = [[0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0]]
    hole = [[1, 1, 0], [2, 1, 0], [2, 2, 0], [1, 2, 0]]
    face = polygon_with_hole(
      definition_uuid: uuid(5), source_uuid: uuid(50),
      outer: outer, hole: hole, normal: [0, 0, 1]
    )
    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [face])],
        extra_primitives: [face],
        extra_occurrences: [
          occurrence(path: [uuid(180)], definition_uuid: uuid(5)),
          occurrence(path: [uuid(181)], definition_uuid: uuid(5), translation: [5, 0, 0])
        ]
      )
    )

    geometry = result.dig('definitions', 0, 'geometry')
    surface = geometry.fetch('surfaces').first
    assert_equal 8, geometry.fetch('vertices').length
    assert_equal [0, 1, 2, 3], surface.fetch('outer')
    assert_equal [[4, 5, 6, 7]], surface.fetch('holes')
    BOMEngine::CleanAnalysis::Writer.generate(result)
  end

  def test_definition_coordinate_normalization_stays_below_geometry_tolerance_and_preserves_area
    source_points = [
      [0.12345678949, 0, 0], [2.12345678949, 0, 0],
      [2.12345678949, 0, 1.23456789149], [0.12345678949, 0, 1.23456789149]
    ]
    face = polygon(
      definition_uuid: uuid(5), source_uuid: uuid(50),
      points: source_points, normal: [0, -1, 0]
    )
    wall_label = label(
      target_key: [uuid(180)].freeze,
      target_kind: 'occurrence', label: 'Wall', role: 'wall'
    )
    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [face])],
        extra_primitives: [face],
        extra_occurrences: [
          occurrence(path: [uuid(180)], definition_uuid: uuid(5)),
          occurrence(path: [uuid(181)], definition_uuid: uuid(5), translation: [3, 0, 0])
        ],
        evidence: [wall_label]
      )
    )

    geometry = result.dig('definitions', 0, 'geometry')
    surface = geometry.fetch('surfaces').first
    resolved = surface.fetch('outer').map { |index| geometry.fetch('vertices').fetch(index) }
    max_error = source_points.zip(resolved).map do |source, normalized|
      Math.sqrt(3.times.inject(0.0) { |sum, axis| sum + (source[axis] - normalized[axis])**2 })
    end.max

    decimal_places = BOMEngine::CleanAnalysis::Compiler::SERIALIZATION_DECIMAL_PLACES
    max_rounding_error = Math.sqrt(3.0) * 0.5 * (10.0**-decimal_places)
    assert_operator max_error, :<=, max_rounding_error
    assert_in_delta polygon_area(resolved), surface.fetch('area_m2'), 1.0e-9
    assert_equal 'analysis_boundary', result.dig('definitions', 0, 'retention')
    BOMEngine::CleanAnalysis::Writer.generate(result)
  end

  def test_projects_shared_definition_vertices_onto_the_sketchup_face_plane
    face = polygon(
      definition_uuid: uuid(5),
      source_uuid: uuid(50),
      points: [[0, 0, 0], [1, 0.0000015, 0], [1, 0.0000026, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    occurrences = 2.times.map do |index|
      occurrence(path: [uuid(80 + index)], definition_uuid: uuid(5), translation: [index * 2, 0, 0])
    end

    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [face])],
        extra_primitives: [face],
        extra_occurrences: occurrences
      )
    )

    geometry = result.dig('definitions', 0, 'geometry')
    surface = geometry.fetch('surfaces').first
    outer = surface.fetch('outer').map { |index| geometry.fetch('vertices').fetch(index) }
    resolved = surface.merge(
      'outer' => outer,
      'holes' => [],
      'normal' => BOMEngine::CleanAnalysis::SurfaceValidator.polygon_normal(outer),
      'area_m2' => BOMEngine::CleanAnalysis::SurfaceValidator.polygon_area(outer)
    )
    assert_empty BOMEngine::CleanAnalysis::SurfaceValidator.validate(resolved)
    assert_equal [0.0], outer.map { |point| point[1] }.uniq
  end

  def test_routes_invalid_shared_definition_polygon_to_existing_fallback
    face = polygon(
      definition_uuid: uuid(5),
      source_uuid: uuid(50),
      points: [[0, 0, 0], [1, 0, 1], [0, 0, 1], [1, 0, 0]],
      normal: [0, -1, 0]
    )
    occurrences = 2.times.map do |index|
      occurrence(path: [uuid(80 + index)], definition_uuid: uuid(5), translation: [index * 2, 0, 0])
    end

    result = compile(
      document(
        extra_definitions: [definition(uuid(5), 'component', [face])],
        extra_primitives: [face],
        extra_occurrences: occurrences
      )
    )

    assert_empty result.dig('definitions', 0, 'geometry', 'surfaces')
    assert_equal 1, result.fetch('fallback_geometry').length
    assert_equal result.dig('definitions', 0, 'id'), result.dig('fallback_geometry', 0, 'definition_id')
    assert_includes result.dig('fallback_geometry', 0, 'validation_issues'), 'outer has zero polygon area'
    BOMEngine::CleanAnalysis::Writer.generate(result)
  end

  def test_preserves_nested_shared_definitions_without_duplicating_child_geometry
    child_face = polygon(
      definition_uuid: uuid(6),
      source_uuid: uuid(60),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    parent_occurrences = 10.times.map do |index|
      occurrence(path: [uuid(100 + index)], definition_uuid: uuid(5), translation: [index * 3, 0, 0])
    end
    child_occurrences = 10.times.map do |index|
      occurrence(
        path: [uuid(100 + index), uuid(70)],
        definition_uuid: uuid(6),
        translation: [index * 3, 0, 0]
      )
    end

    result = compile(
      document(
        extra_definitions: [
          definition(uuid(5), 'component', []),
          definition(uuid(6), 'component', [child_face])
        ],
        extra_primitives: [child_face],
        extra_occurrences: parent_occurrences + child_occurrences
      )
    )

    assert_equal 2, result.fetch('definitions').length
    child_definition = result.fetch('definitions').find do |item|
      item.dig('geometry', 'surfaces').length == 1
    end
    refute_nil child_definition
    assert_equal 1, child_definition.dig('geometry', 'surfaces').length
    assert_equal 20, result.fetch('instances').length
    nested = result.fetch('instances').select { |item| item.key?('parent_instance_id') }
    assert_equal 10, nested.length
    parent_ids = result.fetch('instances').map { |item| item.fetch('id') }
    assert nested.all? { |item| parent_ids.include?(item.fetch('parent_instance_id')) }
  end

  def test_repeated_window_detail_is_shared_instead_of_becoming_top_level_analysis_surfaces
    frame_faces = 6.times.map do |index|
      polygon(
        definition_uuid: uuid(7),
        source_uuid: uuid(40 + index),
        points: [[index * 0.1, 0, 0], [(index + 1) * 0.1, 0, 0],
                 [(index + 1) * 0.1, 0, 1], [index * 0.1, 0, 1]],
        normal: [0, -1, 0]
      )
    end
    occurrences = 20.times.map do |index|
      occurrence(path: [uuid(120 + index)], definition_uuid: uuid(7), translation: [index, 0, 0])
    end
    labels = occurrences.map do |item|
      label(
        target_key: item.uuid_path,
        target_kind: 'occurrence',
        label: 'Repeated Window',
        role: 'window'
      )
    end

    result = compile(
      document(
        extra_definitions: [definition(uuid(7), 'component', frame_faces)],
        extra_primitives: frame_faces,
        extra_occurrences: occurrences,
        evidence: labels
      )
    )

    assert_empty result.fetch('surfaces')
    assert_equal 1, result.fetch('definitions').length
    assert_equal 'visual_architectural_detail', result.dig('definitions', 0, 'retention')
    assert_equal 6, result.dig('definitions', 0, 'geometry', 'surfaces').length
    assert_equal 20, result.fetch('instances').length
    assert_equal ['window'], result.fetch('instances').map { |item| item.fetch('category') }.uniq
  end

  def test_shared_instances_preserve_translation_rotation_and_uniform_scale_without_baking_geometry
    face = polygon(
      definition_uuid: uuid(8),
      source_uuid: uuid(65),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    translation = identity_transform.dup.tap { |matrix| matrix[12] = 4.0 }.freeze
    rotation = [
      0.0, 1.0, 0.0, 0.0,
      -1.0, 0.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ].freeze
    scale = [
      2.0, 0.0, 0.0, 0.0,
      0.0, 2.0, 0.0, 0.0,
      0.0, 0.0, 2.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ].freeze

    result = compile(
      document(
        extra_definitions: [definition(uuid(8), 'component', [face])],
        extra_primitives: [face],
        extra_occurrences: [
          occurrence(path: [uuid(140)], definition_uuid: uuid(8), transform: translation),
          occurrence(path: [uuid(141)], definition_uuid: uuid(8), transform: rotation),
          occurrence(path: [uuid(142)], definition_uuid: uuid(8), transform: scale)
        ]
      )
    )

    transforms = result.fetch('instances').map { |item| item.fetch('transform') }
    assert_includes transforms, translation
    assert_includes transforms, rotation
    assert_includes transforms, scale
    assert_equal 1, result.dig('definitions', 0, 'geometry', 'surfaces').length
    assert_equal [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
                 result.dig('definitions', 0, 'geometry', 'vertices')
    assert_equal [0, 1, 2, 3], result.dig('definitions', 0, 'geometry', 'surfaces', 0, 'outer')
    assert_equal 'world', result.dig('coordinate_system', 'instance_transform_space')
  end

  def test_non_uniform_shared_instance_declares_inverse_transpose_normal_handling
    face = polygon(
      definition_uuid: uuid(10),
      source_uuid: uuid(67),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    non_uniform = [
      2.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 0.5, 0.0,
      0.0, 0.0, 0.0, 1.0
    ].freeze

    result = compile(
      document(
        extra_definitions: [definition(uuid(10), 'component', [face])],
        extra_primitives: [face],
        extra_occurrences: [
          occurrence(path: [uuid(170)], definition_uuid: uuid(10), transform: non_uniform),
          occurrence(path: [uuid(171)], definition_uuid: uuid(10))
        ]
      )
    )

    transformed = result.fetch('instances').find do |item|
      item.fetch('transform_kind') == 'non_uniform_scale'
    end
    refute_nil transformed
    assert_equal 'inverse_transpose_required', transformed.fetch('normal_transform')
  end

  def test_repeated_nested_export_is_byte_deterministic
    face = polygon(
      definition_uuid: uuid(9),
      source_uuid: uuid(66),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
      normal: [0, -1, 0]
    )
    fixture = document(
      extra_definitions: [definition(uuid(9), 'component', [face])],
      extra_primitives: [face],
      extra_occurrences: 20.times.map do |index|
        occurrence(path: [uuid(150 + index)], definition_uuid: uuid(9), translation: [index, 0, 0])
      end
    )

    first = BOMEngine::CleanAnalysis::Writer.generate(compile(fixture))
    second = BOMEngine::CleanAnalysis::Writer.generate(compile(fixture))

    assert_equal first, second
  end

  def test_shared_definition_hole_order_and_vertex_pool_are_input_order_independent
    outer = [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]]
    small_hole = [[1, 1, 0], [1, 2, 0], [2, 2, 0], [2, 1, 0]]
    large_hole = [[7, 7, 0], [7, 9, 0], [9, 9, 0], [9, 7, 0]]
    first_face = polygon_with_holes(
      definition_uuid: uuid(12),
      source_uuid: uuid(68),
      outer: outer,
      holes: [large_hole, small_hole],
      normal: [0, 0, 1]
    )
    second_face = polygon_with_holes(
      definition_uuid: uuid(12),
      source_uuid: uuid(68),
      outer: outer,
      holes: [small_hole, large_hole],
      normal: [0, 0, 1]
    )
    occurrences = [
      occurrence(path: [uuid(180)], definition_uuid: uuid(12)),
      occurrence(path: [uuid(181)], definition_uuid: uuid(12), translation: [12, 0, 0])
    ]

    first = compile(document(
      extra_definitions: [definition(uuid(12), 'component', [first_face])],
      extra_primitives: [first_face],
      extra_occurrences: occurrences
    ))
    second = compile(document(
      extra_definitions: [definition(uuid(12), 'component', [second_face])],
      extra_primitives: [second_face],
      extra_occurrences: occurrences.reverse
    ))

    assert_equal BOMEngine::CleanAnalysis::Writer.generate(first),
                 BOMEngine::CleanAnalysis::Writer.generate(second)
    assert_equal first.dig('definitions', 0, 'geometry', 'vertices'),
                 second.dig('definitions', 0, 'geometry', 'vertices')
    assert_equal first.dig('definitions', 0, 'geometry', 'surfaces', 0, 'holes'),
                 second.dig('definitions', 0, 'geometry', 'surfaces', 0, 'holes')
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
    assert_includes reasons, 'intermediate_horizontal_region'
    assert_includes reasons, 'primary_lowest_horizontal_region'
    assert_includes reasons, 'primary_highest_horizontal_region'
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

    assert_empty result.fetch('surfaces')
    assert_equal 1, result.fetch('definitions').length
    retained_surface = result.dig('definitions', 0, 'geometry', 'surfaces', 0)
    assert_equal 'analysis_boundary', result.dig('definitions', 0, 'retention')
    assert_equal %w[area_m2 classification_hint holes id normal outer source_count type],
                 retained_surface.keys.sort
    overrides = result.fetch('instances').flat_map do |instance|
      instance.fetch('surface_classification_overrides')
    end
    assert overrides.all? { |item| item.fetch('surface_id') == retained_surface.fetch('id') }
    assert_equal %w[roof wall], overrides.map { |item| item.fetch('type') }.sort
    assert_equal ['Atap Occurrence B', 'Dinding Occurrence A'],
                 overrides.map { |item| item.dig('classification', 'label') }.sort
  end

  def test_deduplicates_one_material_across_one_hundred_analytical_polygons
    paint = material(uuid(190), 'Wall Paint', [184, 181, 173, 255])
    faces = 100.times.map do |index|
      x = index * 2
      polygon(
        definition_uuid: uuid(1),
        source_uuid: uuid(201 + index),
        points: [[x, 0, 0], [x + 1, 0, 0], [x + 1, 1, 0], [x, 1, 0]],
        normal: [0, 0, 1],
        front_material_uuid: paint.source_uuid
      )
    end

    result = compile(document(root_primitives: faces, materials: [paint]))

    assert_equal 1, result.fetch('materials').length
    material_id = result.dig('materials', 0, 'id')
    assert_equal 100, result.fetch('surfaces').length
    assert_equal [material_id],
                 result.fetch('surfaces').map { |surface| surface.fetch('front_material_id') }.uniq
    assert_equal 1, result.dig('diagnostics', 'counts', 'material_count')
  end

  def test_preserves_front_back_color_opacity_and_compact_texture_metadata
    front = material(
      uuid(190),
      'Glass Tint',
      [64, 128, 192, 128],
      texture: {
        filename: 'C:\\materials\\facade.png',
        width_m: 0.5,
        height_m: 0.25
      }
    )
    back = material(uuid(191), 'Back Paint', [240, 230, 220, 255])
    face = polygon(
      definition_uuid: uuid(1),
      source_uuid: uuid(20),
      points: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]],
      normal: [0, 0, 1],
      front_material_uuid: front.source_uuid,
      back_material_uuid: back.source_uuid
    )

    result = compile(document(root_primitives: [face], materials: [back, front]))
    materials_by_name = result.fetch('materials').each_with_object({}) do |item, by_name|
      by_name[item.fetch('name')] = item
    end
    surface = result.fetch('surfaces').first

    assert_equal materials_by_name.fetch('Glass Tint').fetch('id'), surface.fetch('front_material_id')
    assert_equal materials_by_name.fetch('Back Paint').fetch('id'), surface.fetch('back_material_id')
    assert_equal [0.250980392, 0.501960784, 0.752941176, 0.501960784],
                 materials_by_name.fetch('Glass Tint').fetch('base_color_rgba')
    assert_equal 0.501960784, materials_by_name.fetch('Glass Tint').fetch('opacity')
    assert_equal 'srgb', materials_by_name.fetch('Glass Tint').fetch('color_space')
    assert_equal({ 'reference' => 'facade.png', 'width_m' => 0.5, 'height_m' => 0.25 },
                 materials_by_name.fetch('Glass Tint').fetch('texture'))
    assert_nil materials_by_name.fetch('Back Paint').fetch('texture')
    refute deep_key?(result, 'uv')
    refute deep_key?(result, 'uvs')
  end

  def test_instance_material_inheritance_keeps_shared_definition_and_holes
    explicit = material(uuid(190), 'Explicit Face', [220, 30, 30, 255])
    inherited = material(uuid(191), 'Occurrence Paint', [30, 60, 220, 200])
    explicit_face = polygon(
      definition_uuid: uuid(12),
      source_uuid: uuid(68),
      points: [[0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0]],
      normal: [0, 0, 1],
      front_material_uuid: explicit.source_uuid
    )
    default_face = polygon_with_hole(
      definition_uuid: uuid(12),
      source_uuid: uuid(69),
      outer: [[0, 0, 1], [4, 0, 1], [4, 4, 1], [0, 4, 1]],
      hole: [[1, 1, 1], [1, 3, 1], [3, 3, 1], [3, 1, 1]],
      normal: [0, 0, 1]
    )
    occurrences = 100.times.map do |index|
      occurrence(
        path: [uuid(301 + index)],
        definition_uuid: uuid(12),
        translation: [index * 5, 0, 0],
        material_uuid: inherited.source_uuid
      )
    end

    result = compile(document(
      extra_definitions: [definition(uuid(12), 'component', [default_face, explicit_face])],
      extra_primitives: [default_face, explicit_face],
      extra_occurrences: occurrences,
      materials: [inherited, explicit]
    ))

    assert_equal 1, result.fetch('definitions').length
    assert_equal 2, result.dig('definitions', 0, 'geometry', 'surfaces').length
    assert_equal 100, result.fetch('instances').length
    assert_equal 1, result.fetch('instances').map { |instance| instance.fetch('material_id') }.uniq.length
    definition_surfaces = result.dig('definitions', 0, 'geometry', 'surfaces')
    assert_equal 1, definition_surfaces.count { |surface| surface.key?('front_material_id') }
    assert_equal 1, definition_surfaces.count { |surface| !surface.key?('front_material_id') }
    assert_equal 1, definition_surfaces.count { |surface| surface.fetch('holes').length == 1 }
    assert_equal 2, result.dig('definitions', 0, 'geometry', 'source_count')
  end

  def test_material_order_polygon_order_and_instance_order_are_byte_deterministic
    explicit = material(uuid(190), 'Explicit Face', [200, 100, 50, 255])
    inherited = material(uuid(191), 'Occurrence Paint', [20, 40, 80, 180])
    painted = polygon(
      definition_uuid: uuid(12),
      source_uuid: uuid(68),
      points: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]],
      normal: [0, 0, 1],
      front_material_uuid: explicit.source_uuid
    )
    default = polygon_with_hole(
      definition_uuid: uuid(12),
      source_uuid: uuid(69),
      outer: [[0, 0, 1], [2, 0, 1], [2, 2, 1], [0, 2, 1]],
      hole: [[0.5, 0.5, 1], [0.5, 1.5, 1], [1.5, 1.5, 1], [1.5, 0.5, 1]],
      normal: [0, 0, 1]
    )
    occurrences = 3.times.map do |index|
      occurrence(
        path: [uuid(401 + index)],
        definition_uuid: uuid(12),
        translation: [index * 3, 0, 0],
        material_uuid: inherited.source_uuid
      )
    end
    forward = document(
      extra_definitions: [definition(uuid(12), 'component', [painted, default])],
      extra_primitives: [painted, default],
      extra_occurrences: occurrences,
      materials: [explicit, inherited]
    )
    reversed = document(
      extra_definitions: [definition(uuid(12), 'component', [default, painted])],
      extra_primitives: [default, painted],
      extra_occurrences: occurrences.reverse,
      materials: [inherited, explicit]
    )

    first = BOMEngine::CleanAnalysis::Writer.generate(compile(forward))
    second = BOMEngine::CleanAnalysis::Writer.generate(compile(reversed))

    assert_equal first, second
  end

  private

  def compile(snapshot_document)
    return nil unless defined?(BOMEngine::CleanAnalysis)

    BOMEngine::CleanAnalysis.compile(snapshot_document, debug: true)
  end

  def snapshot
    BOMEngine::SemanticV2::Snapshot
  end

  def uuid(index)
    UUIDS.fetch(index)
  end

  def document(root_primitives: [], extra_definitions: [], extra_primitives: [],
               extra_occurrences: [], evidence: [], materials: [])
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
      materials: materials.freeze,
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

  def polygon(definition_uuid:, source_uuid:, points:, normal:, adjacent_keys: [], area_m2: nil,
              front_material_uuid: nil, back_material_uuid: nil)
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
      front_material_uuid: front_material_uuid,
      back_material_uuid: back_material_uuid,
      normal: normal.map(&:to_f).freeze,
      area_m2: area_m2 || polygon_area(points),
      construction_hints: [].freeze
    )
  end

  def polygon_with_hole(definition_uuid:, source_uuid:, outer:, hole:, normal:,
                        front_material_uuid: nil, back_material_uuid: nil)
    loops = [
      snapshot::Loop.new(
        kind: 'outer',
        vertices: outer.map { |point| point.map(&:to_f).freeze }.freeze,
        edge_source_uuids: outer.each_index.map { |index| uuid(140 + index) }.freeze,
        adjacent_primitive_keys: [].freeze
      ),
      snapshot::Loop.new(
        kind: 'hole',
        vertices: hole.map { |point| point.map(&:to_f).freeze }.freeze,
        edge_source_uuids: hole.each_index.map { |index| uuid(150 + index) }.freeze,
        adjacent_primitive_keys: [].freeze
      )
    ].freeze
    snapshot::PolygonFragment.new(
      key: [definition_uuid, source_uuid].freeze,
      definition_uuid: definition_uuid,
      source_uuid: source_uuid,
      loops: loops,
      front_material_uuid: front_material_uuid,
      back_material_uuid: back_material_uuid,
      normal: normal.map(&:to_f).freeze,
      area_m2: 15.0,
      construction_hints: [].freeze
    )
  end

  def polygon_with_holes(definition_uuid:, source_uuid:, outer:, holes:, normal:,
                         front_material_uuid: nil, back_material_uuid: nil)
    loops = [
      snapshot::Loop.new(
        kind: 'outer',
        vertices: outer.map { |point| point.map(&:to_f).freeze }.freeze,
        edge_source_uuids: outer.each_index.map { |index| uuid(140 + index) }.freeze,
        adjacent_primitive_keys: [].freeze
      )
    ]
    holes.each_with_index do |hole, hole_index|
      loops << snapshot::Loop.new(
        kind: 'hole',
        vertices: hole.map { |point| point.map(&:to_f).freeze }.freeze,
        edge_source_uuids: hole.each_index.map do |edge_index|
          uuid(170 + (hole_index * 4) + edge_index)
        end.freeze,
        adjacent_primitive_keys: [].freeze
      )
    end
    snapshot::PolygonFragment.new(
      key: [definition_uuid, source_uuid].freeze,
      definition_uuid: definition_uuid,
      source_uuid: source_uuid,
      loops: loops.freeze,
      front_material_uuid: front_material_uuid,
      back_material_uuid: back_material_uuid,
      normal: normal.map(&:to_f).freeze,
      area_m2: 95.0,
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

  def material(source_uuid, name, rgba, texture: nil)
    snapshot::Material.new(
      source_uuid: source_uuid,
      name: name,
      rgba: rgba.freeze,
      texture: texture
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
