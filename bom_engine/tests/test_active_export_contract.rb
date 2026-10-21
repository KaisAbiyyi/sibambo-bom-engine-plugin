# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'json'
require_relative '../evolution_exporter'
require_relative '../../tools/history/build_evolution_lineup'
require_relative '../../tools/history/evolution_lineup/lineup_dialog'

class TestActiveExportContract < Test::Unit::TestCase
  def test_retired_engine_and_profile_fail_before_output_or_receipt_creation
    Dir.mktmpdir do |root|
      [:e1, :e2, :e3].product([:exact, :research]).each do |engine, profile|
        next if engine != :e1 && profile != :research
        destination = File.join(root, 'not-created', 'artifact')
        error = assert_raise(ArgumentError) do
          BOMEngine::EvolutionExporter.export(nil, engine: engine, profile: profile, output_path: destination)
        end
        assert_include error.message, 'retired_for_new_exports'
        assert_equal false, File.exist?(File.dirname(destination))
      end
      error = assert_raise(ArgumentError) do
        BOMEngine::BOMCExtension.export(nil, output_path: File.join(root, 'not-created', 'model.bomc'), profile: :research)
      end
      assert_include error.message, 'retired_for_new_exports'
      assert_equal false, File.exist?(File.join(root, 'not-created'))
    end
  end

  def test_new_output_and_graph_publication_reject_research_instead_of_silent_fallback
    [:research, :invalid].each do |profile|
      assert_raise(ArgumentError) { BOMEngine::BOMCExtension.normalize_output_path('/tmp/model', profile: profile) }
      assert_raise(ArgumentError) { BOMEngine::BOMCExtension.publish_graph('/tmp/not-written.bomc', {}, profile: profile) }
      assert_raise(ArgumentError) { BOMEngine::BOMCExtension.normalize_dialog_settings(output_path: '/tmp/model', profile: profile) }
    end
  end

  def test_six_active_choices_preserve_original_slots_and_independent_formats
    slots = EvolutionLineupBuilder.load_slots
    assert_equal %w[e2 e3 e4], slots.map { |slot| slot.fetch('engine') }
    assert_equal [2, 3, 4], slots.map { |slot| slot.fetch('order') }
    assert_equal %w[e2-canonical-gzip e3-cleanpkg e4-bomc], slots.map { |slot| slot.fetch('id') }
    assert_equal [%w[exact visual]] * 3, slots.map { |slot| slot.fetch('profiles') }
    assert_equal %w[canonical_v3 cleanpkg bomc_three_profile], slots.map { |slot| slot.fetch('kind') }
    assert_match(/__E2__EXACT\.json\.gz\z/, BOMEngine::EvolutionExporter.normalize_output_path('/tmp/model', engine: :e2, profile: :exact))
    assert_match(/__E3__VISUAL\.cleanpkg\z/, BOMEngine::EvolutionExporter.normalize_output_path('/tmp/model', engine: :e3, profile: :visual))
  end

  def test_lineup_dialog_refuses_stale_e1_or_research_even_with_stale_slot_metadata
    dialog = SibamboHistory::EvolutionLab::LineupDialog
    stale = { 'engine' => 'e1', 'profiles' => %w[exact research visual] }
    model = Struct.new(:path).new('/tmp/model.skp')
    assert_raise(ArgumentError) { dialog.default_path(stale, model, 'exact') }
    slot = { 'engine' => 'e2', 'profiles' => %w[exact research visual] }
    assert_raise(ArgumentError) do
      dialog.validated_settings(slot, { batch_size: 512, profile: 'research', output_path: '/tmp/model.json.gz' }, Object.new)
    end
  end

  def test_legacy_document_validation_remains_available_without_enabling_active_exports
    document = BOMEngine::EvolutionDocument.prepare({}, engine: :e1, profile: :research,
      source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40)
    assert_equal 'research', document.fetch('profile')
    assert_equal 'e1', document.fetch('engine')
    assert_equal true, BOMEngine::EvolutionDocument.validate!(document)
  end
end
