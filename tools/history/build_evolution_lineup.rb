# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative 'build_evolution_lab' unless defined?(EvolutionLabBuilder)
require_relative 'build_adaptive_preview_kit'

# Curated four-generation product menu. The older active-release catalog remains
# intact for T7/T8 certification evidence; it is not the user's Evolution menu.
module EvolutionLineupBuilder
  ROOT = File.expand_path('../..', __dir__)
  LINEUP = File.join(ROOT, 'history', 'evolution-lineup.json')
  HISTORY = File.join(ROOT, 'history', 'versions.json')
  TEMPLATES = File.join(__dir__, 'evolution_lineup')
  E4_BASE = 'bd6782691ef8ba98f9d3baab698bc1cd961ce393'
  SLOT_KINDS = {
    'e1-json' => 'tiered_json',
    'e2-canonical-gzip' => 'canonical_v3',
    'e3-cleanpkg' => 'cleanpkg',
    'e4-bomc' => 'bomc_three_profile'
  }.freeze

  def self.load_slots
    data = JSON.parse(File.read(LINEUP))
    raise 'Unsupported Evolution lineup schema' unless data['schemaVersion'] == 'sibambo-evolution-lineup-v1'
    slots = data.fetch('slots')
    raise 'Evolution requires exactly four engine generations' unless slots.is_a?(Array) && slots.length == 4
    history = JSON.parse(File.read(HISTORY)).fetch('versions').map { |version| [version.fetch('display_version'), version] }.to_h
    slots.each_with_index do |slot, index|
      raise 'Evolution engine order or kind is invalid' unless slot['order'] == index + 1 && SLOT_KINDS[slot['id']] == slot['kind']
      raise 'Evolution engine title missing' if slot['title'].to_s.strip.empty?
      raise 'Do not claim an uncertified engine is ready' unless %w[uncertified development].include?(slot['state'])
      if index < 3
        version = history.fetch(slot.fetch('historyVersion'))
        raise 'Historical format does not match Evolution slot' unless EvolutionLabBuilder.historical_export_kind(version).to_s == slot['kind']
        slot['sha'] = version.fetch('commit_sha')
        slot['historical'] = version
      else
        raise 'E4 must use the evolved working tree, not the bd67826 snapshot' unless slot['source'] == 'working-tree' && slot['baseProducerSha'] == E4_BASE
      end
    end
    slots
  end

  def self.build(output:)
    output = File.expand_path(output).tr('\\', '/')
    raise ArgumentError, 'Build output already exists; use a new directory.' if File.exist?(output)
    raise ArgumentError, 'Build path may not contain apostrophes.' if output.include?("'")
    slots = load_slots
    verify_e4_ancestry!

    generated = File.join(output, 'generated')
    staging = File.join(output, 'staging')
    lab = File.join(staging, 'evolution_lineup')
    FileUtils.mkdir_p(lab)
    slots.first(3).each { |slot| stage_historical(slot, generated, lab) }
    source_tree_sha = stage_e4(slots.last, lab)
    slots.last['sha'] = source_tree_sha
    write_menu(staging, lab, slots)
    FileUtils.cp(File.join(TEMPLATES, 'lineup_dialog.rb'), File.join(lab, 'lineup_dialog.rb'))
    FileUtils.cp(File.join(TEMPLATES, 'lineup_dialog.html'), File.join(lab, 'lineup_dialog.html'))
    FileUtils.cp(File.join(TEMPLATES, 'historical_preflight.rb'), File.join(lab, 'historical_preflight.rb'))
    FileUtils.cp(File.join(ROOT, 'bom_engine', 'ui', 'bomc_theme.css'), File.join(lab, 'bomc_theme.css'))
    raise 'Evolution lineup Ruby syntax failed' unless EvolutionLabBuilder.verify_ruby_syntax(staging)

    rbz = File.join(output, 'sibambo_bom_engine_evolution_lineup.rbz')
    EvolutionLabBuilder.zip_folder(staging, rbz)
    manifest = {
      'schemaVersion' => 'sibambo-evolution-lineup-package-v1',
      'certified' => false,
      'status' => 'candidate_pending_cross_model_validation',
      'selectionBasis' => JSON.parse(File.read(LINEUP)).fetch('selectionBasis'),
      'e4BaseProducerSha' => E4_BASE,
      'e4SourceTreeSha256' => source_tree_sha,
      'engines' => slots.map { |slot| slot.slice('id', 'order', 'title', 'kind', 'state', 'sha', 'historyVersion', 'reason') },
      'package' => File.basename(rbz),
      'packageSha256' => Digest::SHA256.file(rbz).hexdigest
    }
    manifest_path = File.join(output, 'manifest.json')
    File.write(manifest_path, JSON.pretty_generate(manifest) + "\n", encoding: 'UTF-8')
    { rbz: rbz, manifest: manifest_path, staging: staging }
  end

  def self.verify_e4_ancestry!
    _out, error, status = Open3.capture3('git', 'merge-base', '--is-ancestor', E4_BASE, 'HEAD', chdir: ROOT)
    raise "Current E4 checkout is not descended from #{E4_BASE}: #{error}" unless status.success?
  end

  def self.stage_historical(slot, generated, lab)
    version = slot.fetch('historical')
    key = slot.fetch('id').tr('-', '_')
    root = File.join(generated, key)
    raw = File.join(root, 'raw')
    staged = File.join(root, 'staged')
    FileUtils.mkdir_p(raw)
    FileUtils.mkdir_p(staged)
    EvolutionLabBuilder.extract_git_snapshot(version.fetch('commit_sha'), raw, version)
    EvolutionLabBuilder.transform_snapshot(raw, staged, version, key, version.fetch('isolated_module'))
    EvolutionLabBuilder.apply_runtime_hardening(staged, version)
    make_canonical_path_idempotent(staged) if slot['kind'] == 'canonical_v3'
    raise "Historical stage failed Ruby syntax: #{key}" unless EvolutionLabBuilder.verify_ruby_syntax(staged)
    destination = File.join(lab, "engine_#{key}")
    FileUtils.cp_r(staged, destination)
    FileUtils.mv(File.join(destination, "entry_#{key}.rb"), File.join(destination, 'entry.rb'))
    FileUtils.rm_rf(File.join(destination, 'bom_engine', 'tests'))
    FileUtils.rm_rf(File.join(destination, 'tests'))
  end

  # The historical canonical exporter appended its version suffix every time.
  # Make the chosen filename stable so the UI never promises a different path.
  def self.make_canonical_path_idempotent(staged)
    path = File.join(staged, 'bom_engine', 'core.rb')
    source = File.read(path, encoding: 'UTF-8')
    anchor = "      base_path = base_path.sub(/_(?:visual|standard|full|canonical)$/i, '')"
    replacement = anchor + "\n      base_path = base_path.sub(/__SBE-2026\\.07\\.16-01$/, '')"
    raise 'Canonical path normalization anchor changed' unless source.include?(anchor)
    File.write(path, source.sub(anchor, replacement), encoding: 'UTF-8')
  end

  def self.stage_e4(slot, lab)
    files = AdaptivePreviewKit.runtime_files(ROOT)
    source_sha = AdaptivePreviewKit.inventory_digest(files)
    namespace = "EvolutionE4_#{source_sha[0, 12]}"
    directory = File.join(lab, 'engine_e4_bomc')
    files.each do |relative, expected|
      bytes = File.binread(File.join(ROOT, relative))
      raise "E4 source changed during build: #{relative}" unless Digest::SHA256.hexdigest(bytes) == expected
      bytes = AdaptivePreviewKit.transform(bytes.force_encoding('UTF-8'), namespace) if relative.end_with?('.rb')
      destination = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, bytes)
    end
    File.write(File.join(directory, 'bom_engine', 'BUILD_SHA.txt'), "#{source_sha}\n", encoding: 'UTF-8')
    entry = <<~RUBY
      # frozen_string_literal: true
      require 'sketchup.rb'
      module SibamboHistory
        EVOLUTION_LAB_EMBEDDED = true unless const_defined?(:EVOLUTION_LAB_EMBEDDED, false)
        module #{namespace}
          SOURCE_TREE_SHA256 = #{source_sha.inspect}.freeze
          BASE_PRODUCER_SHA = #{E4_BASE.inspect}.freeze
          def self.load_engine
            require_relative 'bom_engine/core'
            self
          end
        end
      end
    RUBY
    File.write(File.join(directory, 'entry.rb'), entry, encoding: 'UTF-8')
    slot['moduleName'] = "SibamboHistory::#{namespace}"
    source_sha
  end

  def self.write_menu(staging, lab, slots)
    runtime = slots.map do |slot|
      key = slot.fetch('id').tr('-', '_')
      slot.slice('id', 'order', 'title', 'kind', 'state', 'sha').merge(
        'entry' => "engine_#{key}/entry.rb",
        'moduleName' => slot['moduleName'] || slot.fetch('historical').fetch('isolated_module')
      )
    end
    File.write(File.join(lab, 'engines.json'), JSON.pretty_generate(runtime) + "\n", encoding: 'UTF-8')
    FileUtils.cp(File.join(TEMPLATES, 'master_menu.rb'), File.join(lab, 'master_menu.rb'))
    loader = <<~RUBY
      # frozen_string_literal: true
      require 'sketchup.rb'
      require 'extensions.rb'
      unless file_loaded?(__FILE__)
        extension = SketchupExtension.new('Sibambo BOM Engine Evolution', File.join(__dir__, 'evolution_lineup', 'master_menu.rb'))
        extension.description = 'Four historical BOM Engine generations; E4 is a current working-tree candidate, not certified.'
        extension.version = '2.0.0-candidate'
        extension.creator = 'Sibambo'
        Sketchup.register_extension(extension, true)
        file_loaded(__FILE__)
      end
    RUBY
    File.write(File.join(staging, 'sibambo_evolution_lineup_loader.rb'), loader, encoding: 'UTF-8')
  end
end

if $PROGRAM_NAME == __FILE__
  require 'optparse'
  options = {}
  OptionParser.new { |parser| parser.on('--output PATH') { |path| options[:output] = path } }.parse!
  raise ArgumentError, 'Pass --output with a new package directory' unless options[:output]
  puts JSON.pretty_generate(EvolutionLineupBuilder.build(output: options.fetch(:output)))
end
