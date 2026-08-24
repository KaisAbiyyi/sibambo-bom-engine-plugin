# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require 'open3'
begin
  require 'zip'
rescue LoadError
  # zip gem not present, will use PowerShell Compress-Archive
end

module EvolutionLabBuilder
  ROOT_DIR = File.expand_path('../..', __dir__)
  HISTORY_DIR = File.join(ROOT_DIR, 'history')
  GENERATED_DIR = File.join(HISTORY_DIR, 'generated')
  DIST_DIR = File.join(ROOT_DIR, 'dist', 'history')
  STANDALONE_DIR = File.join(DIST_DIR, 'standalone')
  MANIFEST_FILE = File.join(HISTORY_DIR, 'versions.json')
  EVOLUTION_LAB_VERSION = '1.1.3'.freeze

  def self.build
    puts "======================================================================"
    puts "  SIBAMBO BOM ENGINE — EVOLUTION LAB BUILDER"
    puts "======================================================================"

    raise "Manifest not found: #{MANIFEST_FILE}" unless File.exist?(MANIFEST_FILE)
    manifest = JSON.parse(File.read(MANIFEST_FILE))
    versions = manifest['versions']
    puts "Loaded #{versions.length} versions from manifest."

    FileUtils.mkdir_p(GENERATED_DIR)
    FileUtils.mkdir_p(STANDALONE_DIR)

    master_staging_dir = File.join(DIST_DIR, 'staging')
    FileUtils.rm_rf(master_staging_dir)
    FileUtils.mkdir_p(master_staging_dir)

    evolution_lab_dir = File.join(master_staging_dir, 'evolution_lab')
    FileUtils.mkdir_p(evolution_lab_dir)

    standalone_packages = []

    versions.each do |ver|
      seq = ver['sequence']
      disp = ver['display_version']
      sha = ver['commit_sha']
      label = ver['label']
      mod_name = ver['isolated_module'] # e.g. SibamboHistory::V20260511_01
      key = disp.gsub(/[^A-Za-z0-9_]/, '_')

      puts "\n----------------------------------------------------------------------"
      puts "[#{seq}/#{versions.length}] Processing #{disp}: #{label}"
      puts "Commit: #{sha}"

      ver_gen_dir = File.join(GENERATED_DIR, disp)
      raw_dir = File.join(ver_gen_dir, 'raw')
      staged_dir = File.join(ver_gen_dir, 'staged')

      FileUtils.rm_rf(ver_gen_dir)
      FileUtils.mkdir_p(raw_dir)
      FileUtils.mkdir_p(staged_dir)

      # 1. Extract files from Git
      extract_git_snapshot(sha, raw_dir, ver)

      # 2. Transform into isolated namespace
      transform_snapshot(raw_dir, staged_dir, ver, key, mod_name)

      # 2.5. Backport runtime-only responsiveness fixes. These do not change
      # historical schemas or output ordering; they only memoize pure counts
      # and add cooperative checkpoints used by the serial batch runner.
      apply_runtime_hardening(staged_dir, ver)

      # 3. Verify Ruby syntax
      syntax_ok = verify_ruby_syntax(staged_dir)
      raise "Syntax error in transformed Ruby files for #{disp}" unless syntax_ok

      # 4. Generate Origin and Transform Report
      generate_origin_md(ver_gen_dir, ver)
      generate_transform_report(ver_gen_dir, raw_dir, staged_dir, ver)

      # 5. Copy to Master Evolution Lab directory
      target_dir_in_master = File.join(evolution_lab_dir, "engine_#{key.downcase}")
      FileUtils.cp_r(staged_dir, target_dir_in_master)

      # 6. Package Standalone RBZ
      standalone_rbz = File.join(STANDALONE_DIR, "sibambo_bom_engine_#{key.downcase}.rbz")
      package_standalone_rbz(staged_dir, standalone_rbz, ver, key)
      standalone_packages << {
        version: ver,
        rbz_path: standalone_rbz,
        sha256: Digest::SHA256.file(standalone_rbz).hexdigest
      }
      puts "  -> Standalone RBZ: #{File.basename(standalone_rbz)}"
    end

    # 7. Create Master Evolution Lab Loader and Menu
    create_master_loader(master_staging_dir, evolution_lab_dir, versions)

    # 8. Package Master RBZ
    master_rbz = File.join(DIST_DIR, "sibambo_bom_engine_evolution_lab_v#{EVOLUTION_LAB_VERSION}.rbz")
    package_master_rbz(master_staging_dir, master_rbz)
    master_sha256 = Digest::SHA256.file(master_rbz).hexdigest
    puts "\n======================================================================"
    puts "  MASTER EVOLUTION LAB RBZ CREATED"
    puts "  Path:   #{master_rbz}"
    puts "  SHA256: #{master_sha256}"
    puts "======================================================================"

    # 9. Generate Checksums and Manifest Report
    generate_checksums_and_manifest_md(master_rbz, master_sha256, standalone_packages, versions)

    puts "\n[SUCCESS] Evolution Lab build completed cleanly!"
  end

  def self.extract_git_snapshot(sha, raw_dir, ver)
    temp_zip = File.join(raw_dir, 'temp_archive.zip')
    cmd = "git archive --format=zip #{sha} -o \"#{temp_zip}\""
    stdout, stderr, status = Open3.capture3(cmd, chdir: ROOT_DIR)
    unless status.success?
      raise "Failed to git archive #{sha}: #{stderr}"
    end

    # Unzip using PowerShell Expand-Archive (portable on Windows)
    ps_cmd = "powershell -NoProfile -Command \"Expand-Archive -Path '#{temp_zip}' -DestinationPath '#{raw_dir}' -Force\""
    stdout, stderr, status = Open3.capture3(ps_cmd)
    unless status.success?
      raise "Failed to unzip archive for #{sha}: #{stderr}"
    end
    FileUtils.rm_f(temp_zip)

    # If the commit had files under bom_engine_plugin/, move them to raw_dir root
    sub_plugin = File.join(raw_dir, 'bom_engine_plugin')
    if Dir.exist?(sub_plugin)
      FileUtils.cp_r(File.join(sub_plugin, '.'), raw_dir)
      FileUtils.rm_rf(sub_plugin)
    end
  end

  def self.transform_snapshot(raw_dir, staged_dir, ver, key, mod_name)
    mod_parts = mod_name.split('::')
    root_mod = mod_parts[0] # SibamboHistory
    sub_mod = mod_parts[1]  # V20260511_01

    tag_suffix = "__#{ver['display_version']}"

    # Determine files to copy
    # We copy bom_engine directory or clean_analysis directory and loaders
    source_items = Dir.glob(File.join(raw_dir, '*')).select { |f|
      bn = File.basename(f)
      bn =~ /\Abom_engine/ || bn =~ /\Aclean_analysis/ || bn =~ /\.rb\z/ || bn =~ /\Aui\z/ || bn =~ /\Aschema\z/
    }

    source_items.each do |item|
      dest = File.join(staged_dir, File.basename(item))
      if File.directory?(item)
        FileUtils.cp_r(item, dest)
      else
        FileUtils.cp(item, dest)
      end
    end

    # Transform all Ruby files in staged_dir
    ruby_files = Dir.glob(File.join(staged_dir, '**', '*.rb'))
    ruby_files.each do |rb_path|
      content = File.read(rb_path, encoding: 'UTF-8')
      orig = content.dup

      # 1. Namespace transformation
      # Replace "module BOMEngine" with "module #{root_mod}\n  module #{sub_mod}"
      content = content.gsub(/module\s+BOMEngine\b/, "module #{root_mod}\n  module #{sub_mod}")
      content = content.gsub(/\bBOMEngine::/, "#{mod_name}::")

      # Close outer module at EOF if we replaced module BOMEngine
      if orig =~ /module\s+BOMEngine\b/
        content << "\nend # #{root_mod}\n"
      end

      # 2. Settings namespace isolation
      content = content.gsub(/SETTINGS_KEY\s*=\s*["']([^"']+)["']/, "SETTINGS_KEY = \"Sibambo_History_#{key}_Settings\"")
      content = content.gsub(/Sketchup\.(read|write)_default\(["']BOMEngine_LastSettings["']/, "Sketchup.\\1_default(\"Sibambo_History_#{key}_Settings\"")

      # 3. Output collision prevention
      # Append version tag suffix to default output paths in UI/core
      content = content.gsub(/model\.path\.to_s\.empty\?\s*\?\s*['"]Untitled['"]\s*:\s*File\.basename\(model\.path,\s*File\.extname\(model\.path\)\)/,
        "((model.path.to_s.empty? ? 'Untitled' : File.basename(model.path, File.extname(model.path))) + '#{tag_suffix}')")

      content = content.gsub(/_bom\.json/, "#{tag_suffix}_bom.json")
      content = content.gsub(/_visual\.json/, "#{tag_suffix}_visual.json")
      content = content.gsub(/_standard\.json/, "#{tag_suffix}_standard.json")
      content = content.gsub(/_full\.json/, "#{tag_suffix}_full.json")
      content = content.gsub(/_nano\.json/, "#{tag_suffix}_nano.json")
      content = content.gsub(/_canonical\.json/, "#{tag_suffix}_canonical.json")
      content = content.gsub(/_model-eval\.json/, "#{tag_suffix}_model-eval.json")
      content = content.gsub(/_runtime\.bome2/, "#{tag_suffix}_runtime.bome2")
      content = content.gsub(/\.bomc/, "#{tag_suffix}.bomc")
      content = content.gsub(/\.cleanpkg/, "#{tag_suffix}.cleanpkg")

      # 4. Require relative adjustment
      content = content.gsub(/require_relative\s+['"]bom_engine\//, "require_relative '")
      content = content.gsub(/require\s+File\.join\(File\.dirname\(__FILE__\),\s*['"]bom_engine['"]/, "require File.join(File.dirname(__FILE__)")

      File.write(rb_path, content, encoding: 'UTF-8')
    end

    # Create isolated engine launcher inside staged_dir
    create_engine_entry_point(staged_dir, ver, key, mod_name)
  end

  def self.create_engine_entry_point(staged_dir, ver, key, mod_name)
    sub_mod = mod_name.split('::').last
    entry_file = File.join(staged_dir, "entry_#{key.downcase}.rb")
    code = <<~RUBY
      # frozen_string_literal: true
      # Entry point for #{ver['label']} (#{ver['display_version']})

      module SibamboHistory
        module #{sub_mod}
          DISPLAY_VERSION = #{ver['display_version'].inspect}
          LABEL = #{ver['label'].inspect}
          COMMIT_SHA = #{ver['commit_sha'].inspect}
          FORMAT_FAMILY = #{ver['format_family'].inspect}

          def self.load_engine
            # Load all sub-components relative to this directory
            loader_path = File.join(__dir__, 'bom_engine', 'core.rb')
            loader_path = File.join(__dir__, 'core.rb') unless File.exist?(loader_path)
            loader_path = File.join(__dir__, 'clean_analysis', 'exporter.rb') unless File.exist?(loader_path)

            if File.exist?(loader_path)
              require loader_path
            else
              # Fallback to loading all ruby files in directory
              Dir.glob(File.join(__dir__, '**', '*.rb')).each do |f|
                next if f == __FILE__
                require f
              end
            end
          end

          def self.launch(model = Sketchup.active_model)
            load_engine
      if defined?(Core) && Core.respond_to?(:export_with_dialog)
        Core.export_with_dialog
      elsif defined?(Core) && Core.respond_to?(:show_export_dialog)
              Core.show_export_dialog
            elsif defined?(Core) && Core.respond_to?(:export_from_ui)
              Core.export_from_ui
            elsif defined?(CleanAnalysis::Exporter) && CleanAnalysis::Exporter.respond_to?(:export_active_model)
              CleanAnalysis::Exporter.export_active_model
            elsif defined?(Core) && Core.respond_to?(:export_bomc)
              Core.export_bomc
            elsif defined?(Core) && Core.respond_to?(:export_canonical_v3)
              Core.export_canonical_v3
            elsif defined?(Core) && Core.respond_to?(:export_model_eval_json)
              output = Core.model_eval_output_path(model)
              Core.export_model_eval_json(model, output)
            elsif defined?(Core) && Core.respond_to?(:export_bome2)
              output = Core.bome2_output_path(model.path, false)
              Core.export_bome2(model, output, compress: false)
            else
              UI.messagebox("Engine initialized: \#{LABEL}\\nCommit: \#{COMMIT_SHA}", MB_OK)
            end
          rescue => e
            UI.messagebox("Error launching \#{LABEL}:\\n\#{e.message}\\n\#{e.backtrace&.first}", MB_OK)
          end
        end
      end
    RUBY
    File.write(entry_file, code, encoding: 'UTF-8')
  end

  def self.apply_runtime_hardening(staged_dir, ver)
    display = ver['display_version']
    if %w[SBE-2026.05.11-01 SBE-2026.05.11-02 SBE-2026.05.11-03].include?(display)
      harden_legacy_tree_exporter(staged_dir, display)
    elsif %w[SBE-2026.07.16-01 SBE-2026.07.16-02 SBE-2026.07.16-03 SBE-2026.08.13-01].include?(display)
      harden_canonical_exporter(staged_dir, display)
    end
    harden_windows_dialog_paths(staged_dir) if display.start_with?('SBE-2026.05.11-')
  end

  def self.replace_once!(content, before, after, path)
    raise "Hardening anchor not found in #{path}: #{before.lines.first.to_s.strip}" unless content.include?(before)

    content.sub!(before, after)
  end

  def self.harden_windows_dialog_paths(staged_dir)
    dialog_path = File.join(staged_dir, 'bom_engine', 'ui_dialog.rb')
    return unless File.file?(dialog_path)

    dialog = File.read(dialog_path, encoding: 'UTF-8')
    default_before = <<-'RUBY'.rstrip
        escaped = default_path.gsub("\\", "\\\\").gsub("'", "\\'")
        dialog.execute_script("setDefaultPath('#{escaped}')")
    RUBY
    default_after = <<-'RUBY'.rstrip
        dialog.execute_script("setDefaultPath(#{JSON.generate(default_path)})")
    RUBY
    browse_before = <<-'RUBY'.rstrip
          escaped = chosen.gsub("\\", "\\\\").gsub("'", "\\'")
          dialog.execute_script("setPath('#{escaped}')")
    RUBY
    browse_after = <<-'RUBY'.rstrip
          dialog.execute_script("setPath(#{JSON.generate(chosen)})")
    RUBY

    replace_once!(dialog, default_before, default_after, dialog_path)
    replace_once!(dialog, browse_before, browse_after, dialog_path)
    File.write(dialog_path, dialog, encoding: 'UTF-8')
  end

  def self.harden_legacy_tree_exporter(staged_dir, display)
    traversal_path = File.join(staged_dir, 'bom_engine', 'traversal.rb')
    core_path = File.join(staged_dir, 'bom_engine', 'core.rb')
    traversal = File.read(traversal_path, encoding: 'UTF-8')
    core = File.read(core_path, encoding: 'UTF-8')

    level_line = display == 'SBE-2026.05.11-01' ? '' : "      level         = opts.fetch(:export_level, \"full\")\n"
    anchor = "      include_edges = opts.fetch(:include_edges, Constants::INCLUDE_EDGES)\n#{level_line}"
    additions = <<~RUBY.gsub(/^/, '      ')
      progress      = opts[:progress]
      batch_size    = [opts.fetch(:batch_size, 64).to_i, 1].max
      work_state    = opts[:work_state] ||= { processed: 0 }
      face_cache    = opts[:face_count_cache] ||= {}
      edge_cache    = opts[:edge_count_cache] ||= {}
    RUBY
    replace_once!(traversal, anchor, anchor + additions, traversal_path)

    entity_anchor = "        next if entity.nil? || entity.deleted?\n"
    checkpoint = <<~RUBY.gsub(/^/, '        ')

      work_state[:processed] += 1
      if progress && (work_state[:processed] % batch_size).zero?
        progress.call(stage: 'Traversing legacy entity tree', processed: work_state[:processed])
      end
    RUBY
    replace_once!(traversal, entity_anchor, entity_anchor + checkpoint, traversal_path)

    if display == 'SBE-2026.05.11-01'
      replace_once!(
        traversal,
        "          face_count  = count_faces(defn.entities)\n          edge_count  = include_edges ? count_edges(defn.entities) : 0\n",
        "          cache_key   = defn.object_id\n          face_count  = face_cache.fetch(cache_key) { face_cache[cache_key] = count_faces(defn.entities) }\n          edge_count  = include_edges ? edge_cache.fetch(cache_key) { edge_cache[cache_key] = count_edges(defn.entities) } : 0\n",
        traversal_path
      )
      replace_once!(
        core,
        "        walk_opts = { include_edges: settings[:include_edges] }\n",
        "        walk_opts = { include_edges: settings[:include_edges], progress: settings[:progress], batch_size: settings[:batch_size] || 64 }\n",
        core_path
      )
    else
      replace_once!(
        traversal,
        "            h[:face_count]     = count_faces(defn.entities)\n",
        "            h[:face_count]     = face_cache.fetch(defn.object_id) { face_cache[defn.object_id] = count_faces(defn.entities) }\n",
        traversal_path
      )
      replace_once!(
        traversal,
        "            h[:edge_count]         = include_edges ? count_edges(defn.entities) : 0\n",
        "            h[:edge_count]         = include_edges ? edge_cache.fetch(defn.object_id) { edge_cache[defn.object_id] = count_edges(defn.entities) } : 0\n",
        traversal_path
      )
      replace_once!(
        core,
        "        walk_opts = { include_edges: settings[:include_edges], export_level: level }\n",
        "        walk_opts = { include_edges: settings[:include_edges], export_level: level, progress: settings[:progress], batch_size: settings[:batch_size] || 64 }\n",
        core_path
      )
    end

    traversal.gsub!('def self.count_faces(entities, depth = 0)', 'def self.count_faces(entities, depth = 0, memo = nil)')
    traversal.gsub!('def self.count_edges(entities, depth = 0)', 'def self.count_edges(entities, depth = 0, memo = nil)')
    traversal.gsub!(/(def self\.count_(?:faces|edges)\(entities, depth = 0, memo = nil\)\n      return 0 if depth > Constants::MAX_RECURSION_DEPTH\n)/, "\\1      memo ||= {}\n")
    traversal.gsub!(/when Sketchup::Group\s+then sum \+ count_(faces|edges)\(e\.entities, depth \+ 1\)/, 'when Sketchup::Group            then sum + count_\\1(e.entities, depth + 1, memo)')
    traversal.gsub!(/when Sketchup::ComponentInstance then sum \+ count_(faces|edges)\(e\.definition\.entities, depth \+ 1\)/) do
      kind = Regexp.last_match(1)
      "when Sketchup::ComponentInstance\n          key = [e.definition.object_id, depth + 1]\n          sum + memo.fetch(key) { memo[key] = count_#{kind}(e.definition.entities, depth + 1, memo) }"
    end

    traversal.gsub!(/[ \t]+$/, '')
    File.write(traversal_path, traversal, encoding: 'UTF-8')
    File.write(core_path, core, encoding: 'UTF-8')
  end

  def self.harden_canonical_exporter(staged_dir, display)
    builder_path = File.join(staged_dir, 'bom_engine', 'canonical_graph_builder.rb')
    builder = File.read(builder_path, encoding: 'UTF-8')
    replace_once!(builder, 'texture_writer: nil)', 'texture_writer: nil, progress: nil, batch_size: 32)', builder_path)
    replace_once!(builder, "        texture_writer: texture_writer\n", "        texture_writer: texture_writer,\n        progress: progress,\n        batch_size: batch_size\n", builder_path)
    replace_once!(builder, 'def initialize(model:, settings:, spatial:, texture_writer:)', 'def initialize(model:, settings:, spatial:, texture_writer:, progress: nil, batch_size: 32)', builder_path)
    replace_once!(builder, "        @skipped = Hash.new(0)\n", "        @skipped = Hash.new(0)\n        @progress = progress\n        @batch_size = [batch_size.to_i, 1].max\n        @work_count = 0\n", builder_path)
    replace_once!(builder, "        entities.each do |entity|\n          unless Traversal.exportable_entity?(entity)\n", "        entities.each do |entity|\n          checkpoint('Converting canonical entities')\n          unless Traversal.exportable_entity?(entity)\n", builder_path)
    each_entity_end = <<~RUBY.gsub(/^/, '      ')
      def each_entity(entities)
        entities.each do |entity|
          checkpoint('Converting canonical entities')
          unless Traversal.exportable_entity?(entity)
            @skipped['hidden_or_invalid_entity'] += 1
            next
          end
          yield entity
        end
      end
    RUBY
    checkpoint_method = <<~RUBY.gsub(/^/, '      ')

      def checkpoint(stage)
        return unless @progress

        @work_count += 1
        return unless (@work_count % @batch_size).zero?

        @progress.call(stage: stage, processed: @work_count)
      end
    RUBY
    replace_once!(builder, each_entity_end, each_entity_end + checkpoint_method, builder_path)
    builder.gsub!(/[ \t]+$/, '')
    File.write(builder_path, builder, encoding: 'UTF-8')

    return if display == 'SBE-2026.08.13-01'

    core_path = File.join(staged_dir, 'bom_engine', 'core.rb')
    core = File.read(core_path, encoding: 'UTF-8')
    core.gsub!('def self.export_model_eval_json(model, output_path)', 'def self.export_model_eval_json(model, output_path, progress: nil, batch_size: 32)')
    core.gsub!('graph = build_model_eval_graph(model)', 'graph = build_model_eval_graph(model, progress: progress, batch_size: batch_size)')
    core.gsub!('def self.build_model_eval_graph(model)', 'def self.build_model_eval_graph(model, progress: nil, batch_size: 32)')
    replace_once!(core, "        texture_writer: nil\n      )\n", "        texture_writer: nil,\n        progress: progress,\n        batch_size: batch_size\n      )\n", core_path)
    replace_once!(core, "        texture_writer: texture_writer\n      )\n", "        texture_writer: texture_writer,\n        progress: settings[:progress],\n        batch_size: settings[:batch_size] || 32\n      )\n", core_path)
    File.write(core_path, core, encoding: 'UTF-8')
  end

  def self.verify_ruby_syntax(staged_dir)
    all_ok = true
    ruby_files = Dir.glob(File.join(staged_dir, '**', '*.rb'))
    ruby_files.each do |rb_path|
      stdout, stderr, status = Open3.capture3("ruby -c \"#{rb_path}\"")
      rel = rb_path.sub(staged_dir, '')
      if status.success?
        # Syntax OK
      else
        puts "  [SYNTAX ERROR] #{rel}: #{stderr}"
        all_ok = false
      end
    end
    all_ok
  end

  def self.generate_origin_md(ver_gen_dir, ver)
    content = <<~MARKDOWN
      # Historical Origin & Attribution

      - **Version ID**: `#{ver['display_version']}`
      - **Label**: `#{ver['label']}`
      - **Date**: `#{ver['date']}`
      - **Source Repository**: [#{ver['source_repository']}](#{ver['source_repository']})
      - **Commit SHA**: `#{ver['commit_sha']}`
      - **Commit Message**: `#{ver['commit_message']}`
      - **Classification**: `#{ver['classification']}`
      - **License**: GNU General Public License v3.0 (GPL-3.0)

      ## Historical Intent
      #{ver['approximate_historical_intent']}

      ## Selection Reason
      #{ver['selection_reason']}
    MARKDOWN
    File.write(File.join(ver_gen_dir, 'ORIGIN.md'), content, encoding: 'UTF-8')
  end

  def self.generate_transform_report(ver_gen_dir, raw_dir, staged_dir, ver)
    content = <<~MARKDOWN
      # Transform Report — #{ver['display_version']}

      **Engine**: #{ver['label']}
      **Commit SHA**: `#{ver['commit_sha']}`
      **Isolated Module**: `#{ver['isolated_module']}`

      ## Applied Transformations
      1. **Namespace Isolation**:
         - Transformed top-level `module BOMEngine` to `#{ver['isolated_module']}`.
         - Transformed constant references `BOMEngine::` to `#{ver['isolated_module']}::`.
      2. **Settings Isolation**:
         - Replaced preference keys with `Sibambo_History_#{ver['display_version'].gsub(/[^A-Za-z0-9_]/, '_')}_Settings`.
      3. **Output Collision Prevention**:
         - Appended deterministic suffix `__#{ver['display_version']}` to default output basenames.
      4. **Preserved Geometry & Math Invariants**:
         - No vertex calculation, traversal algorithms, UV extraction, normal generation, or schema encoding logic was modified.
         - Syntax validation with `ruby -c`: **PASSED**.
    MARKDOWN
    File.write(File.join(ver_gen_dir, 'TRANSFORM_REPORT.md'), content, encoding: 'UTF-8')
  end

  def self.create_master_loader(master_staging_dir, evolution_lab_dir, versions)
    FileUtils.cp(
      File.join(ROOT_DIR, 'history', 'batch_runner.rb'),
      File.join(evolution_lab_dir, 'batch_runner.rb')
    )
    # 1. Write evolution_lab/master_menu.rb
    master_menu_file = File.join(evolution_lab_dir, 'master_menu.rb')
    menu_code = +<<~RUBY
      # frozen_string_literal: true
      # Sibambo BOM Engine Evolution Lab — Master Menu Controller

      module SibamboHistory
        module EvolutionLab
          MENU_TITLE = 'Sibambo BOM Engine Evolution Lab'

          CURRENT_MODEL_EXPORTERS = {
    RUBY

    versions.each do |ver|
      format_id = ver['label'][/\A\[(\d{2})\]/, 1]
      next if format_id.nil?

      key = ver['display_version'].gsub(/[^A-Za-z0-9_]/, '_').downcase
      menu_code << <<~RUBY
            #{format_id.inspect} => {
              entry: #{"engine_#{key}/entry_#{key}.rb".inspect},
              module_name: #{ver['isolated_module'].inspect}
            },
      RUBY
    end

    menu_code << <<~RUBY
          }.freeze

          def self.export_current_model(format_id, model = Sketchup.active_model)
            exporter = CURRENT_MODEL_EXPORTERS.fetch(format_id.to_s.rjust(2, '0'))
            entry = File.join(__dir__, exporter.fetch(:entry))
            raise "Historical exporter entry missing: \#{entry}" unless File.file?(entry)

            require entry
            target = exporter.fetch(:module_name).split('::').reject(&:empty?).inject(Object) do |scope, name|
              scope.const_get(name)
            end
            target.launch(model)
          rescue StandardError => error
            UI.messagebox("Current-model export [\#{format_id}] gagal:\n\#{error.message}", MB_OK)
          end

          def self.init_menus
            return if @menus_initialized
            @menus_initialized = true

            ext_menu = UI.menu('Extensions')
            lab_menu = ext_menu.add_submenu(MENU_TITLE)

            major_submenu = lab_menu.add_submenu('Major & Release Versions')
            exp_submenu = lab_menu.add_submenu('Experiments')

            # Chronological insertion (TOP = OLDEST, BOTTOM = NEWEST)
    RUBY

    versions.each do |ver|
      key = ver['display_version'].gsub(/[^A-Za-z0-9_]/, '_')
      target_sub = ver['classification'] == 'EXPERIMENT' ? 'exp_submenu' : 'major_submenu'
      format_id = ver['label'][/\A\[(\d{2})\]/, 1]
      if format_id
        menu_code << <<~RUBY
              #{target_sub}.add_item(#{ver['label'].inspect}) do
                SibamboHistory::EvolutionLab.export_current_model(#{format_id.inspect}, Sketchup.active_model)
              end
        RUBY
      else
        menu_code << <<~RUBY
              #{target_sub}.add_item(#{ver['label'].inspect}) do
                entry = File.join(__dir__, 'engine_#{key.downcase}', 'entry_#{key.downcase}.rb')
                require entry if File.exist?(entry)
                #{ver['isolated_module']}.launch(Sketchup.active_model)
              end
        RUBY
      end
    end

    menu_code << <<~RUBY

            lab_menu.add_separator
            lab_menu.add_item('Batch Export RUMAH + SBOOST ([01] to [09])') do
              require File.join(__dir__, 'batch_runner.rb')
              SibamboHistory::EvolutionLab::BatchRunner.start_or_resume
            end
            lab_menu.add_item('About Evolution Lab') do
              UI.messagebox(
                "Sibambo BOM Engine Evolution Lab\\n\\n" +
                "Side-by-side historical exporter suite spanning 2026-05-11 to 2026-08-19.\\n" +
                "Total historical engines: #{versions.length}\\n\\n" +
                "Preserved for reproducible format archaeology and benchmark analysis.",
                MB_OK
              )
            end
          end
        end
      end

      SibamboHistory::EvolutionLab.init_menus
      require File.join(__dir__, 'batch_runner.rb')
      SibamboHistory::EvolutionLab::BatchRunner.resume_if_pending
    RUBY
    File.write(master_menu_file, menu_code, encoding: 'UTF-8')

    # 2. Write top-level loader: sibambo_evolution_lab_loader.rb
    master_loader_file = File.join(master_staging_dir, 'sibambo_evolution_lab_loader.rb')
    loader_code = <<~RUBY
      # frozen_string_literal: true
      # Copyright (c) 2026 Sibambo. All rights reserved.
      # GNU General Public License v3.0

      require 'sketchup.rb'
      require 'extensions.rb'

      module SibamboHistory
        module EvolutionLab
          PLUGIN_ID = 'sibambo_bom_engine_evolution_lab'
          PLUGIN_NAME = 'Sibambo BOM Engine Evolution Lab'
          PLUGIN_VERSION = '#{EVOLUTION_LAB_VERSION}'

          unless file_loaded?(__FILE__)
            ex = SketchupExtension.new(PLUGIN_NAME, File.join(__dir__, 'evolution_lab', 'master_menu.rb'))
            ex.description = 'Comprehensive historical baseline and side-by-side runner for all Sibambo BOM Engine exporter generations (2026-05-11 to 2026-08-19).'
            ex.version = PLUGIN_VERSION
            ex.creator = 'Sibambo Research / Ridwan Ilyas & Kais Abiyyi'
            ex.copyright = '2026 Sibambo'
            Sketchup.register_extension(ex, true)
            file_loaded(__FILE__)
          end
        end
      end
    RUBY
    File.write(master_loader_file, loader_code, encoding: 'UTF-8')
  end

  def self.package_standalone_rbz(staged_dir, rbz_path, ver, key)
    FileUtils.rm_f(rbz_path)
    temp_zip_dir = File.join(File.dirname(rbz_path), "temp_#{key}")
    FileUtils.rm_rf(temp_zip_dir)
    FileUtils.mkdir_p(temp_zip_dir)

    standalone_loader_name = "sibambo_bom_engine_#{key.downcase}_loader.rb"
    standalone_folder_name = "sibambo_bom_engine_#{key.downcase}"
    isolated_submodule = ver['isolated_module'].split('::').last

    FileUtils.cp_r(staged_dir, File.join(temp_zip_dir, standalone_folder_name))

    loader_code = <<~RUBY
      # frozen_string_literal: true
      require 'sketchup.rb'
      require 'extensions.rb'

      module SibamboHistory
        module #{isolated_submodule}
          PLUGIN_ID = 'sibambo_bom_engine_#{key.downcase}'
          PLUGIN_NAME = 'Sibambo BOM Engine — #{ver['label']}'
          PLUGIN_VERSION = '1.0.0'

          unless file_loaded?(__FILE__)
            entry_point = File.join(__dir__, '#{standalone_folder_name}', 'entry_#{key.downcase}.rb')
            ex = SketchupExtension.new(PLUGIN_NAME, entry_point)
            ex.description = 'Standalone historical snapshot of #{ver['label']} (Commit #{ver['commit_sha'][0..7]}).'
            ex.version = PLUGIN_VERSION
            ex.creator = 'Sibambo Research'
            ex.copyright = '2026 Sibambo'
            Sketchup.register_extension(ex, true)

            UI.menu('Extensions').add_item(PLUGIN_NAME) do
              require entry_point
              SibamboHistory::#{isolated_submodule}.launch(Sketchup.active_model)
            end

            file_loaded(__FILE__)
          end
        end
      end
    RUBY
    File.write(File.join(temp_zip_dir, standalone_loader_name), loader_code, encoding: 'UTF-8')

    zip_folder(temp_zip_dir, rbz_path)
    FileUtils.rm_rf(temp_zip_dir)
  end

  def self.package_master_rbz(master_staging_dir, master_rbz)
    FileUtils.rm_f(master_rbz)
    zip_folder(master_staging_dir, master_rbz)
  end

  def self.zip_folder(folder_path, zip_file_path)
    temp_zip = zip_file_path.sub(/\.rbz\z/i, '.zip')
    temp_zip += '.tmp.zip' if temp_zip == zip_file_path
    FileUtils.rm_f(temp_zip)
    FileUtils.rm_f(zip_file_path)

    ps_cmd = "powershell -NoProfile -Command \"Compress-Archive -Path '#{folder_path}\\*' -DestinationPath '#{temp_zip}' -Force\""
    stdout, stderr, status = Open3.capture3(ps_cmd)
    unless status.success?
      raise "Failed to compress #{temp_zip}: #{stderr}"
    end

    FileUtils.mv(temp_zip, zip_file_path)
  end

  def self.generate_checksums_and_manifest_md(master_rbz, master_sha256, standalone_packages, versions)
    # Checksums file
    checksums_file = File.join(DIST_DIR, 'CHECKSUMS.sha256')
    lines = ["#{master_sha256}  #{File.basename(master_rbz)}"]
    standalone_packages.each do |pkg|
      lines << "#{pkg[:sha256]}  standalone/#{File.basename(pkg[:rbz_path])}"
    end
    File.write(checksums_file, lines.join("\n") + "\n", encoding: 'UTF-8')

    # Manifest MD
    manifest_md_file = File.join(DIST_DIR, 'MANIFEST.md')
    md = +<<~MARKDOWN
      # Sibambo BOM Engine Evolution Lab — Package Manifest

      **Generated At**: `2026-08-19`
      **Master RBZ**: [`#{File.basename(master_rbz)}`](file:///#{master_rbz.gsub('\\', '/')})
      **Master SHA256**: `#{master_sha256}`

      ## Historical Milestone Catalog (Oldest → Newest)

      | Seq | Date | Label | Repository | Commit | Format | Ext | Compression | Class | Standalone RBZ | SHA256 (first 12) |
      | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
    MARKDOWN

    standalone_packages.each do |pkg|
      ver = pkg[:version]
      repo_short = ver['source_repository'].include?('rdwnilyas-coder') ? 'rdwnilyas-coder' : 'KaisAbiyyi'
      rbz_name = File.basename(pkg[:rbz_path])
      md << "| #{ver['sequence']} | #{ver['date'][0..9]} | #{ver['label']} | #{repo_short} | `#{ver['commit_sha'][0..7]}` | `#{ver['format_family']}` | `#{ver['output_extensions'].join(', ')}` | `#{ver['compression']}` | `#{ver['classification']}` | `#{rbz_name}` | `#{pkg[:sha256][0..11]}` |\n"
    end

    File.write(manifest_md_file, md, encoding: 'UTF-8')
  end
end

if __FILE__ == $PROGRAM_NAME
  EvolutionLabBuilder.build
end
