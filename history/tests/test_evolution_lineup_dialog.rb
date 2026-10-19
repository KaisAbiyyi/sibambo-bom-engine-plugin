# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require_relative '../../tools/history/evolution_lineup/lineup_dialog'

class TestEvolutionLineupDialog < Test::Unit::TestCase
  # Synthetic path strings; CI on Unix must use a Unix absolute path.
  OUTPUT_ROOT = Gem.win_platform? ? 'D:/SibamboExports/lineup-fixture' : File.join(Dir.tmpdir, 'sibambo-lineup-fixture')
  Tiered = { 'kind' => 'tiered_json' }.freeze
  Canonical = { 'kind' => 'canonical_v3' }.freeze
  Cleanpkg = { 'kind' => 'cleanpkg' }.freeze

  module CanonicalCore
    def self.canonical_output_path(path, compressed)
      base = path.sub(/\.json(?:\.gz)?\z/i, '').sub(/_canonical\z/i, '').sub(/__SBE-2026\.07\.16-01\z/, '')
      base + '__SBE-2026.07.16-01_canonical.json' + (compressed ? '.gz' : '')
    end
  end
  module CanonicalTarget
    Core = CanonicalCore
  end

  def test_shared_batch_is_validated_for_every_historical_format
    cases = [
      [Tiered, { output_path: File.join(OUTPUT_ROOT, 'model.json'), export_level: 'full' }],
      [Canonical, { output_path: File.join(OUTPUT_ROOT, 'model__SBE-2026.07.16-01_canonical.json.gz') }],
      [Cleanpkg, { output_path: File.join(OUTPUT_ROOT, 'model.cleanpkg') }]
    ]
    cases.each do |slot, raw|
      settings = SibamboHistory::EvolutionLab::LineupDialog.validated_settings(slot, raw.merge(batch_size: 8_192), CanonicalTarget)
      assert_equal 8_192, settings.fetch(:batch_size)
      assert_raise(ArgumentError) do
        SibamboHistory::EvolutionLab::LineupDialog.validated_settings(slot, raw.merge(batch_size: 8_193), CanonicalTarget)
      end
    end
  end

  def test_json_level_and_gzip_are_not_shared_with_wrong_engine
    tiered = SibamboHistory::EvolutionLab::LineupDialog.validated_settings(
      Tiered, { output_path: File.join(OUTPUT_ROOT, 'model.json'), batch_size: 512, export_level: 'visual', export_textures: true }, CanonicalTarget
    )
    assert_equal 'visual', tiered[:export_level]
    assert_equal false, tiered[:export_textures]

    canonical_path = File.join(OUTPUT_ROOT, 'model__SBE-2026.07.16-01_canonical.json.gz')
    canonical = SibamboHistory::EvolutionLab::LineupDialog.validated_settings(
      Canonical, { output_path: canonical_path, batch_size: 512 }, CanonicalTarget
    )
    assert_equal canonical_path, canonical[:output_path]
    assert_equal true, canonical[:compress_output]
    assert_raise(ArgumentError) do
      SibamboHistory::EvolutionLab::LineupDialog.validated_settings(
        Canonical, { output_path: File.join(OUTPUT_ROOT, 'model.json'), batch_size: 512 }, CanonicalTarget
      )
    end
  end
end
