# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../clean_analysis'
require_relative 'support/semantic_v2_fixtures'

class CleanAnalysisProfilerTest < Minitest::Test
  def test_reports_geometry_structure_expansion_and_byte_offenders
    fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture
    snapshot = BOMEngine::SemanticV2::Extractor.extract(
      model: fixture.model,
      roots: fixture.roots,
      parent_transform: BOMEngine::Tests::SemanticV2Fixtures::FakeTransformation.identity,
      identity_plan: fixture.identity_plan,
      settings: { include_hidden: false, scope_mode: 'model' }
    )
    profiler = BOMEngine::CleanAnalysis::Profiler.new(snapshot)
    document = BOMEngine::CleanAnalysis::Compiler.compile(
      snapshot,
      profiler: profiler
    )
    report = profiler.report(document)

    assert_equal BOMEngine::CleanAnalysis::Writer.measure(document),
                 report.dig('output_bytes', 'minified')
    assert_equal BOMEngine::CleanAnalysis::Writer.measure(document, pretty_print: true),
                 report.dig('output_bytes', 'pretty_estimated')
    assert_equal report.dig('output_bytes', 'minified'),
                 report.dig('appearance', 'with_appearance_bytes')
    assert_operator report.dig('appearance', 'without_appearance_bytes'), :<,
                    report.dig('appearance', 'with_appearance_bytes')
    assert_operator report.dig('appearance', 'total_overhead_bytes'), :>, 0
    assert_operator report.dig('appearance', 'breakdown_bytes', 'material_table'), :>, 0
    assert_operator report.dig('appearance', 'breakdown_bytes', 'analytical_surface_material_ids'), :>, 0
    assert_operator report.dig('appearance', 'breakdown_bytes', 'definition_polygon_material_ids'), :>, 0
    assert_equal 0, report.dig('appearance', 'breakdown_bytes', 'uv_data')
    assert_equal 4, report.dig('geometry', 'polygon_count')
    assert_equal 3, report.dig('geometry', 'analytical_polygon_count')
    assert_equal 1, report.dig('geometry', 'definition_polygon_count')
    assert_equal 20, report.dig('geometry', 'total_polygon_vertex_occurrences')
    assert_equal 20, report.dig('geometry', 'serialized_vertex_positions')
    assert_equal 8, report.dig('geometry', 'definition_vertex_pool_positions')
    assert_equal 1.0, report.dig('geometry', 'serialized_vertex_duplication_ratio')
    assert_equal 5, report.dig('sketchup_structure', 'occurrence_count')
    assert_equal 1, report.dig('sketchup_structure', 'group_count')
    assert_equal 3, report.dig('sketchup_structure', 'component_instance_count')
    assert_equal 1, report.dig('sketchup_structure', 'nested_instance_count')
    assert_equal 1, report.dig('expansion', 'expanded_occurrence_count')
    assert_equal 1, report.dig('expansion', 'occurrence_expanded_geometry')
    assert_equal 1.0, report.dig('expansion', 'instance_expansion_ratio')
    assert_operator report.dig('serialized_byte_attribution', 'polygon_coordinates'), :>, 0
    assert_operator report.dig('serialized_byte_attribution', 'polygon_topology_indices'), :>, 0
    assert_equal 3, report.dig('top_offenders', 'surfaces').length
    assert_operator report.dig('top_offenders', 'definitions').length, :>=, 1
  end

  def test_profile_measurement_can_yield_progress_while_counting_large_json
    fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture
    snapshot = BOMEngine::SemanticV2::Extractor.extract(
      model: fixture.model,
      roots: fixture.roots,
      parent_transform: BOMEngine::Tests::SemanticV2Fixtures::FakeTransformation.identity,
      identity_plan: fixture.identity_plan,
      settings: { include_hidden: false, scope_mode: 'model' }
    )
    profiler = BOMEngine::CleanAnalysis::Profiler.new(snapshot)
    document = BOMEngine::CleanAnalysis::Compiler.compile(snapshot, profiler: profiler)
    events = []

    profiler.report(document, progress: ->(stage) { events << stage })

    assert_includes events, 'Writing clean JSON'
  end
end
