# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../../bom_engine/evolution_exporter'
require_relative '../../bom_engine/tests/support/evolution_fixture'

class TestEvolutionExportAll < Test::Unit::TestCase
  FakeModel = Struct.new(:path) do
    def modified? = false
    def observers = (@observers ||= [])
    def add_observer(observer) = observers << observer
    def remove_observer(observer) = observers.delete(observer)
    def commit_edit = observers.each { |observer| observer.onTransactionCommit(self) }
  end

  def setup
    @root = Dir.mktmpdir('sibambo-evolution-all-', Gem.win_platform? ? 'D:/projects/sibambo/scratch' : Dir.tmpdir)
    @source = File.join(@root, 'sample.skp')
    File.binwrite(@source, 'sketchup saved source')
    @model = FakeModel.new(@source)
    @original_export = BOMEngine::EvolutionExporter.method(:export)
    @original_capture = BOMEngine::BOMCExtension.method(:capture_graph)
  end

  def teardown
    BOMEngine::EvolutionExporter.define_singleton_method(:export, @original_export)
    BOMEngine::BOMCExtension.define_singleton_method(:capture_graph, @original_capture)
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def install_fake_export(fail_at: nil)
    BOMEngine::EvolutionExporter.define_singleton_method(:export) do |_model, engine:, profile:, output_path:, **_rest|
      raise 'synthetic failure' if profile == fail_at
      File.binwrite(output_path, "#{engine} #{profile}")
      File.write("#{output_path}.provenance.json", '{"test":true}')
      { path: output_path, bytes: File.size(output_path), sha256: 'a' * 64 }
    end
  end

  def test_each_format_preserves_both_outputs_and_status
    install_fake_export
    %i[e2 e3].each do |engine|
      base = File.join(@root, engine.to_s)
      result = BOMEngine::EvolutionExporter.export_all_profiles(
        @model, engine: engine, output_base_path: base, active_model: -> { @model }
      )
      assert_equal 'complete', result[:status]
      assert_equal %i[exact visual], result[:profiles].keys
      assert_not_equal base, result[:path]
      assert_equal 'complete', JSON.parse(File.read(File.join(result[:path], 'export-status.json')))['status']
      %i[exact visual].each do |profile|
        path = result[:profiles][profile][:path]
        assert File.file?(path)
        assert File.file?("#{path}.provenance.json")
        assert File.basename(path).include?("#{engine.to_s.upcase}__#{profile.to_s.upcase}")
      end
    end
  end

  def test_later_profile_failure_preserves_exact_and_marks_partial
    install_fake_export(fail_at: :visual)
    error = assert_raise(BOMEngine::EvolutionExporter::ExportAllError) do
      BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: :e2, output_base_path: File.join(@root, 'fail'))
    end
    status = JSON.parse(File.read(File.join(error.directory, 'export-status.json')))
    assert_equal 'partial_failed', status['status']
    assert_equal 'visual', status['failed_profile']
    assert File.file?(status.fetch('profiles').fetch('exact').fetch('path'))
    assert File.file?("#{status.fetch('profiles').fetch('exact').fetch('path')}.provenance.json")
  end

  def test_unsaved_model_and_unsupported_engine_are_rejected
    install_fake_export
    @model.path = ''
    assert_raise(ArgumentError) { BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: :e2, output_base_path: File.join(@root, 'bad')) }
    @model.path = @source
    assert_raise(ArgumentError) { BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: :e1, output_base_path: File.join(@root, 'bad')) }
  end
  def test_edit_and_save_between_profiles_stops_batch_and_preserves_exact
    install_fake_export
    progress = lambda do |event|
      @model.commit_edit if event[:stage] == :preparing_all && event[:profile] == :visual
    end
    error = assert_raise(BOMEngine::EvolutionExporter::ExportAllError) do
      BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: :e2,
        output_base_path: File.join(@root, 'edited'), progress: progress)
    end
    status = JSON.parse(File.read(File.join(error.directory, 'export-status.json')))
    assert_equal 'partial_failed', status['status']
    assert_equal ['exact'], status.fetch('profiles').keys
    assert_equal [], Dir.glob(File.join(error.directory, '*__VISUAL*'))
    assert_empty @model.observers, 'batch revision observer must be removed after failure'
  end

  def test_cancel_on_visual_preserves_exact_and_records_cancelled
    install_fake_export
    progress = lambda do |event|
      raise BOMEngine::ConversionJob::Cancelled if event[:stage] == :preparing_all && event[:profile] == :visual
    end
    assert_raise(BOMEngine::ConversionJob::Cancelled) do
      BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: :e3,
        output_base_path: File.join(@root, 'cancelled'), progress: progress)
    end
    directory = Dir.glob(File.join(@root, 'cancelled__E3__ALL-*')).fetch(0)
    status = JSON.parse(File.read(File.join(directory, 'export-status.json')))
    assert_equal 'cancelled', status['status']
    assert_equal 'visual', status['failed_profile']
    exact = status.fetch('profiles').fetch('exact').fetch('path')
    assert File.file?(exact)
    assert File.file?("#{exact}.provenance.json")
    assert_empty @model.observers
  end

  def test_source_replacement_before_visual_does_not_publish_visual
    install_fake_export
    progress = lambda do |event|
      File.binwrite(@source, 'different saved source') if event[:stage] == :preparing_all && event[:profile] == :visual
    end
    error = assert_raise(BOMEngine::EvolutionExporter::ExportAllError) do
      BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: :e2,
        output_base_path: File.join(@root, 'replaced'), progress: progress)
    end
    assert_equal [], Dir.glob(File.join(error.directory, '*__VISUAL*'))
    status = JSON.parse(File.read(File.join(error.directory, 'export-status.json')))
    assert_equal ['exact'], status.fetch('profiles').keys
    assert_empty @model.observers
  end

  def test_source_change_at_publication_preserves_only_the_previous_profile
    BOMEngine::BOMCExtension.define_singleton_method(:capture_graph) { |_model, **_| EvolutionFixture.graph }
    progress = lambda do |event|
      if event[:stage] == :publication && event[:profile] == :visual
        File.binwrite(@source, 'source replaced immediately before publication')
      end
    end
    error = assert_raise(BOMEngine::EvolutionExporter::ExportAllError) do
      BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: :e2,
        output_base_path: File.join(@root, 'publication'), progress: progress)
    end
    status = JSON.parse(File.read(File.join(error.directory, 'export-status.json')))
    exact = status.fetch('profiles').fetch('exact').fetch('path')
    assert File.file?(exact)
    assert File.file?("#{exact}.provenance.json")
    assert_equal [], Dir.glob(File.join(error.directory, '*__VISUAL.json.gz*')).reject { |path| path.end_with?('.performance.error.json') }
    assert_empty @model.observers
  end

  def test_both_profiles_use_real_writers_and_independent_readback_for_each_format
    BOMEngine::BOMCExtension.define_singleton_method(:capture_graph) { |_model, **_| EvolutionFixture.graph }
    %i[e2 e3].each do |engine|
      result = BOMEngine::EvolutionExporter.export_all_profiles(@model, engine: engine,
        output_base_path: File.join(@root, "real-#{engine}"))
      assert_equal 'complete', result.fetch(:status)
      result.fetch(:profiles).each do |profile, record|
        validation = BOMEngine::EvolutionValidator.validate_file!(record.fetch(:path),
          engine: engine, expected_profile: profile, artifact_sha256: record.fetch(:sha256))
        assert_equal true, validation.fetch(:passed)
        provenance = JSON.parse(File.read("#{record.fetch(:path)}.provenance.json"))
        assert_equal Digest::SHA256.file(@source).hexdigest, provenance.dig('model', 'sourceSha256')
        assert_equal profile.to_s, provenance.dig('artifact', 'profile')
      end
    end
    assert_empty @model.observers
  end

end
