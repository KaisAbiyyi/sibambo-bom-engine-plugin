# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/history/install_evolution_lineup'

class TestEvolutionLineupInstaller < Test::Unit::TestCase
  def test_installs_verified_archive_and_reversibly_disables_old_menus
    Dir.mktmpdir('lineup-installer-') do |root|
      package = File.join(root, 'package')
      stage = File.join(package, 'staging')
      folder = File.join(stage, 'evolution_lineup')
      plugins = File.join(root, 'Plugins')
      FileUtils.mkdir_p(folder)
      FileUtils.mkdir_p(plugins)
      engines = %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc].map { |id| { 'id' => id, 'sha' => 'a' * 64 } }
      File.write(File.join(folder, 'engines.json'), JSON.generate(engines))
      FileUtils.mkdir_p(File.join(folder, 'engine_e4_bomc', 'bom_engine'))
      File.write(File.join(folder, 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt'), 'a' * 64)
      File.write(File.join(stage, 'sibambo_evolution_lineup_loader.rb'), 'new loader')
      EvolutionLineupInstaller::RETIRED_LOADERS.each { |name| File.write(File.join(plugins, name), 'old loader') }

      rbz = File.join(package, 'lineup.rbz')
      EvolutionLabBuilder.zip_folder(stage, rbz)
      File.write(File.join(package, 'manifest.json'), JSON.generate(
        'schemaVersion' => 'sibambo-evolution-lineup-package-v1', 'certified' => false,
        'package' => 'lineup.rbz', 'packageSha256' => Digest::SHA256.file(rbz).hexdigest,
        'e4SourceTreeSha256' => 'a' * 64
      ))

      result = EvolutionLineupInstaller.install(package_dir: package, plugins_dir: plugins)
      assert_equal true, result.fetch(:restart_required)
      assert File.file?(File.join(plugins, 'sibambo_evolution_lineup_loader.rb'))
      assert_equal 2, result.fetch(:disabled_loaders).length
      EvolutionLineupInstaller::RETIRED_LOADERS.each do |name|
        assert !File.exist?(File.join(plugins, name))
        assert File.file?(File.join(plugins, "#{name}.disabled"))
      end
      assert_raise(RuntimeError) { EvolutionLineupInstaller.install(package_dir: package, plugins_dir: plugins) }
    end
  end

  def test_replaces_owned_install_and_keeps_a_recoverable_backup
    Dir.mktmpdir('lineup-upgrade-') do |root|
      package = File.join(root, 'package')
      stage = File.join(package, 'staging')
      folder = File.join(stage, 'evolution_lineup')
      plugins = File.join(root, 'Plugins')
      FileUtils.mkdir_p(folder)
      FileUtils.mkdir_p(plugins)
      old_sha = 'b' * 64
      new_sha = 'a' * 64
      engines = %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc].each_with_index.map do |id, index|
        { 'id' => id, 'sha' => index == 3 ? new_sha : (id == 'e1-json' ? 'e1' : id) }
      end
      File.write(File.join(folder, 'engines.json'), JSON.generate(engines))
      FileUtils.mkdir_p(File.join(folder, 'engine_e4_bomc', 'bom_engine'))
      File.write(File.join(folder, 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt'), new_sha)
      File.write(File.join(stage, 'sibambo_evolution_lineup_loader.rb'), "SketchupExtension.new('Sibambo BOM Engine Evolution', File.join(__dir__, 'evolution_lineup', 'master_menu.rb'))")

      old_folder = File.join(plugins, 'evolution_lineup')
      old_loader = File.join(plugins, 'sibambo_evolution_lineup_loader.rb')
      FileUtils.mkdir_p(File.join(old_folder, 'engine_e4_bomc', 'bom_engine'))
      old_engines = engines.map(&:dup)
      old_engines.last['sha'] = old_sha
      File.write(File.join(old_folder, 'engines.json'), JSON.generate(old_engines))
      File.write(File.join(old_folder, 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt'), old_sha)
      File.write(old_loader, "SketchupExtension.new('Sibambo BOM Engine Evolution', File.join(__dir__, 'evolution_lineup', 'master_menu.rb'))")

      rbz = File.join(package, 'lineup.rbz')
      EvolutionLabBuilder.zip_folder(stage, rbz)
      File.write(File.join(package, 'manifest.json'), JSON.generate(
        'schemaVersion' => 'sibambo-evolution-lineup-package-v1', 'certified' => false,
        'package' => 'lineup.rbz', 'packageSha256' => Digest::SHA256.file(rbz).hexdigest,
        'e4SourceTreeSha256' => new_sha
      ))

      result = EvolutionLineupInstaller.install(package_dir: package, plugins_dir: plugins)
      backup = result.fetch(:backup_path)
      assert_equal true, result.fetch(:restart_required)
      assert_equal new_sha, File.read(File.join(old_folder, 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt')).strip
      assert_equal old_sha, File.read(File.join(backup, 'evolution_lineup', 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt')).strip
      assert File.file?(File.join(backup, 'sibambo_evolution_lineup_loader.rb'))
      assert File.file?(old_loader)
    end
  end
end
