# frozen_string_literal: true

# End-to-end, read-only Scene instrumentation.
# Loading this file does not register menus or mutate SketchUp state.

require 'digest'
require 'fileutils'
require 'json'
require_relative 'probe_sketchup_scene_api'
require_relative '../bom_engine/bomc_extension'

module BOMEngine
  module Diagnostics
    module SceneTruth
      module_function

      def capture(model: Sketchup.active_model, output_dir: nil, exact_path: nil)
        raise 'No active SketchUp model' unless model

        output_dir ||= BOMCExtension.output_directory(model)
        FileUtils.mkdir_p(output_dir)
        model_name = model.path.to_s.empty? ? 'Untitled' : File.basename(model.path.to_s, File.extname(model.path.to_s))
        exact_path ||= File.join(output_dir, "#{model_name}__SCENE-TRUTH__EXACT.bomc")

        sketchup_report = BOMEngine::Diagnostics.probe_scenes(model)
        write_json(File.join(output_dir, 'scene-truth-sketchup.json'), sketchup_report)

        diagnostics = {}
        export_result = BOMCExtension.export(
          model,
          output_path: exact_path,
          profile: :exact,
          diagnostics: diagnostics
        )
        graph = diagnostics.fetch(:graph) { raise 'Export did not expose its diagnostic graph snapshot' }

        producer_report = producer_truth(graph, exact_path, export_result)
        write_json(File.join(output_dir, 'scene-truth-producer.json'), producer_report)

        decoded = BOMCDecoder.read(exact_path)
        bomc_report = bomc_truth(decoded, exact_path)
        write_json(File.join(output_dir, 'scene-truth-bomc.json'), bomc_report)

        {
          exact_bomc: File.expand_path(exact_path),
          sketchup: File.join(output_dir, 'scene-truth-sketchup.json'),
          producer: File.join(output_dir, 'scene-truth-producer.json'),
          bomc: File.join(output_dir, 'scene-truth-bomc.json'),
          export: export_result
        }
      end

      def producer_truth(graph, exact_path, export_result)
        planes = Array(graph[:clip_planes])
        {
          report: 'scene-truth-producer',
          exact_bomc_path: File.expand_path(exact_path),
          exact_bomc_sha256: Digest::SHA256.file(exact_path).hexdigest,
          export_result: json_safe(export_result),
          scenes: Array(graph[:scenes]).map { |scene| producer_scene(scene, planes) },
          clip_planes: json_safe(planes)
        }
      end

      def producer_scene(scene, planes)
        state = scene[:section_state] || {}
        active_ids = Array(state[:active_section_plane_ids]).map(&:to_s).sort.uniq
        active_indices = if state[:section_cuts_displayed] == true
                           planes.each_index.select do |index|
                             plane = planes[index]
                             active_ids.include?(plane[:stable_id].to_s) || active_ids.include?(plane[:source_persistent_id].to_s)
                           end
                         else
                           []
                         end
        {
          scene_id: scene[:id],
          name: scene[:name],
          camera: scene[:camera],
          visibility: scene[:visibility],
          stores_section_planes: scene[:stores_section_planes],
          active_section_plane_ids: active_ids,
          section_cut_display_state: {
            display_section_cuts: state[:section_cuts_displayed] == true,
            display_section_planes: state[:section_planes_displayed] == true
          },
          rendering_support: state[:rendering_support],
          active_clip_indices: active_indices,
          referenced_clip_records: active_indices.map { |index| planes[index] },
          plane_metadata: planes.select do |plane|
            active_ids.include?(plane[:stable_id].to_s) || active_ids.include?(plane[:source_persistent_id].to_s)
          end,
          source_binding: scene[:source_binding],
          is_active_at_export: scene[:is_active_at_export],
          visibility_signature: scene[:visibility_signature],
          scene_diagnostics: scene[:scene_diagnostics]
        }
      end

      def bomc_truth(decoded, exact_path)
        planes = Array(decoded[:clip_planes])
        {
          report: 'scene-truth-bomc',
          exact_bomc_path: File.expand_path(exact_path),
          exact_bomc_sha256: Digest::SHA256.file(exact_path).hexdigest,
          format: decoded[:format],
          container: decoded[:container],
          scenes: Array(decoded[:scenes]).map do |scene|
            state = scene[:section_state] || {}
            indices = Array(state[:active_clip_plane_indices])
            {
              scene_id: scene[:id],
              name: scene[:name],
              camera: scene[:camera],
              visibility: scene[:visibility],
              section_19: {
                version: scene[:section_version],
                state: state,
                active_section_ids: state[:active_section_plane_ids],
                active_clip_indices: indices
              },
              decoded_clip_records: indices.map { |index| planes[index] }.compact,
              rendering_support: state[:rendering_support],
              section_cut_display_state: {
                display_section_cuts: state[:section_cuts_displayed] == true,
                display_section_planes: state[:section_planes_displayed] == true
              },
              source_binding: scene[:source_binding],
              is_active_at_export: scene[:is_active_at_export],
              visibility_signature: scene[:visibility_signature]
            }
          end,
          clip_planes: planes
        }
      end

      def write_json(path, value)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(value))
        path
      end

      def json_safe(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
