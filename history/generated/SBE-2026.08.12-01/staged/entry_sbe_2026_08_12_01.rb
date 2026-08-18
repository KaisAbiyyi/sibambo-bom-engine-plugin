# frozen_string_literal: true
# Entry point for [07] 2026-08-12 — CleanPKG Binary Container (SBE-2026.08.12-01)

module SibamboHistory
  module VSBE_2026_08_12_01
    DISPLAY_VERSION = "SBE-2026.08.12-01"
    LABEL = "[07] 2026-08-12 — CleanPKG Binary Container"
    COMMIT_SHA = "d245b6873a992c87f7647c6b816c13e6ab7815e0"
    FORMAT_FAMILY = "clean_package_v1"

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
      if defined?(Core) && Core.respond_to?(:show_export_dialog)
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
