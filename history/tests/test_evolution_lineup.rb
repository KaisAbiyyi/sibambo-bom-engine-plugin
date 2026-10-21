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

  def test_three_active_slots_are_engine_generations_not_model_fixtures
    slots = EvolutionLineupBuilder.load_slots
    assert_equal %w[e2-canonical-gzip e3-cleanpkg e4-bomc], slots.map { |slot| slot.fetch('id') }
    assert_equal %w[canonical_v3 cleanpkg bomc_three_profile], slots.map { |slot| slot.fetch('kind') }
    assert_equal %w[e2 e3 e4], slots.map { |slot| slot.fetch('engine') }
    assert slots.all? { |slot| slot.fetch('profiles') == %w[exact visual] }
    assert_equal %w[SBE-2026.07.16-01 SBE-2026.08.12-01], slots.first(2).map { |slot| slot.fetch('historyVersion') }
    assert_equal 'bd6782691ef8ba98f9d3baab698bc1cd961ce393', slots.last.fetch('baseProducerSha')
    assert_equal 'working-tree', slots.last.fetch('source')
  end

  def test_bundle_has_three_dispatch_slots_and_one_shared_current_runtime
    Dir.mktmpdir('evolution-lineup-') do |temp|
      result = EvolutionLineupBuilder.build(output: File.join(temp, 'package'))
      assert File.file?(result.fetch(:rbz))
      assert File.file?(result.fetch(:manifest))
      manifest = JSON.parse(File.read(result.fetch(:manifest)))
      assert_equal false, manifest.fetch('certified')
      assert_equal 'sibambo-evolution-lineup-package-v3', manifest.fetch('schemaVersion')
      assert_equal 3, manifest.fetch('engines').length
      assert_equal 6, manifest.fetch('engines').sum { |engine| engine.fetch('profiles').length }
      assert_equal Digest::SHA256.file(result.fetch(:rbz)).hexdigest, manifest.fetch('packageSha256')
      assert_match(/\A[0-9a-f]{64}\z/, manifest.fetch('e4SourceTreeSha256'))
      assert_equal manifest.fetch('sharedSourceTreeSha256'), manifest.fetch('e4SourceTreeSha256')

      archive, error, status = Open3.capture3('unzip', '-Z', '-1', result.fetch(:rbz))
      assert status.success?, error
      assert_include archive, 'sibambo_evolution_lineup_loader.rb'
      %w[e2_canonical_gzip e3_cleanpkg e4_bomc].each do |key|
        assert_include archive, "evolution_lineup/engine_#{key}/entry.rb"
      end
      assert_include archive, 'evolution_lineup/runtime/entry.rb'
      assert_include archive, 'evolution_lineup/runtime/bom_engine/evolution_exporter.rb'
      assert_include archive, 'evolution_lineup/engine_e4_bomc/bom_engine/BUILD_SHA.txt'
      assert_include archive, 'evolution_lineup/lineup_dialog.html'
      assert_include archive, 'evolution_lineup/bomc_theme.css'
      assert_not_match(/matrix_capture|adaptive_preview|test\.skp|house2\.skp|RUMAH Y\.skp/, archive)

      staging = File.join(temp, 'package', 'staging', 'evolution_lineup')
      menu = File.read(File.join(staging, 'master_menu.rb'))
      menu_engines = JSON.parse(File.read(File.join(staging, 'engines.json')))
      assert_equal 3, menu_engines.length
      assert menu_engines.all? { |engine| engine.fetch('sha') == manifest.fetch('sharedSourceTreeSha256') }
      assert menu_engines.all? { |engine| engine.fetch('profiles') == %w[exact visual] }
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
          runtime = engine.load_engine
          raise "Engine failed to load: #{slot.fetch('id')}" unless runtime.const_defined?(:Core)
          raise "Shared tree mismatch: #{slot.fetch('id')}" unless engine::SOURCE_TREE_SHA256 == slot.fetch('sha')
          puts slot.fetch('id')
        end
      RUBY
      mock_dir = File.join(ROOT, 'bom_engine', 'tests')
      loaded, load_error, load_status = Open3.capture3(RbConfig.ruby, '-I', mock_dir, '-r', 'sketchup_mock_helper', '-r', 'json',
                                                       '-e', runtime_code, staging)
      assert load_status.success?, load_error
      assert_equal %w[e2-canonical-gzip e3-cleanpkg e4-bomc], loaded.lines.map(&:strip)

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


  def test_installer_upgrades_owned_v1_shape_and_rolls_back_failed_copy
    Dir.mktmpdir('evolution-lineup-upgrade-') do |temp|
      package = File.join(temp, 'package')
      result = EvolutionLineupBuilder.build(output: package)
      plugins = File.join(temp, 'Plugins')
      FileUtils.mkdir_p(plugins)
      staging = result.fetch(:staging)
      source_folder = File.join(staging, 'evolution_lineup')
      destination_folder = File.join(plugins, 'evolution_lineup')
      FileUtils.mkdir_p(destination_folder)
      old_engines = JSON.parse(File.read(File.join(source_folder, 'engines.json'))).map { |engine| engine.reject { |key, _| %w[profiles formatVersion historicalBaselineSha].include?(key) } }
      old_engines.unshift({ 'id' => 'e1-json', 'sha' => 'e' * 40 })
      File.write(File.join(destination_folder, 'engines.json'), JSON.pretty_generate(old_engines))
      old_e4 = File.join(destination_folder, 'engine_e4_bomc', 'bom_engine')
      FileUtils.mkdir_p(old_e4)
      File.write(File.join(old_e4, 'BUILD_SHA.txt'), old_engines.last.fetch('sha'))
      loader = File.join(plugins, 'sibambo_evolution_lineup_loader.rb')
      FileUtils.cp(File.join(staging, 'sibambo_evolution_lineup_loader.rb'), loader)
      old_loader_bytes = File.binread(loader)
      old_engines_bytes = File.binread(File.join(destination_folder, 'engines.json'))

      assert_raise(RuntimeError) do
        EvolutionLineupInstaller.install(
          package_dir: package,
          plugins_dir: plugins,
          copy_tree: ->(_source, _destination) { raise 'injected copy failure' }
        )
      end
      assert_equal old_loader_bytes, File.binread(loader)
      assert_equal old_engines_bytes, File.binread(File.join(destination_folder, 'engines.json'))

      installed = EvolutionLineupInstaller.install(package_dir: package, plugins_dir: plugins)
      assert installed.fetch(:backup_path)
      upgraded = JSON.parse(File.read(File.join(destination_folder, 'engines.json')))
      assert upgraded.all? { |engine| engine.fetch('profiles') == %w[exact visual] }
    end
  end

  def test_installer_accepts_legacy_package_v1_archive
    Dir.mktmpdir('evolution-lineup-v1-package-') do |temp|
      package = File.join(temp, 'package')
      staging = File.join(package, 'staging')
      lineup = File.join(staging, 'evolution_lineup')
      FileUtils.mkdir_p(lineup)
      sha = 'a' * 64
      engines = %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc].each_with_index.map do |id, index|
        key = id.tr('-', '_')
        entry_dir = File.join(lineup, "engine_#{key}")
        FileUtils.mkdir_p(entry_dir)
        File.write(File.join(entry_dir, 'entry.rb'), "# v1 fixture #{id}\n")
        { 'id' => id, 'order' => index + 1, 'sha' => index == 3 ? sha : (index + 1).to_s * 40, 'entry' => "engine_#{key}/entry.rb", 'moduleName' => "Fixture#{index + 1}" }
      end
      e4_marker = File.join(lineup, 'engine_e4_bomc', 'bom_engine')
      FileUtils.mkdir_p(e4_marker)
      File.write(File.join(e4_marker, 'BUILD_SHA.txt'), "#{sha}\n")
      File.write(File.join(lineup, 'engines.json'), JSON.pretty_generate(engines) + "\n")
      File.write(File.join(staging, 'sibambo_evolution_lineup_loader.rb'), <<~RUBY)
        extension = SketchupExtension.new('Sibambo BOM Engine Evolution', File.join(__dir__, 'evolution_lineup', 'master_menu.rb'))
      RUBY
      File.write(File.join(lineup, 'master_menu.rb'), "# legacy v1 fixture\n")
      rbz = File.join(package, 'sibambo_bom_engine_evolution_lineup.rbz')
      FileUtils.mkdir_p(package)
      EvolutionLabBuilder.zip_folder(staging, rbz)
      manifest = {
        'schemaVersion' => 'sibambo-evolution-lineup-package-v1', 'certified' => false,
        'e4SourceTreeSha256' => sha, 'package' => File.basename(rbz),
        'packageSha256' => Digest::SHA256.file(rbz).hexdigest
      }
      File.write(File.join(package, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")

      plugins = File.join(temp, 'Plugins')
      FileUtils.mkdir_p(plugins)
      installed = EvolutionLineupInstaller.install(package_dir: package, plugins_dir: plugins)
      assert_equal sha, installed.fetch(:source_tree_sha256)
      assert File.file?(File.join(plugins, 'evolution_lineup', 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt'))
      assert File.file?(File.join(plugins, 'sibambo_evolution_lineup_loader.rb'))
    end
  end
  def test_installer_accepts_legacy_package_v2_archive
    Dir.mktmpdir('evolution-lineup-v2-package-') do |temp|
      package = File.join(temp, 'package')
      staging = File.join(package, 'staging')
      lineup = File.join(staging, 'evolution_lineup')
      FileUtils.mkdir_p(lineup)
      sha = 'a' * 64
      engines = %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc].each_with_index.map do |id, index|
        key = id.tr('-', '_')
        entry_dir = File.join(lineup, "engine_#{key}")
        FileUtils.mkdir_p(entry_dir)
        File.write(File.join(entry_dir, 'entry.rb'), "# v1 fixture #{id}\n")
        { 'id' => id, 'order' => index + 1, 'sha' => sha, 'profiles' => %w[visual research exact], 'entry' => "engine_#{key}/entry.rb", 'moduleName' => "Fixture#{index + 1}" }
      end
      e4_marker = File.join(lineup, 'engine_e4_bomc', 'bom_engine')
      FileUtils.mkdir_p(e4_marker)
      File.write(File.join(e4_marker, 'BUILD_SHA.txt'), "#{sha}\n")
      FileUtils.mkdir_p(File.join(lineup, 'runtime', 'bom_engine'))
      File.write(File.join(lineup, 'runtime', 'bom_engine', 'BUILD_SHA.txt'), sha)
      File.write(File.join(lineup, 'engines.json'), JSON.pretty_generate(engines) + "\n")
      File.write(File.join(staging, 'sibambo_evolution_lineup_loader.rb'), <<~RUBY)
        extension = SketchupExtension.new('Sibambo BOM Engine Evolution', File.join(__dir__, 'evolution_lineup', 'master_menu.rb'))
      RUBY
      File.write(File.join(lineup, 'master_menu.rb'), "# legacy v1 fixture\n")
      rbz = File.join(package, 'sibambo_bom_engine_evolution_lineup.rbz')
      FileUtils.mkdir_p(package)
      EvolutionLabBuilder.zip_folder(staging, rbz)
      manifest = {
        'schemaVersion' => 'sibambo-evolution-lineup-package-v2', 'certified' => false,
        'sharedSourceTreeSha256' => sha, 'e4SourceTreeSha256' => sha, 'package' => File.basename(rbz),
        'packageSha256' => Digest::SHA256.file(rbz).hexdigest
      }
      File.write(File.join(package, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")

      plugins = File.join(temp, 'Plugins')
      FileUtils.mkdir_p(plugins)
      installed = EvolutionLineupInstaller.install(package_dir: package, plugins_dir: plugins)
      assert_equal sha, installed.fetch(:source_tree_sha256)
      assert File.file?(File.join(plugins, 'evolution_lineup', 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt'))
      assert File.file?(File.join(plugins, 'sibambo_evolution_lineup_loader.rb'))
    end
  end
end
