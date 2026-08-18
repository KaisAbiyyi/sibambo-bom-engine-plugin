# frozen_string_literal: true

module SibamboHistory
  module V20260812_01
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

      def default_visual_output_path(model_path)
        default_output_path(model_path).sub(/_clean\.json\z/, '_clean_visual.zip')
      end

      def default_package_output_path(model_path)
        default_output_path(model_path).sub(/_clean\.json\z/, '__SBE-2026.08.12-01.cleanpkg')
      end

      def export_model(model, output_path: nil, progress: nil, batch_size: 24,
                       pretty_print: false)
        path = output_path || default_output_path(model.path)
        Exporter.export(
          model: model,
          roots: model.entities,
          parent_transform: Geom::Transformation.new,
          output_path: path,
          settings: { scope_mode: 'model' },
          progress: progress,
          batch_size: batch_size,
          pretty_print: pretty_print
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

        BatchOptions.show(profile: BatchOptions.device_profile) do |batch_size, mode, pretty_print|
          start_export(model, selected, batch_size, mode, pretty_print)
        end
      rescue StandardError => error
        UI.messagebox("Clean analysis export failed:\n#{error.message}")
        nil
      end

      def prompt_and_export_visual
        model = Sketchup.active_model
        return UI.messagebox('No active SketchUp model is available.') if model.nil?

        suggested = default_visual_output_path(model.path)
        selected = UI.savepanel(
          'Export Clean Visual Package',
          File.dirname(suggested),
          File.basename(suggested)
        )
        return nil if selected.nil?

        BatchOptions.show(profile: BatchOptions.device_profile) do |batch_size, mode, _pretty_print|
          start_visual_export(model, selected, batch_size, mode)
        end
      rescue StandardError => error
        UI.messagebox("Clean visual export failed:\n#{error.message}")
        nil
      end

      def prompt_and_export_package
        model = Sketchup.active_model
        return UI.messagebox('No active SketchUp model is available.') if model.nil?

        suggested = default_package_output_path(model.path)
        selected = UI.savepanel(
          'Export Optimized Clean Package',
          File.dirname(suggested),
          File.basename(suggested)
        )
        return nil if selected.nil?

        BatchOptions.show(profile: BatchOptions.device_profile) do |batch_size, mode, _pretty_print|
          start_package_export(model, selected, batch_size, mode)
        end
      rescue StandardError => error
        UI.messagebox("Optimized clean package export failed:\n#{error.message}")
        nil
      end

      def start_package_export(model, output_path, batch_size, mode = 'auto')
        ConversionJob.start(
          title: "BOM Engine Clean Package - #{mode} batch #{batch_size}",
          output_path: output_path,
          batch_size: batch_size
        ) do |progress|
          Exporter.export_package(
            model: model,
            roots: model.entities,
            parent_transform: Geom::Transformation.new,
            output_path: output_path,
            settings: { scope_mode: 'model' },
            progress: progress,
            batch_size: batch_size
          )
        end
      end

      def start_visual_export(model, output_path, batch_size, mode = 'auto')
        ConversionJob.start(
          title: "BOM Engine Clean Visual - #{mode} batch #{batch_size}",
          output_path: output_path,
          batch_size: batch_size
        ) do |progress|
          Exporter.export_visual(
            model: model,
            roots: model.entities,
            parent_transform: Geom::Transformation.new,
            output_path: output_path,
            settings: { scope_mode: 'model' },
            progress: progress,
            batch_size: batch_size
          )
        end
      end

      def start_export(model, output_path, batch_size, mode = 'auto', pretty_print = false)
        ConversionJob.start(
          title: "BOM Engine Clean - #{mode} batch #{batch_size}",
          output_path: output_path,
          batch_size: batch_size
        ) do |progress|
          export_model(
            model,
            output_path: output_path,
            progress: progress,
            batch_size: batch_size,
            pretty_print: pretty_print
          )
        end
      end

      def register!
        return if @registered

        menu = UI.menu('Plugins').add_submenu(DISPLAY_NAME)
        menu.add_item('Export Clean Analysis JSON...') { prompt_and_export }
        menu.add_item('Export Clean Visual Package...') { prompt_and_export_visual }
        menu.add_item('Export Optimized Clean Package (__SBE-2026.08.12-01.cleanpkg)...') { prompt_and_export_package }
        menu.add_item('Development Build Info') { puts BuildInfo.diagnostic }
        puts BuildInfo.diagnostic
        @registered = true
      end
    end
  end
end

end # SibamboHistory
