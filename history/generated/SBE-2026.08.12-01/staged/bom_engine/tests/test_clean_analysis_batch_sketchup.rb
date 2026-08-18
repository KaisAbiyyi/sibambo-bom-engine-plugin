# frozen_string_literal: true

# Automated SketchUp-host smoke harness. Set these before launching SketchUp:
#   BOM_ENGINE_CLEAN_PLUGIN_ROOT
#   BOM_ENGINE_CLEAN_BATCH_MODEL
#   BOM_ENGINE_CLEAN_BATCH_OUTPUT
#   BOM_ENGINE_CLEAN_BATCH_MARKER

require 'json'

plugin_root = ENV.fetch('BOM_ENGINE_CLEAN_PLUGIN_ROOT')
require File.join(plugin_root, 'bom_engine_clean', 'clean_analysis')

module SibamboHistory
  module V20260812_01
  module Tests
    module CleanAnalysisBatchSketchupTest
      module_function

      def run
        model_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_BATCH_MODEL'))
        output_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_BATCH_OUTPUT'))
        marker_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_BATCH_MARKER'))
        model = Sketchup.active_model
        unless File.expand_path(model.path.to_s).casecmp?(model_path)
          raise "wrong active model: #{model.path.inspect}"
        end

        job = SibamboHistory::V20260812_01::CleanAnalysis::SketchupExtension.start_export(
          model,
          output_path,
          8,
          'smoke'
        )
        monitor_id = UI.start_timer(0.05, true) do
          next if job.running?

          UI.stop_timer(monitor_id)
          payload = JSON.parse(File.binread(output_path))
          unless payload.dig('format', 'identifier') == 'bom_engine_clean_v1'
            raise 'batch smoke output has the wrong format'
          end
          write_marker(
            marker_path,
            status: 'passed',
            batch_size: 8,
            bytes: File.size(output_path),
            surface_count: payload.fetch('surfaces').length
          )
          UI.start_timer(0.5, false) { Sketchup.quit }
        rescue StandardError => error
          UI.stop_timer(monitor_id)
          write_failure(marker_path, error)
          UI.start_timer(0.5, false) { Sketchup.quit }
        end
      rescue StandardError => error
        marker_path ||= ENV['BOM_ENGINE_CLEAN_BATCH_MARKER']
        write_failure(marker_path, error) if marker_path
        UI.start_timer(0.5, false) { Sketchup.quit }
      end

      def write_marker(path, values)
        File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(values) + "\n") }
      end
      private_class_method :write_marker

      def write_failure(path, error)
        write_marker(
          path,
          status: 'failed',
          error_class: error.class.name,
          error: error.message,
          backtrace: Array(error.backtrace).first(12)
        )
      end
      private_class_method :write_failure
    end
  end
end

UI.start_timer(2.0, false) { SibamboHistory::V20260812_01::Tests::CleanAnalysisBatchSketchupTest.run }

end # SibamboHistory
