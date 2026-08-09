# frozen_string_literal: true

# Automated SketchUp-host acceptance harness. Set these before launching
# SketchUp with the scratch model:
#   BOM_ENGINE_CLEAN_PLUGIN_ROOT
#   BOM_ENGINE_CLEAN_SCRATCH_MODEL
#   BOM_ENGINE_CLEAN_SCRATCH_OUTPUT
#   BOM_ENGINE_CLEAN_SCRATCH_MARKER

require 'json'

plugin_root = ENV.fetch('BOM_ENGINE_CLEAN_PLUGIN_ROOT')
require File.join(plugin_root, 'bom_engine_clean', 'clean_analysis')

module BOMEngine
  module Tests
    module CleanAnalysisScratchSketchupTest
      module_function

      def run
        model_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_SCRATCH_MODEL'))
        output_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_SCRATCH_OUTPUT'))
        marker_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_SCRATCH_MARKER'))
        model = Sketchup.active_model
        unless File.expand_path(model.path.to_s).casecmp?(model_path)
          raise "wrong active model: #{model.path.inspect}"
        end

        result = BOMEngine::CleanAnalysis::SketchupExtension.export_model(
          model,
          output_path: output_path
        )
        payload = result.fetch(:document)
        sree = payload.fetch('excluded_objects').find do |item|
          item.fetch('name').to_s.casecmp?('Sree')
        end
        raise 'Sree was not excluded' if sree.nil?
        unless payload.dig('diagnostics', 'counts', 'raw_triangle_indices_serialized') == 0
          raise 'clean JSON serialized triangle indices'
        end

        write_marker(
          marker_path,
          status: 'passed',
          output_path: result.fetch(:path),
          bytes: result.fetch(:bytes),
          counts: result.fetch(:counts),
          surface_types: payload.fetch('surfaces').group_by { |surface| surface.fetch('type') }
                                .transform_values(&:length),
          sree: sree
        )
      rescue StandardError => error
        marker_path ||= ENV['BOM_ENGINE_CLEAN_SCRATCH_MARKER']
        write_marker(
          marker_path,
          status: 'failed',
          error_class: error.class.name,
          error: error.message,
          backtrace: error.backtrace.first(12)
        ) if marker_path
      ensure
        UI.start_timer(0.5, false) { Sketchup.quit } if Sketchup.respond_to?(:quit)
      end

      def write_marker(path, values)
        File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(values) + "\n") }
      end
      private_class_method :write_marker
    end
  end
end

UI.start_timer(2.0, false) { BOMEngine::Tests::CleanAnalysisScratchSketchupTest.run }
