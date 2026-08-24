# frozen_string_literal: true
# Entry point for [EXP-01] 2026-05-11 — Nano BBox JSON (SBE-2026.05.11-EXP)

module SibamboHistory
  EVOLUTION_LAB_EMBEDDED = true unless const_defined?(:EVOLUTION_LAB_EMBEDDED, false)

  module V20260511_EXP
    DISPLAY_VERSION = "SBE-2026.05.11-EXP"
    LABEL = "[EXP-01] 2026-05-11 — Nano BBox JSON"
    COMMIT_SHA = "7dd932dfe1b7eeb500e9d82e2d87fbe2275f56be"
    FORMAT_FAMILY = "bom_nano_json"
    EXPORT_KIND = :experimental
    PLUGIN_VERSION = "2.0.0" unless const_defined?(:PLUGIN_VERSION, false)

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

    require File.join(__dir__, 'evolution_cooperative_job.rb')
    install_batch_wrapper
  end

  def self.install_batch_wrapper
    return if @batch_wrapper_installed
    return unless defined?(Core) && Core.respond_to?(:run_export)

    original_run_export = Core.method(:run_export)
    job = EvolutionCooperativeJob
    label = LABEL
    Core.define_singleton_method(:run_export) do |settings|
      selected = settings.is_a?(Hash) ? settings.dup : {}
      batch_size = selected.fetch(:batch_size, 512).to_i
      batch_size = 512 if batch_size < 1
      job.start(title: label, batch_size: batch_size) do |progress|
        original_run_export.call(selected.merge(progress: progress, batch_size: batch_size))
      end
    end
    @batch_wrapper_installed = true
  end

  def self.launch(model = Sketchup.active_model)
    load_engine
    load_format_adapter
    UIDialog.show do |settings|
      export_current_model(model, settings)
    end
    rescue => e
      UI.messagebox("Error launching #{LABEL}:\n#{e.message}\n#{e.backtrace&.first}", MB_OK)
    end

    def self.load_format_adapter
      case EXPORT_KIND
      when :cleanpkg
        require File.join(__dir__, 'bom_engine', 'clean_analysis.rb')
      when :bomc_v1, :bomc_scene
        require File.join(__dir__, 'bom_engine', 'bomc_extension.rb')
      end
    end

    def self.export_current_model(model, settings)
      selected = settings.is_a?(Hash) ? settings.dup : {}
      batch_size = [selected.fetch(:batch_size, 512).to_i, 1].max
      case EXPORT_KIND
      when :legacy_json, :experimental
        Core.run_export(selected.merge(output_format: 'legacy', batch_size: batch_size))
      when :tiered_json
        Core.run_export(selected.merge(output_format: 'legacy', batch_size: batch_size))
      when :minified_visual_json
        Core.run_export(selected.merge(output_format: 'legacy', export_level: 'visual', pretty_print: false, batch_size: batch_size))
      when :canonical_v3
        Core.run_export(selected.merge(output_format: 'canonical_v3', compress_output: true, batch_size: batch_size))
      when :model_eval_json
        output = output_with_suffix(selected[:output_path], '_model-eval.json')
        run_direct_export(output, batch_size, 'Model-Eval JSON') do |progress|
          Core.export_model_eval_json(model, output, progress: progress, batch_size: batch_size)
        end
      when :bome2
        Core.run_export(selected.merge(output_format: 'bome2', compress_output: false, batch_size: batch_size))
      when :cleanpkg
        output = output_with_suffix(selected[:output_path], '.cleanpkg')
        run_direct_export(output, batch_size, 'CleanPKG') do |progress|
          CleanAnalysis::Exporter.export_package(
            model: model,
            roots: model.entities,
            parent_transform: Geom::Transformation.new,
            output_path: output,
            settings: { scope_mode: 'model' },
            progress: progress,
            batch_size: batch_size
          )
        end
      when :bomc_v1
        output = output_with_suffix(selected[:output_path], '.bomc')
        run_direct_export(output, batch_size, 'BOMC 1.0') do |progress|
          BOMCExtension.export(model, output_path: output, profile: BOMCExtension::DEFAULT_PROFILE, progress: progress, batch_size: batch_size)
        end
      when :bomc_scene
        output = output_with_suffix(selected[:output_path], '.bomc')
        processing = BOMCProcessing.settings(
          :custom,
          custom: { max_items: batch_size, max_items_limit: 8_192, min_items: 1, max_ms: 24.0 }
        )
        run_direct_export(output, batch_size, 'BOMC Scene/Page') do |progress|
          BOMCExtension.export(
            model,
            output_path: output,
            profile: BOMCExtension::DEFAULT_PROFILE,
            progress: progress,
            settings: processing
          )
        end
      else
        raise "Unsupported Evolution Lab export kind: #{EXPORT_KIND.inspect}"
      end
    end

    def self.run_direct_export(output, batch_size, format_name, &work)
      EvolutionCooperativeJob.start(title: LABEL, batch_size: batch_size) do |progress|
        result = work.call(progress)
        path = result.is_a?(Hash) ? (result[:path] || output) : output
        UI.messagebox("Export #{format_name} selesai!\n\nFile: #{path}", MB_OK)
        result
      end
    end

    def self.output_with_suffix(path, suffix)
      base = path.to_s.sub(/.(?:json|bome2|cleanpkg|bomc)(?:.gz)?z/i, '')
      base = base.sub(/_(?:bom|canonical|model-eval|runtime)z/i, '')
      "#{base}#{suffix}"
    end
  end
end
