# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../clean_analysis'
require_relative 'support/semantic_v2_fixtures'

class CleanAnalysisExporterTest < Minitest::Test
  include BOMEngine::Tests::SemanticV2Fixtures

  def test_exports_real_snapshot_pipeline_without_model_writes_or_triangles
    fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture
    result = nil

    Dir.mktmpdir('clean-analysis-exporter') do |directory|
      output_path = File.join(directory, 'fixture_clean.json')
      if defined?(BOMEngine::CleanAnalysis::Exporter)
        result = BOMEngine::CleanAnalysis::Exporter.export(
          model: fixture.model,
          roots: fixture.roots,
          parent_transform: BOMEngine::Tests::SemanticV2Fixtures::FakeTransformation.identity,
          output_path: output_path,
          identity_plan: fixture.identity_plan,
          settings: { include_hidden: false, scope_mode: 'model' }
        )
        payload = JSON.parse(File.binread(output_path))

        assert_equal 'bom_engine_clean_v1', payload.dig('format', 'identifier')
        assert_equal 0, payload.dig('diagnostics', 'counts', 'raw_triangle_indices_serialized')
        assert_operator payload.fetch('surfaces').length, :>=, 1
        assert_equal %w[door door door], payload.fetch('components').select { |item| item.fetch('category') == 'door' }.map { |item| item.fetch('category') }
        assert_equal [], fixture.model.operation_calls
        assert_equal [], fixture.model.writes
        assert_equal output_path, result.fetch(:path)
      end
    end

    refute_nil result
  end

  def test_default_output_path_is_separate_from_existing_export_formats
    path = nil
    if defined?(BOMEngine::CleanAnalysis::SketchupExtension)
      path = BOMEngine::CleanAnalysis::SketchupExtension.default_output_path(
        'D:/models/scratch1.skp'
      )
    end

    assert_equal 'D:/models/clean-analysis-exports/scratch1_clean.json', path
  end
end
