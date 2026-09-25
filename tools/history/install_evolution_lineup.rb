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

  def self.install(package_dir:, plugins_dir:)
    package = File.realpath(package_dir)
    plugins = File.realpath(plugins_dir)
    manifest = JSON.parse(File.read(File.join(package, 'manifest.json')))
    raise 'Wrong package schema' unless manifest['schemaVersion'] == 'sibambo-evolution-lineup-package-v1'
    raise 'This installer accepts candidate packages only' unless manifest['certified'] == false
    rbz = File.join(package, manifest.fetch('package'))
    raise 'Package archive checksum mismatch' unless Digest::SHA256.file(rbz).hexdigest == manifest.fetch('packageSha256')
    entries, listing_error, listing_status = Open3.capture3('tar', '-tf', rbz)
    raise "Cannot inspect package: #{listing_error}" unless listing_status.success?
    names = entries.lines.map(&:strip)
    raise 'Unsafe archive member' if names.any? { |name| name.start_with?('/', '\\') || name.match?(/\A[A-Za-z]:/) || name.split('/').include?('..') }
    raise 'Unexpected archive content' unless names.all? { |name| name == LOADER || name.start_with?("#{FOLDER}/") }
    raise 'Package loader missing' unless names.include?(LOADER)
    destination_folder = File.expand_path(File.join(plugins, FOLDER))
    destination_loader = File.expand_path(File.join(plugins, LOADER))
    [destination_folder, destination_loader].each do |path|
      raise "Unsafe install target: #{path}" unless File.dirname(path) == plugins
      raise "Install target already exists: #{path}" if File.exist?(path)
    end
    RETIRED_LOADERS.each do |name|
      old = File.join(plugins, name)
      raise "Cannot disable old loader: #{old}.disabled already exists" if File.file?(old) && File.exist?("#{old}.disabled")
    end

    Dir.mktmpdir('evolution-lineup-install-') do |unpacked|
      _out, extract_error, extract_status = Open3.capture3('tar', '-xf', rbz, '-C', unpacked)
      raise "Cannot unpack package: #{extract_error}" unless extract_status.success?
      source_folder = File.join(unpacked, FOLDER)
      source_loader = File.join(unpacked, LOADER)
      raise 'Package is incomplete' unless File.directory?(source_folder) && File.file?(source_loader)
      engines = JSON.parse(File.read(File.join(source_folder, 'engines.json')))
      raise 'Expected four engine generations' unless engines.map { |engine| engine.fetch('id') } == %w[e1-json e2-canonical-gzip e3-cleanpkg e4-bomc]
      raise 'E4 source identity mismatch' unless engines.last.fetch('sha') == manifest.fetch('e4SourceTreeSha256')

      FileUtils.cp_r(source_folder, destination_folder)
      source_tree = EvolutionLabBuilder.compute_tree_sha(source_folder)
      installed_tree = EvolutionLabBuilder.compute_tree_sha(destination_folder)
      raise 'Installed Evolution folder differs from verified package' unless installed_tree == source_tree
      FileUtils.cp(source_loader, destination_loader)
      raise 'Installed loader differs from verified package' unless Digest::SHA256.file(source_loader) == Digest::SHA256.file(destination_loader)

      retired = []
      RETIRED_LOADERS.each do |name|
        old = File.join(plugins, name)
        disabled = "#{old}.disabled"
        next unless File.file?(old)
        FileUtils.mv(old, disabled)
        retired << disabled
      end
      { installed_folder: destination_folder, installed_loader: destination_loader,
        source_tree_sha256: manifest.fetch('e4SourceTreeSha256'), disabled_loaders: retired,
        restart_required: true }
    end
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
