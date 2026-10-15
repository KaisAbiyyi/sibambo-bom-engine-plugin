# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require_relative '../evolution_exporter'

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
    first = BOMEngine::EvolutionExporter.normalize_output_path('C:/out/house', engine: :e2, profile: :research)
    second = BOMEngine::EvolutionExporter.normalize_output_path(first, engine: :e2, profile: :research)
    assert_equal 'C:/out/house__E2__RESEARCH.json.gz', first
    assert_equal first, second
  end
end
