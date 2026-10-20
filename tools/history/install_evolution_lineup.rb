# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'optparse'
require 'open3'
require 'tmpdir'
require_relative 'build_evolution_lab'

module EvolutionLineupInstaller
  FOLDER = 'evolution_lineup'.freeze
  LOADER = 'sibambo_evolution_lineup_loader.rb'.freeze
  RETIRED_LOADERS = %w[sibambo_evolution_lab_loader.rb sibambo_e4_jcm_8b5d7b07a2ea6094.rb].freeze
  ENGINE_IDS = %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc].freeze

  def self.install(package_dir:, plugins_dir:, copy_tree: nil)
    package = File.realpath(package_dir)
    plugins = File.realpath(plugins_dir)
    manifest = JSON.parse(File.read(File.join(package, 'manifest.json')))
    package_schema = manifest['schemaVersion']
    unless %w[sibambo-evolution-lineup-package-v1 sibambo-evolution-lineup-package-v2].include?(package_schema)
      raise 'Wrong package schema'
    end
    raise 'This installer accepts candidate packages only' unless manifest['certified'] == false
    rbz = File.join(package, manifest.fetch('package'))
    raise 'Package archive checksum mismatch' unless Digest::SHA256.file(rbz).hexdigest == manifest.fetch('packageSha256')
    # Windows ships bsdtar (ZIP-aware) whereas GNU tar on Linux cannot list RBZ ZIPs.
    # Keep the native Windows installer working without requiring third-party unzip.
    list_command = Gem.win_platform? ? ['tar', '-tf', rbz] : ['unzip', '-Z', '-1', rbz]
    entries, listing_error, listing_status = Open3.capture3(*list_command)
    raise "Cannot inspect package: #{listing_error}" unless listing_status.success?
    names = entries.lines.map(&:strip)
    raise 'Unsafe archive member' if names.any? { |name| name.start_with?('/', '\\') || name.match?(/\A[A-Za-z]:/) || name.split('/').include?('..') }
    raise 'Unexpected archive content' unless names.all? { |name| name == LOADER || name.start_with?("#{FOLDER}/") }
    raise 'Package loader missing' unless names.include?(LOADER)
    destination_folder = File.expand_path(File.join(plugins, FOLDER))
    destination_loader = File.expand_path(File.join(plugins, LOADER))
    [destination_folder, destination_loader].each do |path|
      raise "Unsafe install target: #{path}" unless File.dirname(path) == plugins
    end
    existing_install = owned_installation?(destination_folder, destination_loader)
    RETIRED_LOADERS.each do |name|
      old = File.join(plugins, name)
      raise "Cannot disable old loader: #{old}.disabled already exists" if File.file?(old) && File.exist?("#{old}.disabled")
    end

    Dir.mktmpdir('evolution-lineup-install-') do |unpacked|
      extract_command = Gem.win_platform? ? ['tar', '-xf', rbz, '-C', unpacked] : ['unzip', '-q', '-o', rbz, '-d', unpacked]
      _out, extract_error, extract_status = Open3.capture3(*extract_command)
      raise "Cannot unpack package: #{extract_error}" unless extract_status.success?
      source_folder = File.join(unpacked, FOLDER)
      source_loader = File.join(unpacked, LOADER)
      raise 'Package is incomplete' unless File.directory?(source_folder) && File.file?(source_loader)
      engines = JSON.parse(File.read(File.join(source_folder, 'engines.json')))
      raise 'Expected four engine generations' unless engines.map { |engine| engine.fetch('id') } == ENGINE_IDS
      raise 'E4 source identity mismatch' unless engines.last.fetch('sha') == manifest.fetch('e4SourceTreeSha256')
      e4_build_sha_path = File.join(source_folder, 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt')
      raise 'Packaged E4 build identity is missing or mismatched' unless File.file?(e4_build_sha_path) && File.read(e4_build_sha_path).strip == manifest.fetch('e4SourceTreeSha256')
      if package_schema == 'sibambo-evolution-lineup-package-v2'
        raise 'Every Evolution slot must expose Visual/Research/Exact' unless engines.all? { |engine| engine.fetch('profiles') == %w[visual research exact] }
        shared_build_sha_path = File.join(source_folder, 'runtime', 'bom_engine', 'BUILD_SHA.txt')
        raise 'Packaged shared runtime identity is missing or mismatched' unless File.file?(shared_build_sha_path) && File.read(shared_build_sha_path).strip == manifest.fetch('sharedSourceTreeSha256')
        raise 'Shared runtime and E4 identities diverged' unless manifest.fetch('sharedSourceTreeSha256') == manifest.fetch('e4SourceTreeSha256')
      end

      backup = nil
      moved_folder = false
      moved_loader = false
      installed_new_folder = false
      installed_new_loader = false
      retired = []
      begin
        if existing_install
          previous_sha = existing_install.fetch(:e4_sha)[0, 12]
          stamp = Time.now.strftime('%Y%m%d-%H%M%S')
          base_name = "evolution_lineup_backup_#{stamp}_#{previous_sha}"
          backup = File.join(plugins, base_name)
          suffix = 1
          while File.exist?(backup)
            backup = File.join(plugins, "#{base_name}_#{suffix}")
            suffix += 1
          end
          raise "Unsafe backup target: #{backup}" unless File.dirname(backup) == plugins
          FileUtils.mkdir_p(backup)
          FileUtils.mv(destination_folder, File.join(backup, FOLDER))
          moved_folder = true
          FileUtils.mv(destination_loader, File.join(backup, LOADER))
          moved_loader = true
        end

        copier = copy_tree || ->(source, destination) { FileUtils.cp_r(source, destination) }
        copier.call(source_folder, destination_folder)
        installed_new_folder = true
        source_tree = EvolutionLabBuilder.compute_tree_sha(source_folder)
        installed_tree = EvolutionLabBuilder.compute_tree_sha(destination_folder)
        raise 'Installed Evolution folder differs from verified package' unless installed_tree == source_tree
        FileUtils.cp(source_loader, destination_loader)
        installed_new_loader = true
        raise 'Installed loader differs from verified package' unless Digest::SHA256.file(source_loader) == Digest::SHA256.file(destination_loader)

        RETIRED_LOADERS.each do |name|
          old = File.join(plugins, name)
          disabled = "#{old}.disabled"
          next unless File.file?(old)
          FileUtils.mv(old, disabled)
          retired << [old, disabled]
        end

        { installed_folder: destination_folder, installed_loader: destination_loader,
          source_tree_sha256: manifest.fetch('e4SourceTreeSha256'), backup_path: backup,
          disabled_loaders: retired.map(&:last), restart_required: true }
      rescue StandardError
        FileUtils.rm_rf(destination_loader) if installed_new_loader && File.file?(destination_loader)
        FileUtils.rm_rf(destination_folder) if installed_new_folder && File.directory?(destination_folder)
        retired.reverse_each do |old, disabled|
          FileUtils.mv(disabled, old) if File.file?(disabled) && !File.exist?(old)
        end
        FileUtils.mv(File.join(backup, LOADER), destination_loader) if moved_loader && File.file?(File.join(backup, LOADER))
        FileUtils.mv(File.join(backup, FOLDER), destination_folder) if moved_folder && File.directory?(File.join(backup, FOLDER))
        Dir.rmdir(backup) if backup && File.directory?(backup) && Dir.empty?(backup)
        raise
      end
    end
  end

  # Only replace a complete Evolution install that this installer can identify.
  # Unknown files at either owned path are preserved by refusing the upgrade.
  def self.owned_installation?(folder, loader)
    folder_exists = File.exist?(folder) || File.symlink?(folder)
    loader_exists = File.exist?(loader) || File.symlink?(loader)
    return nil unless folder_exists || loader_exists
    raise 'Existing Evolution installation is incomplete; refusing replacement' unless folder_exists && loader_exists
    raise 'Existing Evolution installation uses a symlink; refusing replacement' if File.symlink?(folder) || File.symlink?(loader)
    raise 'Existing Evolution installation has unexpected path types' unless File.directory?(folder) && File.file?(loader)

    loader_source = File.read(loader)
    unless loader_source.include?("SketchupExtension.new('Sibambo BOM Engine Evolution'") &&
           loader_source.include?("'evolution_lineup', 'master_menu.rb'")
      raise 'Existing loader is not the managed Sibambo BOM Engine Evolution loader; refusing replacement'
    end

    engines = JSON.parse(File.read(File.join(folder, 'engines.json')))
    raise 'Existing Evolution install has unexpected engine slots' unless engines.map { |engine| engine.fetch('id') } == ENGINE_IDS
    e4_sha = engines.last.fetch('sha')
    build_sha_path = File.join(folder, 'engine_e4_bomc', 'bom_engine', 'BUILD_SHA.txt')
    unless e4_sha.match?(/\A[0-9a-f]{64}\z/) && File.file?(build_sha_path) && File.read(build_sha_path).strip == e4_sha
      raise 'Existing Evolution install has an unverifiable E4 identity; refusing replacement'
    end
    { e4_sha: e4_sha }
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--package-dir PATH') { |path| options[:package_dir] = path }
    parser.on('--plugins-dir PATH') { |path| options[:plugins_dir] = path }
  end.parse!
  raise ArgumentError, 'Pass --package-dir and --plugins-dir' unless options[:package_dir] && options[:plugins_dir]
  puts JSON.pretty_generate(EvolutionLineupInstaller.install(**options))
end
