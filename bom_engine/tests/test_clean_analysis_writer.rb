# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../clean_analysis'

class CleanAnalysisWriterTest < Minitest::Test
  def test_writes_readable_deterministic_json_without_mesh_representations
    result = nil
    Dir.mktmpdir('clean-analysis-writer') do |directory|
      path = File.join(directory, 'model_clean.json')
      if defined?(BOMEngine::CleanAnalysis::Writer)
        result = BOMEngine::CleanAnalysis::Writer.write(path, clean_document)
        first = File.binread(path)
        BOMEngine::CleanAnalysis::Writer.write(path, clean_document)
        second = File.binread(path)

        assert_equal first, second
        assert_includes first, "\n  \"format\""
        assert_equal clean_document, JSON.parse(first)
        refute_match(/\"(?:triangles|faces|positions|loops)\"\s*:/, first)
        assert_equal first.bytesize, result.fetch(:bytes)
      end
    end

    refute_nil result
  end

  def test_rejects_redundant_mesh_keys_at_any_depth
    error = nil
    if defined?(BOMEngine::CleanAnalysis::Writer)
      error = assert_raises(ArgumentError) do
        BOMEngine::CleanAnalysis::Writer.generate(
          clean_document.merge('fallback_geometry' => [{ 'triangles' => [0, 1, 2] }])
        )
      end
    end

    refute_nil error
    assert_match(/redundant geometry key: triangles/, error.message)
  end

  private

  def clean_document
    {
      'format' => { 'identifier' => 'bom_engine_clean_v1', 'version' => '1.0.0' },
      'units' => 'm',
      'coordinate_system' => { 'handedness' => 'right', 'up_axis' => '+Z' },
      'model' => { 'bounds' => { 'min' => [0.0, 0.0, 0.0], 'max' => [2.0, 0.0, 1.0] } },
      'surfaces' => [
        {
          'id' => 'surface-example',
          'type' => 'wall',
          'outer' => [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [2.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
          'holes' => [],
          'normal' => [0.0, -1.0, 0.0],
          'area_m2' => 2.0
        }
      ],
      'components' => [],
      'excluded_objects' => [],
      'fallback_geometry' => [],
      'diagnostics' => {
        'excluded' => {},
        'counts' => {
          'raw_vertices_serialized' => 4,
          'raw_triangle_indices_serialized' => 0
        }
      }
    }
  end
end
