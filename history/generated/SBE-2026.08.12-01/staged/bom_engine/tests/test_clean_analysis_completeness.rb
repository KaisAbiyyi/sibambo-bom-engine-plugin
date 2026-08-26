# frozen_string_literal: true

require 'json'
require 'minitest/autorun'

require_relative '../semantic_v2'
require_relative '../clean_analysis'
require_relative 'support/clean_analysis_completeness_fixture'

class CleanAnalysisCompletenessTest < Minitest::Test
  include CleanAnalysisCompletenessFixture

  def test_comprehensive_visible_detail_has_exactly_one_disposition
    materials = 100.times.map { |index| material(index) }
    root = architectural_shell(materials)
    details = detail_definitions(materials)
    occurrences, evidence = detail_occurrences(details)
    visual_edges = [
      visual_edge(uuid(1), uuid(450), [[0, 0, 0], [0, 0, 2]]),
      visual_edge(uuid(1), uuid(452), [[0, 0, 2], [1, 0, 3]]),
      visual_edge(
        details.fetch(:railing).fetch(:definition).source_uuid,
        uuid(451),
        [[0, 0, 1], [2, 0, 1]]
      )
    ]
    fixture = document(
      root_primitives: root,
      definitions: details.values.map { |item| item.fetch(:definition) },
      primitives: details.values.flat_map { |item| item.fetch(:primitives) },
      occurrences: occurrences,
      materials: materials,
      evidence: evidence
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture, visual_edges: visual_edges)

    assert_equal({
      'analytical' => 7,
      'visual_retained' => 12,
      'fallback' => 0,
      'explicitly_excluded' => 1,
      'unaccounted' => 0
    }, result.dig('diagnostics', 'coverage'))
    names = result.fetch('instances').map { |item| item.fetch('name') }
    %w[Window WindowFrame Door Railing Baluster RoofDetail FacadeTrim UnknownVisible].each do |name|
      assert_includes names, name
    end
    assert_equal ['Sree Entourage'], result.fetch('excluded_objects').map { |item| item.fetch('name') }
    assert_empty result.fetch('components')
    assert_equal 2, result.fetch('visual_edges').length
    railing_definition = result.fetch('definitions').find do |item|
      item.fetch('id') == stable_definition_id(details.fetch(:railing).fetch(:definition).source_uuid)
    end
    assert_equal 1, railing_definition.dig('geometry', 'edges').length
  end

  def test_materials_are_pruned_to_reachable_retained_references
    materials = 100.times.map { |index| material(index) }
    retained = 3.times.map do |index|
      polygon(
        definition_uuid: uuid(1), source_uuid: uuid(20 + index),
        points: [[index, 0, 0], [index + 0.8, 0, 0], [index + 0.8, 1, 0], [index, 1, 0]],
        normal: [0, 0, 1], material_uuid: materials.fetch(index).source_uuid
      )
    end
    excluded_face = polygon(
      definition_uuid: uuid(30), source_uuid: uuid(31),
      points: [[0, 0, 0], [1, 0, 0], [1, 1, 0]], normal: [0, 0, 1],
      material_uuid: materials.fetch(20).source_uuid
    )
    path = [uuid(32)]
    fixture = document(
      root_primitives: retained,
      definitions: [definition(uuid(30), [excluded_face])],
      primitives: [excluded_face],
      occurrences: [occurrence(path: path, definition_uuid: uuid(30))],
      materials: materials,
      evidence: [label(path, 'Sree Entourage')]
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)

    assert_equal 3, result.fetch('materials').length
    assert_equal 100, result.dig('diagnostics', 'materials', 'source')
    assert_equal 3, result.dig('diagnostics', 'materials', 'referenced')
    assert_equal 3, result.dig('diagnostics', 'materials', 'emitted')
    assert_equal 0, result.dig('diagnostics', 'materials', 'unused_emitted')
  end

  def test_nested_only_definition_and_child_geometry_remain_shared
    child_face = polygon(
      definition_uuid: uuid(40), source_uuid: uuid(41),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]], normal: [0, -1, 0]
    )
    parent = definition(uuid(42), [])
    child = definition(uuid(40), [child_face])
    occurrences = []
    100.times do |index|
      parent_path = [uuid(100 + index)]
      occurrences << occurrence(path: parent_path, definition_uuid: parent.source_uuid, translation: [index * 2, 0, 0])
      occurrences << occurrence(path: parent_path + [uuid(300 + index)], definition_uuid: child.source_uuid,
                                translation: [index * 2, 0, 0])
    end
    fixture = document(
      root_primitives: [], definitions: [parent, child], primitives: [child_face],
      occurrences: occurrences, materials: [], evidence: []
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)

    assert_equal 2, result.fetch('definitions').length
    assert_equal 200, result.fetch('instances').length
    assert_equal 1, result.fetch('definitions').sum { |item| item.dig('geometry', 'surfaces').length }
    assert_equal 100, result.fetch('instances').count { |item| item.key?('parent_instance_id') }
    assert_equal 0, result.dig('diagnostics', 'coverage', 'unaccounted')
  end

  def test_nested_primitives_below_an_excluded_occurrence_are_explicitly_accounted
    child_face = polygon(
      definition_uuid: uuid(45), source_uuid: uuid(46),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]], normal: [0, -1, 0]
    )
    parent = definition(uuid(47), [])
    child = definition(uuid(45), [child_face])
    parent_path = [uuid(48)]
    fixture = document(
      root_primitives: [], definitions: [parent, child], primitives: [child_face],
      occurrences: [
        occurrence(path: parent_path, definition_uuid: parent.source_uuid),
        occurrence(path: parent_path + [uuid(49)], definition_uuid: child.source_uuid)
      ],
      materials: [], evidence: [label(parent_path, 'Sree Entourage')]
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)

    assert_equal 1, result.dig('diagnostics', 'coverage', 'explicitly_excluded')
    assert_equal 0, result.dig('diagnostics', 'coverage', 'unaccounted')
  end

  def test_invalid_polygon_fallback_contains_reconstructable_geometry
    invalid = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(60),
      points: [[0, 0, 0], [1, 0, 0], [2, 0, 0]], normal: [0, 1, 0]
    )
    fixture = document(
      root_primitives: [invalid], definitions: [], primitives: [], occurrences: [],
      materials: [], evidence: []
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)
    fallback = result.fetch('fallback_geometry').first

    assert_equal [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [2.0, 0.0, 0.0]], fallback.fetch('outer')
    assert_equal [], fallback.fetch('holes')
    assert_equal 1, result.dig('diagnostics', 'coverage', 'fallback')
    assert_equal 0, result.dig('diagnostics', 'coverage', 'unaccounted')
  end

  def test_geometry_only_floor_and_ceiling_use_vertical_context_even_when_normals_are_reversed
    low = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(70),
      points: [[0, 0, 0], [0, 4, 0], [4, 4, 0], [4, 0, 0]], normal: [0, 0, -1]
    )
    high = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(71),
      points: [[0, 0, 3], [4, 0, 3], [4, 4, 3], [0, 4, 3]], normal: [0, 0, 1]
    )
    fixture = document(
      root_primitives: [low, high], definitions: [], primitives: [], occurrences: [],
      materials: [], evidence: []
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)
    by_z = result.fetch('surfaces').sort_by { |item| item.fetch('outer').first.fetch(2) }

    assert_equal 'floor', by_z.first.fetch('type')
    assert_equal 'ceiling', by_z.last.fetch('type')
  end

  def test_explicit_floor_and_ceiling_semantics_override_vertical_context
    low = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(72),
      points: [[0, 0, 0], [0, 4, 0], [4, 4, 0], [4, 0, 0]], normal: [0, 0, -1]
    )
    high = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(73),
      points: [[0, 0, 3], [4, 0, 3], [4, 4, 3], [0, 4, 3]], normal: [0, 0, 1]
    )
    fixture = document(
      root_primitives: [low, high], definitions: [], primitives: [], occurrences: [],
      materials: [], evidence: [
        primitive_label(low.key, 'Explicit Ceiling', 'ceiling'),
        primitive_label(high.key, 'Explicit Floor', 'floor')
      ]
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)
    by_z = result.fetch('surfaces').sort_by { |item| item.fetch('outer').first.fetch(2) }

    assert_equal 'ceiling', by_z.first.fetch('type')
    assert_equal 'floor', by_z.last.fetch('type')
  end

  def test_debug_mode_adds_full_coverage_and_verbose_classification_only
    face = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(80),
      points: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]], normal: [0, 0, 1]
    )
    fixture = document(
      root_primitives: [face], definitions: [], primitives: [], occurrences: [],
      materials: [], evidence: []
    )

    production = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)
    debug = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture, debug: true)

    assert_equal({ 'method' => 'geometry_hint' }, production.dig('surfaces', 0, 'classification'))
    assert_equal 'single_horizontal_level_normal_hint', debug.dig('surfaces', 0, 'classification', 'reason')
    refute production.dig('diagnostics').key?('coverage_ledger')
    assert_equal 1, debug.dig('diagnostics', 'coverage_ledger').length
    assert_operator SibamboHistory::V20260812_01::CleanAnalysis::Writer.generate(production).bytesize, :<,
                    SibamboHistory::V20260812_01::CleanAnalysis::Writer.generate(debug).bytesize
  end

  def test_completeness_report_summarizes_coverage_materials_topology_and_definitions
    face = polygon(
      definition_uuid: uuid(1), source_uuid: uuid(90),
      points: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]], normal: [0, 0, 1]
    )
    fixture = document(
      root_primitives: [face], definitions: [], primitives: [], occurrences: [],
      materials: [], evidence: []
    )
    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)

    report = SibamboHistory::V20260812_01::CleanAnalysis::CompletenessReport.generate(result)

    assert_equal 1, report.dig('source_eligible', 'primitive_count')
    assert_equal 1, report.dig('output', 'analytical')
    assert_equal 0, report.dig('output', 'unaccounted')
    assert_equal 4, report.dig('topology', 'vertex_occurrences')
    assert_equal 4, report.dig('topology', 'unique_pooled_vertices')
    assert_equal 0, report.dig('materials', 'unused_emitted')
  end

  def test_one_thousand_instances_keep_one_geometry_copy
    face = polygon(
      definition_uuid: uuid(95), source_uuid: uuid(96),
      points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]], normal: [0, -1, 0]
    )
    shared = definition(uuid(95), [face])
    occurrences = 1000.times.map do |index|
      occurrence(path: [uuid(100 + (index % 800)), uuid(899 - (index / 800))],
                 definition_uuid: shared.source_uuid, translation: [index * 2, 0, 0])
    end
    fixture = document(
      root_primitives: [], definitions: [shared], primitives: [face],
      occurrences: occurrences, materials: [], evidence: []
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(fixture)

    assert_equal 1, result.fetch('definitions').length
    assert_equal 1, result.dig('definitions', 0, 'geometry', 'surfaces').length
    assert_equal 1000, result.fetch('instances').length
    assert_equal 1, result.dig('diagnostics', 'coverage', 'visual_retained')
    assert_equal 0, result.dig('diagnostics', 'coverage', 'unaccounted')
  end

  private

  def architectural_shell(materials)
    walls = 4.times.map do |index|
      polygon(
        definition_uuid: uuid(1), source_uuid: uuid(10 + index),
        points: [[index, 0, 0], [index + 1, 0, 0], [index + 1, 0, 3], [index, 0, 3]],
        normal: [0, -1, 0], material_uuid: materials.fetch(index % 3).source_uuid
      )
    end
    walls + [
      polygon(definition_uuid: uuid(1), source_uuid: uuid(14), points: [[0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0]], normal: [0, 0, 1]),
      polygon(definition_uuid: uuid(1), source_uuid: uuid(15), points: [[0, 0, 3], [0, 4, 3], [4, 4, 3], [4, 0, 3]], normal: [0, 0, -1]),
      polygon(
        definition_uuid: uuid(1), source_uuid: uuid(16),
        points: [[0, 0, 3], [4, 0, 3], [2, 2, 4]],
        normal: [0, -0.4472135955, 0.894427191]
      )
    ]
  end

  def detail_definitions(materials)
    specs = {
      window: [uuid(200), uuid(201)], frame: [uuid(202), uuid(203)],
      door: [uuid(204), uuid(205)], railing: [uuid(206), uuid(207)],
      baluster: [uuid(208), uuid(209)], roof_detail: [uuid(210), uuid(211)],
      facade_trim: [uuid(212), uuid(213)], unknown: [uuid(214), uuid(215)],
      entourage: [uuid(216), uuid(217)], nested_only: [uuid(218), nil],
      nested_child: [uuid(219), uuid(220)]
    }
    specs.each_with_object({}) do |(name, (definition_uuid, face_uuid)), result|
      faces = if face_uuid
                [polygon(
                  definition_uuid: definition_uuid, source_uuid: face_uuid,
                  points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
                  normal: [0, -1, 0],
                  material_uuid: name == :entourage ? materials.fetch(20).source_uuid : nil
                )]
              else
                []
              end
      result[name] = { definition: definition(definition_uuid, faces), primitives: faces }
    end
  end

  def detail_occurrences(details)
    occurrences = []
    evidence = []
    specs = [
      [:window, 'Window', 'window'], [:frame, 'WindowFrame', nil],
      [:door, 'Door', 'door'], [:railing, 'Railing', nil],
      [:roof_detail, 'RoofDetail', nil], [:facade_trim, 'FacadeTrim', nil],
      [:unknown, 'UnknownVisible', nil], [:entourage, 'Sree Entourage', nil]
    ]
    specs.each_with_index do |(key, name, role), index|
      path = key == :frame ? [uuid(250), uuid(251)] : [uuid(250 + index)]
      transform = case key
                  when :facade_trim
                    [
                      2.0, 0.0, 0.0, 0.0,
                      0.0, 1.0, 0.0, 0.0,
                      0.0, 0.0, 0.5, 0.0,
                      0.0, 0.0, 0.0, 1.0
                    ]
                  when :unknown
                    [
                      0.0, 1.0, 0.0, 0.0,
                      -1.0, 0.0, 0.0, 0.0,
                      0.0, 0.0, 1.0, 0.0,
                      0.0, 0.0, 0.0, 1.0
                    ]
                  end
      occurrences << occurrence(
        path: path,
        definition_uuid: details.fetch(key).fetch(:definition).source_uuid,
        transform: transform
      )
      evidence << label(path, name, role)
    end
    2.times do |index|
      path = [uuid(253), uuid(270 + index)]
      occurrences << occurrence(path: path, definition_uuid: details.fetch(:baluster).fetch(:definition).source_uuid)
      evidence << label(path, 'Baluster')
    end
    parent_path = [uuid(280)]
    occurrences << occurrence(path: parent_path, definition_uuid: details.fetch(:nested_only).fetch(:definition).source_uuid)
    occurrences << occurrence(path: parent_path + [uuid(281)], definition_uuid: details.fetch(:nested_child).fetch(:definition).source_uuid)
    [occurrences, evidence]
  end

  def visual_edge(definition_uuid, source_uuid, points)
    {
      definition_uuid: definition_uuid,
      source_uuid: source_uuid,
      vertices: points.map { |point| point.map(&:to_f).freeze }.freeze
    }.freeze
  end

  def primitive_label(key, name, role)
    snapshot::LabelEvidence.new(
      target_key: key,
      target_kind: 'primitive',
      label: name,
      source: 'synthetic_explicit_semantics',
      role: role,
      classification_policy: 'label_first',
      aliases: [name].freeze,
      explicit: true,
      primary: true
    )
  end

  def stable_definition_id(source_uuid)
    "definition-#{Digest::SHA256.hexdigest(source_uuid)[0, 16]}"
  end
end
