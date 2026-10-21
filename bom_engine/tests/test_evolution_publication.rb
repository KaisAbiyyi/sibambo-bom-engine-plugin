# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require_relative '../evolution_exporter'
require_relative '../performance_trace'

class TestEvolutionPublication < Test::Unit::TestCase
  FakeModel = Struct.new(:path, :guid, :name, :modified, :observers) do
    def initialize(*args)
      super
      self.observers ||= []
    end

    def add_observer(observer)
      observers << observer
    end

    def remove_observer(observer)
      observers.delete(observer)
    end

    def modified?
      modified == true
    end

    def commit_edit
      observers.each { |observer| observer.onTransactionCommit(self) }
    end
  end

  def test_pair_publication_replaces_both_files
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'model.json')
      sidecar = "#{output}.provenance.json"
      File.binwrite(output, 'old-artifact')
      File.binwrite(sidecar, 'old-sidecar')
      candidate = File.join(dir, 'candidate.json')
      sidecar_candidate = File.join(dir, 'candidate-sidecar.json')
      File.binwrite(candidate, 'new-artifact')
      File.binwrite(sidecar_candidate, 'new-sidecar')
      BOMEngine::EvolutionExporter.publish_pair(candidate, sidecar_candidate, output, sidecar)
      assert_equal 'new-artifact', File.binread(output)
      assert_equal 'new-sidecar', File.binread(sidecar)
      assert_equal [], Dir.glob(File.join(dir, '*.bak'))
    end
  end

  def test_second_rename_failure_restores_old_pair_and_cleans_partial_output
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'model.json')
      sidecar = "#{output}.provenance.json"
      File.binwrite(output, 'old-artifact')
      File.binwrite(sidecar, 'old-sidecar')
      candidate = File.join(dir, 'candidate.json')
      sidecar_candidate = File.join(dir, 'candidate-sidecar.json')
      File.binwrite(candidate, 'new-artifact')
      File.binwrite(sidecar_candidate, 'new-sidecar')
      calls = 0
      mover = lambda do |source, destination|
        calls += 1
        raise IOError, 'injected sidecar rename failure' if calls == 2
        FileUtils.mv(source, destination, force: true)
      end
      assert_raise(IOError) do
        BOMEngine::EvolutionExporter.publish_pair(candidate, sidecar_candidate, output, sidecar, move: mover)
      end
      assert_equal 'old-artifact', File.binread(output)
      assert_equal 'old-sidecar', File.binread(sidecar)
      assert_equal [], Dir.glob(File.join(dir, '*.bak'))
    end
  end

  def test_revision_guard_rejects_edit_even_when_model_started_dirty
    model = FakeModel.new('', 'model-guid', 'fixture', true, [])
    guard = BOMEngine::EvolutionExporter::ModelRevisionGuard.new(model, active_model: -> { model }).attach
    assert_equal true, guard.check!
    model.commit_edit
    assert_raise(BOMEngine::EvolutionExporter::ModelChanged) { guard.check! }
  ensure
    guard&.detach
  end

  def test_revision_guard_rejects_path_or_active_model_change
    model = FakeModel.new('C:/a.skp', 'model-guid', 'fixture', false, [])
    active = model
    guard = BOMEngine::EvolutionExporter::ModelRevisionGuard.new(model, active_model: -> { active }).attach
    model.path = 'C:/b.skp'
    assert_raise(BOMEngine::EvolutionExporter::ModelChanged) { guard.check! }
    model.path = 'C:/a.skp'
    active = FakeModel.new('', 'other', 'other', false, [])
    assert_raise(BOMEngine::EvolutionExporter::ModelChanged) { guard.check! }
  ensure
    guard&.detach
  end

  def test_output_name_normalization_is_idempotent
    first = BOMEngine::EvolutionExporter.normalize_output_path('C:/out/house', engine: :e2, profile: :exact)
    second = BOMEngine::EvolutionExporter.normalize_output_path(first, engine: :e2, profile: :exact)
    assert_equal 'C:/out/house__E2__EXACT.json.gz', first
    assert_equal first, second
  end

  def test_performance_receipt_is_separate_from_artifact_and_provenance
    Dir.mktmpdir('evolution-performance-receipt') do |dir|
      output = File.join(dir, 'house__E2__VISUAL.json.gz')
      receipt_path = BOMEngine::EvolutionExporter.performance_receipt_path(output)
      assert_equal "#{output}.performance.json", receipt_path
      refute_equal "#{output}.provenance.json", receipt_path

      trace = BOMEngine::PerformanceTrace.new(enabled: true, metadata: { engine: 'e2', profile: 'visual' })
      trace.stage(:writer) { 1 + 1 }
      receipt = BOMEngine::EvolutionExporter.finalize_performance_trace(output, trace, status: :success)
      assert_equal receipt_path, receipt[:path]
      parsed = JSON.parse(File.read(receipt_path, encoding: 'UTF-8'))
      assert_equal BOMEngine::PerformanceTrace::SCHEMA, parsed['schema']
      assert_equal 'success', parsed['status']
      refute File.exist?(output), 'performance receipt must not create the artifact'
      refute File.exist?("#{output}.provenance.json"), 'performance receipt must not create provenance'

      failed_trace = BOMEngine::PerformanceTrace.new(enabled: true, metadata: { engine: 'e2', profile: 'visual' })
      failed = BOMEngine::EvolutionExporter.finalize_performance_trace(
        output, failed_trace, status: :error, error: RuntimeError.new('failed'),
        metadata: { source_tree_sha256: 'a' * 64, preserved_existing_artifact: { sha256: 'b' * 64, bytes: 12 } }
      )
      assert(failed[:path].end_with?('.performance.error.json'), 'failed attempt uses a distinct receipt path')
      assert(File.file?(receipt_path), 'failed attempt preserves the success receipt path')
      failed_payload = JSON.parse(File.read(failed[:path], encoding: 'UTF-8'))
      assert_equal 'a' * 64, failed_payload.dig('metadata', 'source_tree_sha256')
      assert_equal 'b' * 64, failed_payload.dig('metadata', 'preserved_existing_artifact', 'sha256')
    end
  end
end
