# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'tmpdir'
require 'digest'
require 'open3'
require 'rbconfig'
require_relative '../../tools/history/build_evolution_lineup'
require_relative '../../tools/history/install_evolution_lineup'

class TestEvolutionLineup < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)

  def test_four_slots_are_engine_generations_not_model_fixtures
    slots = EvolutionLineupBuilder.load_slots
    assert_equal %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc], slots.map { |slot| slot.fetch('id') }
    assert_equal %w[tiered_json canonical_v3 cleanpkg bomc_three_profile], slots.map { |slot| slot.fetch('kind') }
    assert_equal %w[SBE-2026.05.11-02 SBE-2026.07.16-01 SBE-2026.08.12-01], slots.first(3).map { |slot| slot.fetch('historyVersion') }
    assert_equal 'bd6782691ef8ba98f9d3baab698bc1cd961ce393', slots.last.fetch('baseProducerSha')
    assert_equal 'working-tree', slots.last.fetch('source')
  end

  def test_bundle_has_four_isolated_engines_and_shared_historical_dialog
    Dir.mktmpdir('evolution-lineup-') do |temp|
      result = EvolutionLineupBuilder.build(output: File.join(temp, 'package'))
      assert File.file?(result.fetch(:rbz))
      assert File.file?(result.fetch(:manifest))
      manifest = JSON.parse(File.read(result.fetch(:manifest)))
      assert_equal false, manifest.fetch('certified')
      assert_equal 4, manifest.fetch('engines').length
      assert_equal Digest::SHA256.file(result.fetch(:rbz)).hexdigest, manifest.fetch('packageSha256')
      assert_match(/\A[0-9a-f]{64}\z/, manifest.fetch('e4SourceTreeSha256'))

      archive, error, status = Open3.capture3('unzip', '-Z', '-1', result.fetch(:rbz))
      assert status.success?, error
      assert_include archive, 'sibambo_evolution_lineup_loader.rb'
      %w[e1_json e2_canonical_gzip e3_cleanpkg e4_bomc].each do |key|
        assert_include archive, "evolution_lineup/engine_#{key}/entry.rb"
      end
      assert_include archive, 'evolution_lineup/lineup_dialog.html'
      assert_include archive, 'evolution_lineup/historical_preflight.rb'
      assert_include archive, 'evolution_lineup/bomc_theme.css'
      assert_not_match(/matrix_capture|adaptive_preview|test\.skp|house2\.skp|RUMAH Y\.skp/, archive)

      staging = File.join(temp, 'package', 'staging', 'evolution_lineup')
      menu = File.read(File.join(staging, 'master_menu.rb'))
      menu_engines = JSON.parse(File.read(File.join(staging, 'engines.json')))
      assert_equal 4, menu_engines.length
      assert_include menu, 'ENGINES.each do |slot|'
      assert_include menu, 'active_menu.add_item(label)'
      assert_include menu, 'LineupDialog.show'
      assert_include menu, 'BOMCExtension.export_interactive'
      assert_include menu_engines.last.fetch('title'), 'E4 — BOMC 1.2'

      # Load all packaged engine modules under the SketchUp API mock. This
      # catches missing requires and namespace clashes without exporting SKP.
      runtime_code = <<~'RUBY'
        $LOADED_FEATURES << 'sketchup.rb'
        root = ARGV.fetch(0)
        JSON.parse(File.read(File.join(root, 'engines.json'))).each do |slot|
          require File.join(root, slot.fetch('entry'))
          engine = slot.fetch('moduleName').split('::').inject(Object) { |scope, name| scope.const_get(name) }
          engine.load_engine
          raise "Engine failed to load: #{slot.fetch('id')}" unless engine.const_defined?(:Core)
          puts slot.fetch('id')
        end
      RUBY
      mock_dir = File.join(ROOT, 'bom_engine', 'tests')
      loaded, load_error, load_status = Open3.capture3(RbConfig.ruby, '-I', mock_dir, '-r', 'sketchup_mock_helper', '-r', 'json',
                                                       '-e', runtime_code, staging)
      assert load_status.success?, load_error
      assert_equal %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc], loaded.lines.map(&:strip)

      plugins = File.join(temp, 'Plugins')
      FileUtils.mkdir_p(plugins)
      EvolutionLineupInstaller::RETIRED_LOADERS.each { |name| File.write(File.join(plugins, name), 'old loader') }
      install = EvolutionLineupInstaller.install(package_dir: File.join(temp, 'package'), plugins_dir: plugins)
      assert_equal true, install.fetch(:restart_required)
      assert File.file?(File.join(plugins, 'sibambo_evolution_lineup_loader.rb'))
      assert_equal 2, install.fetch(:disabled_loaders).length
      EvolutionLineupInstaller::RETIRED_LOADERS.each do |name|
        assert File.file?(File.join(plugins, "#{name}.disabled"))
        assert !File.exist?(File.join(plugins, name))
      end
    end
  end
end
