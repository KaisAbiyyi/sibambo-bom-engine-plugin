# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../../bom_engine/evolution_exporter'

class TestEvolutionExportAll < Test::Unit::TestCase
  FakeModel = Struct.new(:path) do
    def modified? = false
  end

  def setup
    @root = Dir.mktmpdir('sibambo-evolution-all-', Gem.win_platform? ? 'D:/projects/sibambo/scratch' : Dir.tmpdir)
    @source = File.join(@root, 'sample.skp')
    File.binwrite(@source, 'sketchup saved source')
    @model = FakeModel.new(@source)
    @original_export = BOMEngine::EvolutionExporter.method(:export)
  end

  def teardown
    BOMEngine::EvolutionExporter.define_singleton_method(:export, @original_export)
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
end
