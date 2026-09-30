# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../bomc_extension'

class TestBOMCExportAll < Minitest::Test
  FakeModel = Struct.new(:path) do
    def modified?; false; end
  end

  def with_export_stub(implementation)
    extension = BOMEngine::BOMCExtension
    original = extension.method(:export)
    extension.define_singleton_method(:export, &implementation)
    yield
  ensure
    extension.define_singleton_method(:export, original) if original
  end

  def test_all_choice_creates_three_distinct_validated_outputs_without_overwriting_old_files
    Dir.mktmpdir('bomc-all-test-') do |root|
      model = FakeModel.new(File.join(root, 'house.skp'))
      base = File.join(root, 'house')
      old_visual = BOMEngine::BOMCExtension.normalize_output_path(base, profile: :visual)
      File.binwrite(old_visual, 'old')
      options = BOMEngine::BOMCExtension.normalize_dialog_settings(
        output_path: old_visual, profile: 'all', batch_mode: 'auto'
      )
      assert_equal :all, options[:profile]
      assert_equal base, options[:output_path]
      calls = []
      events = []
      test = self
      with_export_stub(lambda do |_model, output_path:, profile:, progress:, settings:, candidate_cache:|
        calls << profile
        test.assert_equal :interactive, settings[:mode]
        test.assert_same candidate_cache, test.instance_variable_get(:@first_cache) if test.instance_variable_defined?(:@first_cache)
        test.instance_variable_set(:@first_cache, candidate_cache)
        progress.call(stage: :SCAN_MODEL, processed: 1, total: 3)
        File.binwrite(output_path, profile.to_s)
        { path: output_path, bytes: File.size(output_path), source_info: { path: model.path, bytes: 100 } }
      end) do
        result = BOMEngine::BOMCExtension.export_all_profiles(model, output_path: base,
          settings: options[:processing], progress: ->(event) { events << event })
        assert_equal %i[visual research exact], calls
        assert_equal %i[visual research exact], events.select { |event| event[:stage] == :SCAN_MODEL }.map { |event| event[:profile] }
        assert_equal 'old', File.binread(old_visual)
        assert_equal 'complete', JSON.parse(File.read(File.join(result[:path], 'export-status.json'))).fetch('status')
        assert_equal %w[exact research visual], result[:profiles].keys.map(&:to_s).sort
        result[:profiles].each do |profile, item|
          assert_equal profile.to_s, File.binread(item.fetch(:path))
          assert_includes item.fetch(:path), "__#{profile.to_s.upcase}.bomc"
        end
      end
    end
  ensure
    @first_cache = nil
  end

  def test_dialog_rejects_relative_or_directory_only_export_all_destination
    %w[house D:/exports/].each do |path|
      assert_raises(ArgumentError) do
        BOMEngine::BOMCExtension.normalize_dialog_settings(
          output_path: path, profile: 'all', batch_mode: 'auto'
        )
      end
    end
  end

  def test_all_choice_marks_partial_failure_and_keeps_earlier_result
    Dir.mktmpdir('bomc-all-fail-') do |root|
      model = FakeModel.new(File.join(root, 'house.skp'))
      calls = []
      with_export_stub(lambda do |_model, output_path:, profile:, **_kwargs|
        calls << profile
        raise 'research codec failed' if profile == :research
        File.binwrite(output_path, 'visual')
        { path: output_path, bytes: 6, source_info: { path: model.path, bytes: 100 } }
      end) do
        error = assert_raises(BOMEngine::BOMCExtension::ExportAllError) do
          BOMEngine::BOMCExtension.export_all_profiles(model, output_path: File.join(root, 'house'),
            settings: BOMEngine::BOMCProcessing.settings(:balanced), progress: ->(_event) {})
        end
        assert_equal %i[visual research], calls
        assert_includes error.message, 'research'
        assert File.file?(File.join(error.directory, 'house__SIBAMBO-BOMC-v1.2.0__VISUAL.bomc'))
        status = JSON.parse(File.read(File.join(error.directory, 'export-status.json')))
        assert_equal 'partial_failed', status.fetch('status')
        assert_equal %w[visual], status.fetch('profiles').keys
        refute File.exist?(File.join(error.directory, 'house__SIBAMBO-BOMC-v1.2.0__EXACT.bomc'))
      end
    end
  end
end
