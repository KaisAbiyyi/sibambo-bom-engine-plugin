# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../clean_analysis'

class CleanAnalysisWriterTest < Minitest::Test
  def test_writes_minified_deterministic_json_without_mesh_representations
    result = nil
    Dir.mktmpdir('clean-analysis-writer') do |directory|
      path = File.join(directory, 'model_clean.json')
      if defined?(BOMEngine::CleanAnalysis::Writer)
        result = BOMEngine::CleanAnalysis::Writer.write(path, clean_document)
        first = File.binread(path)
        BOMEngine::CleanAnalysis::Writer.write(path, clean_document)
        second = File.binread(path)

        assert_equal first, second
        assert_equal JSON.generate(clean_document), first
        refute_includes first, "\n"
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

  def test_measures_compact_and_pretty_bytes_without_changing_the_document
    compact = BOMEngine::CleanAnalysis::Writer.measure(clean_document)
    pretty = BOMEngine::CleanAnalysis::Writer.measure(
      clean_document,
      pretty_print: true
    )

    assert_equal JSON.generate(clean_document).bytesize, compact
    assert_equal (JSON.pretty_generate(clean_document) + "\n").bytesize, pretty
    assert_equal 'bom_engine_clean_v1', clean_document.dig('format', 'identifier')
  end

  def test_minified_write_is_cooperative_and_reports_progress
    events = []
    error = nil

    Dir.mktmpdir('clean-analysis-streaming-writer') do |directory|
      path = File.join(directory, 'streamed_clean.json')
      begin
        BOMEngine::CleanAnalysis::Writer.write(
          path,
          clean_document,
          progress: ->(stage) { events << stage }
        )
      rescue ArgumentError => caught
        error = caught
      end

      assert_nil error
      assert_equal JSON.generate(clean_document), File.binread(path)
    end

    assert_operator events.length, :>, 10
    assert events.all? { |stage| stage == 'Writing clean JSON' }
  end

  def test_blocks_every_invalid_surface_polygon_invariant
    invalid_surfaces = {
      'outer requires three vertices' => valid_surface.merge(
        'outer' => [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]]
      ),
      'duplicate consecutive point' => valid_surface.merge(
        'outer' => [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [2.0, 0.0, 0.0], [0.0, 0.0, 1.0]]
      ),
      'non-finite coordinate' => valid_surface.merge(
        'outer' => [[0.0, 0.0, 0.0], [Float::INFINITY, 0.0, 0.0], [0.0, 0.0, 1.0]]
      ),
      'zero polygon area' => valid_surface.merge(
        'outer' => [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [2.0, 0.0, 0.0]],
        'area_m2' => 0.0
      ),
      'vertex off declared plane' => valid_surface.merge(
        'outer' => [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [2.0, 0.1, 1.0], [0.0, 0.0, 1.0]]
      ),
      'normal must be normalized' => valid_surface.merge('normal' => [0.0, -2.0, 0.0]),
      'stored area mismatch' => valid_surface.merge('area_m2' => 9.0),
      'hole requires three vertices' => valid_surface.merge(
        'holes' => [[[0.5, 0.0, 0.2], [1.5, 0.0, 0.2]]]
      ),
      'hole must lie inside outer' => valid_surface.merge(
        'holes' => [[[3.0, 0.0, 0.2], [3.5, 0.0, 0.2], [3.5, 0.0, 0.8], [3.0, 0.0, 0.8]]],
        'area_m2' => 1.7
      )
    }

    invalid_surfaces.each do |name, surface|
      error = assert_raises(ArgumentError, name) do
        BOMEngine::CleanAnalysis::Writer.generate(
          clean_document.merge('surfaces' => [surface])
        )
      end
      assert_match(/invalid surface/, error.message, name)
    end
  end

  def test_validates_definition_local_retained_polygons_too
    definition = {
      'id' => 'definition-example',
      'kind' => 'component',
      'retention' => 'visual_architectural_detail',
      'geometry' => {
        'coordinate_space' => 'definition_local',
        'source_count' => 1,
        'surfaces' => [valid_surface.merge('id' => 'definition-surface-example', 'area_m2' => 9.0)]
      }
    }

    error = assert_raises(ArgumentError) do
      BOMEngine::CleanAnalysis::Writer.generate(
        clean_document.merge('definitions' => [definition], 'instances' => [])
      )
    end

    assert_match(/invalid surface definition-surface-example/, error.message)
  end

  private

  def clean_document
    {
      'format' => { 'identifier' => 'bom_engine_clean_v1', 'version' => '1.0.0' },
      'units' => 'm',
      'coordinate_system' => { 'handedness' => 'right', 'up_axis' => '+Z' },
      'model' => { 'bounds' => { 'min' => [0.0, 0.0, 0.0], 'max' => [2.0, 0.0, 1.0] } },
      'surfaces' => [
        valid_surface
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

  def valid_surface
    {
      'id' => 'surface-example',
      'type' => 'wall',
      'outer' => [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [2.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
      'holes' => [],
      'normal' => [0.0, -1.0, 0.0],
      'area_m2' => 2.0,
      'source_count' => 1
    }
  end
end
