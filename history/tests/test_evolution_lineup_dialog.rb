# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require_relative '../../tools/history/evolution_lineup/lineup_dialog'

class TestEvolutionLineupDialog < Test::Unit::TestCase
  # Synthetic output paths are D:-scoped on Windows and absolute on Unix CI.
  OUTPUT_ROOT = Gem.win_platform? ? 'D:/SibamboExports/lineup-fixture' : File.join(Dir.tmpdir, 'sibambo-lineup-fixture')
  Tiered = { 'engine' => 'e1', 'kind' => 'tiered_json', 'profiles' => %w[visual research exact] }.freeze
  Canonical = { 'engine' => 'e2', 'kind' => 'canonical_v3', 'profiles' => %w[visual research exact] }.freeze
  Cleanpkg = { 'engine' => 'e3', 'kind' => 'cleanpkg', 'profiles' => %w[visual research exact] }.freeze

  module CanonicalTarget
    def self.normalize_output_path(path, profile)
      engine = if path.downcase.end_with?('.cleanpkg') then 'E3'
               elsif path.downcase.end_with?('.json.gz') then 'E2'
               else 'E1'
               end
      extension = engine == 'E1' ? '.json' : engine == 'E2' ? '.json.gz' : '.cleanpkg'
      base = path.sub(/__E[1-3]__(?:VISUAL|RESEARCH|EXACT)(?:\.json(?:\.gz)?|\.cleanpkg)\z/i, '')
                 .sub(/(?:\.json(?:\.gz)?|\.cleanpkg)\z/i, '')
      "#{base}__#{engine}__#{profile.to_s.upcase}#{extension}"
    end
  end

  def test_shared_batch_and_profile_are_validated_for_every_active_format
    cases = [
      [Tiered, { output_path: File.join(OUTPUT_ROOT, 'model__E1__EXACT.json') }],
      [Canonical, { output_path: File.join(OUTPUT_ROOT, 'model__E2__EXACT.json.gz') }],
      [Cleanpkg, { output_path: File.join(OUTPUT_ROOT, 'model__E3__EXACT.cleanpkg') }]
    ]
    cases.each do |slot, raw|
      settings = SibamboHistory::EvolutionLab::LineupDialog.validated_settings(slot, raw.merge(batch_size: 8_192, profile: 'exact'), CanonicalTarget)
      assert_equal 8_192, settings.fetch(:batch_size)
      assert_equal :exact, settings.fetch(:profile)
      assert_raise(ArgumentError) do
        SibamboHistory::EvolutionLab::LineupDialog.validated_settings(slot, raw.merge(batch_size: 8_193, profile: 'exact'), CanonicalTarget)
      end
    end
  end

  def test_profile_and_output_name_must_match_active_writer_contract
    exact = SibamboHistory::EvolutionLab::LineupDialog.validated_settings(
      Canonical, { output_path: File.join(OUTPUT_ROOT, 'model__E2__EXACT.json.gz'), batch_size: 512, profile: 'exact' }, CanonicalTarget
    )
    assert_equal :exact, exact[:profile]
    assert_raise(ArgumentError) do
      SibamboHistory::EvolutionLab::LineupDialog.validated_settings(
        Canonical, { output_path: File.join(OUTPUT_ROOT, 'model__E2__VISUAL.json.gz'), batch_size: 512, profile: 'exact' }, CanonicalTarget
      )
    end
    assert_raise(ArgumentError) do
      SibamboHistory::EvolutionLab::LineupDialog.validated_settings(
        Canonical, { output_path: File.join(OUTPUT_ROOT, 'model__E2__STANDARD.json.gz'), batch_size: 512, profile: 'standard' }, CanonicalTarget
      )
    end
  end
end
