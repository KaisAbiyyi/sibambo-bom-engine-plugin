# frozen_string_literal: true

# Generic boundary diff for the four Scene truth reports.
# Usage: ruby tools/compare_scene_truth.rb sketchup.json producer.json bomc.json consumer.json

require 'json'

module BOMEngine
  module Diagnostics
    module SceneTruthDiff
      module_function

      def compare(sketchup, producer, bomc, consumer)
        sketchup_scenes = index_scenes(sketchup, :sketchup)
        producer_scenes = index_scenes(producer, :producer)
        bomc_scenes = index_scenes(bomc, :bomc)
        consumer_scenes = index_scenes(consumer, :consumer)
        keys = (sketchup_scenes.keys + producer_scenes.keys + bomc_scenes.keys + consumer_scenes.keys).uniq.sort

        {
          report: 'scene-truth-diff',
          scenes: keys.map do |key|
            sketchup_scene = sketchup_scenes[key]
            producer_scene = producer_scenes[key]
            bomc_scene = bomc_scenes[key]
            consumer_scene = consumer_scenes[key]
            boundaries = [
              boundary('SketchUp → Producer', sketchup_scene, producer_scene) { |left, right| compare_sketchup_producer(left, right) },
              boundary('Producer → BOMC', producer_scene, bomc_scene) { |left, right| compare_producer_bomc(left, right) },
              boundary('BOMC → Consumer', bomc_scene, consumer_scene) { |left, right| compare_bomc_consumer(left, right) }
            ]
            {
              scene_key: key,
              first_divergence: boundaries.find { |item| !item[:matches] }&.dig(:boundary),
              boundaries: boundaries
            }
          end
        }
      end

      def boundary(name, left, right)
        return { boundary: name, matches: false, missing_left: left.nil?, missing_right: right.nil?, mismatches: ['scene missing at boundary'] } unless left && right

        mismatches = yield(left, right)
        { boundary: name, matches: mismatches.empty?, mismatches: mismatches }
      end

      def compare_sketchup_producer(sketchup, producer)
        mismatches = []
        compare_value(mismatches, 'camera.eye', sketchup.dig('camera', 'eye').to_a.map { |v| v.to_f * 0.0254 }, producer.dig('camera', 'eye_m'))
        compare_value(mismatches, 'camera.target', sketchup.dig('camera', 'target').to_a.map { |v| v.to_f * 0.0254 }, producer.dig('camera', 'target_m'))
        compare_value(mismatches, 'camera.up', sketchup.dig('camera', 'up'), producer.dig('camera', 'up'))
        compare_value(mismatches, 'camera.projection', sketchup.dig('camera', 'perspective') ? 'perspective' : 'orthographic', producer.dig('camera', 'projection'))
        compare_value(mismatches, 'visible_tag_ids', sketchup.dig('layer_summary', 'visible_tag_ids'), producer.dig('visibility', 'visible_tag_ids'))
        compare_value(mismatches, 'hidden_tag_ids', sketchup.dig('layer_summary', 'hidden_tag_ids'), producer.dig('visibility', 'hidden_tag_ids'))
        compare_value(mismatches, 'active_section_plane_ids', normalize_section_ids(sketchup['active_section_plane_ids']), producer['active_section_plane_ids'])
        compare_value(mismatches, 'DisplaySectionCuts', sketchup['display_section_cuts'] == true, producer.dig('section_cut_display_state', 'display_section_cuts'))
        compare_value(mismatches, 'DisplaySectionPlanes', sketchup['display_section_planes'] == true, producer.dig('section_cut_display_state', 'display_section_planes'))
        mismatches
      end

      def compare_producer_bomc(producer, bomc)
        mismatches = []
        compare_value(mismatches, 'camera', producer['camera'], bomc['camera'])
        %w[visible_tag_ids hidden_tag_ids visible_node_overrides hidden_node_overrides visible_face_overrides hidden_face_overrides visible_edge_overrides hidden_edge_overrides].each do |field|
          compare_value(mismatches, "visibility.#{field}", producer.dig('visibility', field), bomc.dig('visibility', field))
        end
        compare_value(mismatches, 'active_section_plane_ids', producer['active_section_plane_ids'], bomc.dig('section_19', 'active_section_ids'))
        compare_value(mismatches, 'active_clip_indices', producer['active_clip_indices'], bomc.dig('section_19', 'active_clip_indices'))
        compare_value(mismatches, 'section_cut_display_state', producer['section_cut_display_state'], bomc['section_cut_display_state'])
        compare_value(mismatches, 'rendering_support', producer['rendering_support'], bomc['rendering_support'])
        compare_value(mismatches, 'referenced_clip_records', producer['referenced_clip_records'], bomc['decoded_clip_records'])
        mismatches
      end

      def compare_bomc_consumer(bomc, consumer)
        mismatches = []
        compare_value(mismatches, 'scene_id', bomc['scene_id'], consumer['sceneId'])
        compare_value(mismatches, 'name', bomc['name'], consumer['sceneName'])
        compare_value(mismatches, 'camera.target_m', bomc.dig('camera', 'target_m'), consumer['decodedAuthoredCameraTargetM'])
        compare_value(mismatches, 'visibility_signature', bomc['visibility_signature'], consumer['visibilitySignature'])
        compare_value(mismatches, 'active_clip_indices', bomc.dig('section_19', 'active_clip_indices'), consumer['activeClipPlaneIndices'])
        compare_value(mismatches, 'resolved_clip_stable_ids', bomc['decoded_clip_records'].to_a.map { |plane| plane['stable_id'] }, consumer['resolvedClipPlaneStableIds'])
        expected_navigation_target = map_sketchup_to_three(bomc.dig('camera', 'target_m'))
        compare_value(mismatches, 'actual_navigation_target', expected_navigation_target, consumer['actualNavigationTarget'])
        mismatches
      end

      def index_scenes(document, kind)
        raw = if kind == :consumer
                document['scene'] ? [document['scene']] : Array(document['scenes'] || document)
              else
                Array(document['scenes'])
              end
        raw.each_with_object({}) do |scene, index|
          next unless scene.is_a?(Hash)
          key = case kind
                when :sketchup then scene['persistent_id'].to_s.empty? ? scene['name'].to_s : scene['persistent_id'].to_s
                when :consumer then scene['sourceBindingPersistentId'].to_s.empty? ? scene['sceneId'].to_s.sub(/\Ascene:doc:/, '') : scene['sourceBindingPersistentId'].to_s
                else scene.dig('source_binding', 'persistent_id').to_s.empty? ? scene['scene_id'].to_s.sub(/\Ascene:doc:/, '') : scene.dig('source_binding', 'persistent_id').to_s
                end
          index[key] = scene
        end
      end

      def normalize_section_ids(ids)
        Array(ids).map { |id| id.to_s.start_with?('section:') ? id.to_s : "section:#{id}" }.sort
      end

      def map_sketchup_to_three(point)
        values = Array(point)
        return nil unless values.length == 3
        [values[0].to_f, values[2].to_f, -values[1].to_f]
      end

      def compare_value(mismatches, field, expected, actual)
        mismatches << { field: field, expected: expected, actual: actual } unless equal_value?(expected, actual)
      end

      def equal_value?(left, right)
        if left.is_a?(Array) && right.is_a?(Array) && left.length == right.length
          left.zip(right).all? { |a, b| equal_value?(a, b) }
        elsif left.is_a?(Numeric) && right.is_a?(Numeric)
          (left.to_f - right.to_f).abs <= 1e-5
        else
          left == right
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  paths = ARGV.first(4)
  abort 'usage: ruby tools/compare_scene_truth.rb sketchup.json producer.json bomc.json consumer.json' unless paths.length == 4
  documents = paths.map { |path| JSON.parse(File.read(path)) }
  puts JSON.pretty_generate(BOMEngine::Diagnostics::SceneTruthDiff.compare(*documents))
end
