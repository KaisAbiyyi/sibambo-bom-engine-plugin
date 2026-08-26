# frozen_string_literal: true

# SketchUp-host profiling harness. Required environment variables:
#   BOM_ENGINE_CLEAN_PLUGIN_ROOT
#   BOM_ENGINE_CLEAN_PROFILE_MODEL
#   BOM_ENGINE_CLEAN_PROFILE_OUTPUT
#   BOM_ENGINE_CLEAN_PROFILE_REPORT
#   BOM_ENGINE_CLEAN_PROFILE_MARKER

require 'json'

plugin_root = ENV.fetch('BOM_ENGINE_CLEAN_PLUGIN_ROOT')
require File.join(plugin_root, 'bom_engine_clean', 'clean_analysis')

module SibamboHistory
  module V20260812_01
  module Tests
    module CleanAnalysisProfileSketchupTest
      module_function

      def run
        model_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_PROFILE_MODEL'))
        output_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_PROFILE_OUTPUT'))
        report_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_PROFILE_REPORT'))
        marker_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_PROFILE_MARKER'))
        model = Sketchup.active_model
        unless File.expand_path(model.path.to_s).casecmp?(model_path)
          raise "wrong active model: #{model.path.inspect}"
        end

        result_holder = {}
        job = SibamboHistory::V20260812_01::CleanAnalysis::ConversionJob.start(
          title: 'BOM Engine Clean structural profile',
          output_path: output_path,
          batch_size: 8_192
        ) do |progress|
          result_holder[:result] = SibamboHistory::V20260812_01::CleanAnalysis::Exporter.export(
            model: model,
            roots: model.entities,
            parent_transform: Geom::Transformation.new,
            output_path: output_path,
            settings: { scope_mode: 'model' },
            progress: progress,
            batch_size: 8_192,
            profile: true
          )
        end

        monitor_id = UI.start_timer(0.25, true) do
          next if job.running?

          UI.stop_timer(monitor_id)
          result = result_holder.fetch(:result)
          profile = result.fetch(:profile)
          write_json(report_path, profile)
          write_json(
            marker_path,
            status: 'passed',
            output_path: output_path,
            report_path: report_path,
            bytes: File.size(output_path),
            surfaces: profile.dig('geometry', 'polygon_count')
          )
          result_holder.clear
          UI.start_timer(0.5, false) { Sketchup.quit }
        rescue StandardError => error
          UI.stop_timer(monitor_id)
          write_failure(marker_path, error)
          UI.start_timer(0.5, false) { Sketchup.quit }
        end
      rescue StandardError => error
        marker_path ||= ENV['BOM_ENGINE_CLEAN_PROFILE_MARKER']
        write_failure(marker_path, error) if marker_path
        UI.start_timer(0.5, false) { Sketchup.quit }
      end

      def write_json(path, value)
        File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(value) + "\n") }
      end
      private_class_method :write_json

      def write_failure(path, error)
        write_json(
          path,
          status: 'failed',
          error_class: error.class.name,
          error: error.message,
          backtrace: Array(error.backtrace).first(16)
        )
      end
      private_class_method :write_failure
    end
  end
end

UI.start_timer(2.0, false) { SibamboHistory::V20260812_01::Tests::CleanAnalysisProfileSketchupTest.run }

end # SibamboHistory
