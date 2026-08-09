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

      def export_model(model, output_path: nil, progress: nil, batch_size: 24)
        path = output_path || default_output_path(model.path)
        Exporter.export(
          model: model,
          roots: model.entities,
          parent_transform: Geom::Transformation.new,
          output_path: path,
          settings: { scope_mode: 'model' },
          progress: progress,
          batch_size: batch_size
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

        BatchOptions.show(profile: BatchOptions.device_profile) do |batch_size, mode|
          start_export(model, selected, batch_size, mode)
        end
      rescue StandardError => error
        UI.messagebox("Clean analysis export failed:\n#{error.message}")
        nil
      end

      def start_export(model, output_path, batch_size, mode = 'auto')
        ConversionJob.start(
          title: "BOM Engine Clean - #{mode} batch #{batch_size}",
          output_path: output_path,
          batch_size: batch_size
        ) do |progress|
          export_model(
            model,
            output_path: output_path,
            progress: progress,
            batch_size: batch_size
          )
        end
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
