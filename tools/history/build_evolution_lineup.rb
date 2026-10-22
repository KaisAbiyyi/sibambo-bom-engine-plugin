# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative 'build_evolution_lab' unless defined?(EvolutionLabBuilder)
require_relative 'build_adaptive_preview_kit'
require_relative '../../bom_engine/evolution_export_policy'

module EvolutionLineupBuilder
  ROOT = File.expand_path('../..', __dir__)
  LINEUP = File.join(ROOT, 'history', 'evolution-lineup.json')
  HISTORY = File.join(ROOT, 'history', 'versions.json')
  TEMPLATES = File.join(__dir__, 'evolution_lineup')
  E4_BASE = 'bd6782691ef8ba98f9d3baab698bc1cd961ce393'
  SLOT_KINDS = {
    'e2-canonical-gzip' => 'canonical_v3',
    'e3-cleanpkg' => 'cleanpkg',
    'e4-bomc' => 'bomc_three_profile'
  }.freeze
  ENGINES = { 'e2-canonical-gzip' => 'e2', 'e3-cleanpkg' => 'e3', 'e4-bomc' => 'e4' }.freeze
  ORDERS = { 'e2-canonical-gzip' => 2, 'e3-cleanpkg' => 3, 'e4-bomc' => 4 }.freeze
  PROFILES = BOMEngine::EvolutionExportPolicy::PROFILES.map(&:to_s).freeze

  def self.load_slots
    data = JSON.parse(File.read(LINEUP))
    raise 'Unsupported Evolution lineup schema' unless data['schemaVersion'] == 'sibambo-evolution-lineup-v3'
    slots = data.fetch('slots')
    raise 'Evolution requires E2/E3/E4 in historical slot order' unless slots.is_a?(Array) && slots.map { |slot| slot['id'] } == ENGINES.keys
    history = JSON.parse(File.read(HISTORY)).fetch('versions').map { |version| [version.fetch('display_version'), version] }.to_h
    slots.each do |slot|
      id = slot.fetch('id')
      raise 'Evolution engine order or kind is invalid' unless slot['order'] == ORDERS[id] && SLOT_KINDS[id] == slot['kind'] && ENGINES[id] == slot['engine']
      raise 'Evolution engine title missing' if slot['title'].to_s.strip.empty?
      raise 'Evolution active slots must use the current working tree' unless slot['source'] == 'working-tree'
      raise 'Evolution profiles must be Exact/Visual' unless slot['profiles'] == PROFILES
      raise 'Do not claim an uncertified engine is ready' unless %w[uncertified development].include?(slot['state'])
      if slot['engine'] != 'e4'
        historical = history.fetch(slot.fetch('historyVersion'))
        raise 'Historical format does not match Evolution baseline' unless EvolutionLabBuilder.historical_export_kind(historical).to_s == slot['kind']
        slot['historical'] = historical
        slot['historicalBaselineSha'] = historical.fetch('commit_sha')
      else
        raise 'E4 base producer identity changed' unless slot['baseProducerSha'] == E4_BASE
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

    staging = File.join(output, 'staging')
    lab = File.join(staging, 'evolution_lineup')
    FileUtils.mkdir_p(lab)
    source_tree_sha, namespace = stage_shared_runtime(lab)
    slots.each { |slot| slot['sha'] = source_tree_sha }
    stage_slot_wrappers(slots, lab, namespace, source_tree_sha)
    write_menu(staging, lab, slots)
    FileUtils.cp(File.join(TEMPLATES, 'lineup_dialog.rb'), File.join(lab, 'lineup_dialog.rb'))
    FileUtils.cp(File.join(TEMPLATES, 'lineup_dialog.html'), File.join(lab, 'lineup_dialog.html'))
    FileUtils.cp(File.join(ROOT, 'bom_engine', 'ui', 'bomc_theme.css'), File.join(lab, 'bomc_theme.css'))
    raise 'Evolution lineup Ruby syntax failed' unless EvolutionLabBuilder.verify_ruby_syntax(staging)

    rbz = File.join(output, 'sibambo_bom_engine_evolution_lineup.rbz')
    EvolutionLabBuilder.zip_folder(staging, rbz)
    manifest = {
      'schemaVersion' => 'sibambo-evolution-lineup-package-v3',
      'certified' => false,
      'status' => 'candidate_pending_cross_model_validation',
      'selectionBasis' => JSON.parse(File.read(LINEUP)).fetch('selectionBasis'),
      'e4BaseProducerSha' => E4_BASE,
      'sharedSourceTreeSha256' => source_tree_sha,
      'e4SourceTreeSha256' => source_tree_sha,
      'engines' => slots.map do |slot|
        slot.slice('id', 'engine', 'order', 'title', 'kind', 'formatVersion', 'state', 'sha', 'historyVersion', 'historicalBaselineSha', 'profiles', 'reason')
      end,
      'package' => File.basename(rbz),
      'packageSha256' => Digest::SHA256.file(rbz).hexdigest
    }
    manifest_path = File.join(output, 'manifest.json')
    File.write(manifest_path, JSON.pretty_generate(manifest) + "\n", encoding: 'UTF-8')
    { rbz: rbz, manifest: manifest_path, staging: staging, source_tree_sha256: source_tree_sha }
  end

  def self.verify_e4_ancestry!
    _out, error, status = Open3.capture3('git', 'merge-base', '--is-ancestor', E4_BASE, 'HEAD', chdir: ROOT)
    raise "Current E4 checkout is not descended from #{E4_BASE}: #{error}" unless status.success?
  end

  # Retained only for archived tests/tools that explicitly call the historical staging helper.
  # Package v2 does not invoke it for active E1-E3 slots.
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
    raise "Historical stage failed Ruby syntax: #{key}" unless EvolutionLabBuilder.verify_ruby_syntax(staged)
    destination = File.join(lab, "engine_#{key}")
    FileUtils.cp_r(staged, destination)
  end

  def self.stage_shared_runtime(lab)
    files = AdaptivePreviewKit.runtime_files(ROOT)
    source_sha = AdaptivePreviewKit.inventory_digest(files)
    namespace = "EvolutionShared_#{source_sha[0, 12]}"
    directory = File.join(lab, 'runtime')
    files.each do |relative, expected|
      bytes = File.binread(File.join(ROOT, relative))
      raise "Evolution source changed during build: #{relative}" unless Digest::SHA256.hexdigest(bytes) == expected
      bytes = AdaptivePreviewKit.transform(bytes.force_encoding('UTF-8'), namespace) if relative.end_with?('.rb')
      destination = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, bytes)
    end
    File.write(File.join(directory, 'bom_engine', 'BUILD_SHA.txt'), "#{source_sha}\n", encoding: 'UTF-8')
    File.write(File.join(directory, 'entry.rb'), <<~RUBY, encoding: 'UTF-8')
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
    [source_sha, namespace]
  end

  def self.stage_slot_wrappers(slots, lab, namespace, source_sha)
    slots.each do |slot|
      key = slot.fetch('id').tr('-', '_')
      directory = File.join(lab, "engine_#{key}")
      FileUtils.mkdir_p(directory)
      module_name = "EvolutionSlot_#{slot.fetch('engine').upcase}"
      engine = slot.fetch('engine')
      historical = slot['historicalBaselineSha']
      body = <<~RUBY
        # frozen_string_literal: true
        require_relative '../runtime/entry'
        module SibamboHistory
          module #{module_name}
            SOURCE_TREE_SHA256 = #{source_sha.inspect}.freeze
            ENGINE = #{engine.inspect}.freeze
            HISTORICAL_BASELINE_SHA = #{historical.inspect}.freeze
            def self.load_engine
              SibamboHistory::#{namespace}.load_engine
            end
            def self.normalize_output_path(path, profile)
              load_engine::EvolutionExporter.normalize_output_path(path, engine: ENGINE, profile: profile)
            end
            def self.export_current_model(model, settings)
              runtime = load_engine
              batch_mode = settings.fetch(:batch_mode, 'manual')
              processing = runtime::BOMCProcessing.from_ui(batch_mode: batch_mode, batch_size: settings[:batch_size])
              all = settings.fetch(:profile) == :all
              runtime::ConversionJob.start(
                title: "Sibambo Evolution — \#{ENGINE.upcase} \#{settings.fetch(:profile).to_s.upcase}",
                output_path: settings.fetch(:output_path),
                batch_size: processing[:max_items],
                kind: all ? :batch_export : :export
              ) do |progress|
                if all
                  runtime::EvolutionExporter.export_all_profiles(
                    model, engine: ENGINE, output_base_path: settings.fetch(:output_path),
                    processing: processing, progress: progress, active_model: -> { Sketchup.active_model }
                  )
                else
                  runtime::EvolutionExporter.export(
                    model, engine: ENGINE, profile: settings.fetch(:profile), output_path: settings.fetch(:output_path),
                    processing: processing, progress: progress, active_model: -> { Sketchup.active_model }
                  )
                end
              end
            end
          end
        end
      RUBY
      File.write(File.join(directory, 'entry.rb'), body, encoding: 'UTF-8')
      if engine == 'e4'
        marker = File.join(directory, 'bom_engine')
        FileUtils.mkdir_p(marker)
        File.write(File.join(marker, 'BUILD_SHA.txt'), "#{source_sha}\n", encoding: 'UTF-8')
      end
      slot['moduleName'] = "SibamboHistory::#{module_name}"
    end
  end

  def self.write_menu(staging, lab, slots)
    runtime = slots.map do |slot|
      key = slot.fetch('id').tr('-', '_')
      slot.slice('id', 'engine', 'order', 'title', 'kind', 'formatVersion', 'state', 'sha', 'historicalBaselineSha', 'profiles').merge(
        'entry' => "engine_#{key}/entry.rb",
        'moduleName' => slot.fetch('moduleName')
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
        extension.description = 'Three active Evolution formats on one current capture runtime; candidate only, not certified.'
        extension.version = '3.1.0-candidate'
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
