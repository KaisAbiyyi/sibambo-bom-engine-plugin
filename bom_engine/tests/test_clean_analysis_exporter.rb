# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../clean_analysis'
require_relative 'support/semantic_v2_fixtures'

class CleanAnalysisExporterTest < Minitest::Test
  include BOMEngine::Tests::SemanticV2Fixtures

  class ReadOnlyIdentityModel
    attr_reader :entities, :shadow_info, :operation_calls, :writes

    def initialize(entities)
      @entities = entities
      @shadow_info = { 'NorthAngle' => 0.0 }
      @operation_calls = []
      @writes = []
    end

    def active_path
      []
    end

    def get_attribute(_dictionary, _key, default = nil)
      default
    end
  end

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

  def test_read_only_clean_export_does_not_materialize_publication_registry
    face = BOMEngine::Tests::SemanticV2Fixtures::FakeFace.new(
      outer: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]],
      area: 4.0
    )
    owners = [face] + face.loops.flat_map(&:edges)
    owners.each_with_index do |owner, index|
      owner.instance_variable_set(:@test_persistent_id, 100 + index)
      owner.define_singleton_method(:persistent_id) { @test_persistent_id }
      next if owner.respond_to?(:get_attribute)

      owner.define_singleton_method(:get_attribute) do |_dictionary, _key, default = nil|
        default
      end
    end
    model = ReadOnlyIdentityModel.new([face])
    registry_class = BOMEngine::SemanticV2::IdentityRegistry
    original_to_h = registry_class.instance_method(:to_h)
    materializations = 0
    registry_class.define_method(:to_h) do
      materializations += 1
      original_to_h.bind(self).call
    end

    begin
      Dir.mktmpdir('clean-analysis-read-only-plan') do |directory|
        BOMEngine::CleanAnalysis::Exporter.export(
          model: model,
          roots: model.entities,
          parent_transform: BOMEngine::Tests::SemanticV2Fixtures::FakeTransformation.identity,
          output_path: File.join(directory, 'fixture_clean.json'),
          settings: { include_hidden: false, scope_mode: 'model' }
        )
      end
    ensure
      registry_class.define_method(:to_h, original_to_h)
    end

    assert_equal 0, materializations,
                 'read-only compilation must defer the registry publication snapshot'
    assert_empty model.operation_calls
    assert_empty model.writes
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

  def test_exports_the_same_unchanged_fixture_to_byte_identical_clean_json
    fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture

    Dir.mktmpdir('clean-analysis-determinism') do |directory|
      first_path = File.join(directory, 'first_clean.json')
      second_path = File.join(directory, 'second_clean.json')
      export_options = {
        model: fixture.model,
        roots: fixture.roots,
        parent_transform: BOMEngine::Tests::SemanticV2Fixtures::FakeTransformation.identity,
        identity_plan: fixture.identity_plan,
        settings: { include_hidden: false, scope_mode: 'model' }
      }

      BOMEngine::CleanAnalysis::Exporter.export(**export_options.merge(output_path: first_path))
      BOMEngine::CleanAnalysis::Exporter.export(**export_options.merge(output_path: second_path))

      first = File.binread(first_path)
      assert_equal first, File.binread(second_path)
      assert_equal JSON.generate(JSON.parse(first)), first
      assert_equal [], fixture.model.operation_calls
      assert_equal [], fixture.model.writes
    end
  end

  def test_pretty_print_is_an_explicit_export_option
    fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture

    Dir.mktmpdir('clean-analysis-pretty-print') do |directory|
      output_path = File.join(directory, 'pretty_clean.json')
      BOMEngine::CleanAnalysis::Exporter.export(
        model: fixture.model,
        roots: fixture.roots,
        parent_transform: BOMEngine::Tests::SemanticV2Fixtures::FakeTransformation.identity,
        output_path: output_path,
        identity_plan: fixture.identity_plan,
        settings: { include_hidden: false, scope_mode: 'model' },
        pretty_print: true
      )

      bytes = File.binread(output_path)
      assert_includes bytes, "\n  \"format\""
      assert_equal JSON.pretty_generate(JSON.parse(bytes)) + "\n", bytes
    end
  end

  def test_export_reports_bounded_progress_across_extraction_and_compilation
    fixture = BOMEngine::Tests::SemanticV2Fixtures.complex_fixture
    events = []
    result = nil
    error = nil

    Dir.mktmpdir('clean-analysis-progress') do |directory|
      begin
        result = BOMEngine::CleanAnalysis::Exporter.export(
          model: fixture.model,
          roots: fixture.roots,
          parent_transform: BOMEngine::Tests::SemanticV2Fixtures::FakeTransformation.identity,
          output_path: File.join(directory, 'fixture_clean.json'),
          identity_plan: fixture.identity_plan,
          settings: { include_hidden: false, scope_mode: 'model' },
          progress: ->(event) { events << event },
          batch_size: 2
        )
      rescue ArgumentError => caught
        error = caught
      end
    end

    assert_nil error
    refute_nil result
    assert_operator events.length, :>, 2
    assert_equal 'Preparing clean export', events.first.fetch(:stage)
    assert events.any? { |event| event.fetch(:stage).include?('Extracting') }
    assert events.any? { |event| event.fetch(:stage).include?('Validating neutral snapshot graph') }
    assert events.any? { |event| event.fetch(:stage).include?('Compiling') }
    assert_equal events.map { |event| event.fetch(:processed) }.sort,
                 events.map { |event| event.fetch(:processed) }
  end
end
