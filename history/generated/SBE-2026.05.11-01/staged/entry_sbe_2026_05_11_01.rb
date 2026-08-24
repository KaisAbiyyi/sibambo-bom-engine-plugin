# frozen_string_literal: true
# Entry point for [01] 2026-05-11 — Original BOM JSON (SBE-2026.05.11-01)

module SibamboHistory
  module V20260511_01
    DISPLAY_VERSION = "SBE-2026.05.11-01"
    LABEL = "[01] 2026-05-11 — Original BOM JSON"
    COMMIT_SHA = "a6bf3f638e387f52a6e32bf4aea7f635b9ad2225"
    FORMAT_FAMILY = "bom_json_v2"
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
        UI.messagebox("Engine initialized: #{LABEL}\nCommit: #{COMMIT_SHA}", MB_OK)
      end
    rescue => e
      UI.messagebox("Error launching #{LABEL}:\n#{e.message}\n#{e.backtrace&.first}", MB_OK)
    end
  end
end
