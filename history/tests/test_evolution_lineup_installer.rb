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
end
