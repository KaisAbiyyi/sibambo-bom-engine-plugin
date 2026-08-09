# frozen_string_literal: true

module BOMEngine
  module CleanAnalysis
    module SketchupExtension
      DISPLAY_NAME = 'BOM Engine Clean Analysis (Experimental)'.freeze

      module_function

      def default_output_path(model_path)
        source_path = model_path.to_s
        if source_path.empty?
          profile = ENV['USERPROFILE'].to_s
          profile = Dir.home if profile.empty?
          directory = File.join(profile, 'Documents', 'BOMEngineExports')
          base_name = 'Untitled'
        else
          directory = File.join(File.dirname(source_path), 'clean-analysis-exports')
          base_name = File.basename(source_path, File.extname(source_path))
        end
        File.join(directory, "#{base_name}_clean.json")
      end

      def export_model(model, output_path: nil)
        path = output_path || default_output_path(model.path)
        Exporter.export(
          model: model,
          roots: model.entities,
          parent_transform: Geom::Transformation.new,
          output_path: path,
          settings: { scope_mode: 'model' }
        )
      end

      def prompt_and_export
        model = Sketchup.active_model
        return UI.messagebox('No active SketchUp model is available.') if model.nil?

        suggested = default_output_path(model.path)
        selected = UI.savepanel(
          'Export Clean Analysis JSON',
          File.dirname(suggested),
          File.basename(suggested)
        )
        return nil if selected.nil?

        result = export_model(model, output_path: selected)
        counts = result.fetch(:counts)
        UI.messagebox(
          "Clean analysis export complete.\n\n" \
          "File: #{result.fetch(:path)}\n" \
          "Surfaces: #{counts.fetch('architectural_surface_count')}\n" \
          "Components: #{counts.fetch('component_count')}\n" \
          "Excluded objects: #{counts.fetch('excluded_object_count')}"
        )
        result
      rescue StandardError => error
        UI.messagebox("Clean analysis export failed:\n#{error.message}")
        nil
      end

      def register!
        return if @registered

        menu = UI.menu('Plugins').add_submenu(DISPLAY_NAME)
        menu.add_item('Export Clean Analysis JSON...') { prompt_and_export }
        @registered = true
      end
    end
  end
end
