# frozen_string_literal: true
# tools/probe_sketchup_scene_api.rb
# Diagnostic probe to safely inspect official SketchUp Scene/Page API properties on an active model.
# Read-only: Does NOT modify model state.

module BOMEngine
  module Diagnostics
    module_function

    def probe_scenes(model = Sketchup.active_model)
      return { error: 'No active SketchUp model' } unless model

      pages = model.pages ? model.pages.to_a : []
      layers = model.layers ? model.layers.to_a : []

      report = {
        model_name: model.title,
        page_count: pages.length,
        layer_count: layers.length,
        scenes: []
      }

      pages.each do |page|
        cam = page.camera
        cam_info = if cam
                     {
                       perspective: (cam.respond_to?(:perspective?) ? cam.perspective? : true),
                       eye: cam.eye.to_a,
                       target: cam.target.to_a,
                       up: cam.up.to_a,
                       fov: (cam.respond_to?(:fov) ? cam.fov : nil),
                       height: (cam.respond_to?(:height) ? cam.height : nil)
                     }
                   else
                     nil
                   end

        # Tag/Layer details
        page_layers = (page.respond_to?(:layers) && page.layers) ? page.layers.to_a : []
        layer_summary = {
          use_hidden_layers: (page.respond_to?(:use_hidden_layers?) ? page.use_hidden_layers? : true),
          layers_count: page_layers.length,
          layers: page_layers.map { |l| l.respond_to?(:name) ? l.name : l.to_s }
        }

        # Hidden entities details
        hidden_ents = (page.respond_to?(:hidden_entities) && page.hidden_entities) ? page.hidden_entities.to_a : []

        # Section planes details
        active_planes = []
        if page.respond_to?(:active_section_planes) && page.active_section_planes
          page.active_section_planes.each do |sp|
            eq = sp.respond_to?(:get_plane) ? sp.get_plane.to_a : nil
            pid = sp.respond_to?(:persistent_id) ? sp.persistent_id : sp.object_id
            active_planes << { persistent_id: pid, plane_equation: eq }
          end
        elsif page.respond_to?(:active_section_plane) && page.active_section_plane
          sp = page.active_section_plane
          eq = sp.respond_to?(:get_plane) ? sp.get_plane.to_a : nil
          pid = sp.respond_to?(:persistent_id) ? sp.persistent_id : sp.object_id
          active_planes << { persistent_id: pid, plane_equation: eq }
        end

        rendering_options = if page.respond_to?(:use_rendering_options?) && page.use_rendering_options? && page.respond_to?(:rendering_options)
                              page.rendering_options
                            end

        scene_entry = {
          name: page.name,
          persistent_id: (page.respond_to?(:persistent_id) ? page.persistent_id : nil),
          use_camera: (page.respond_to?(:use_camera?) ? page.use_camera? : true),
          camera: cam_info,
          layer_summary: layer_summary,
          use_hidden_objects: (page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : true),
          use_hidden_geometry: (page.respond_to?(:use_hidden_geometry?) ? page.use_hidden_geometry? : false),
          hidden_entities_count: hidden_ents.length,
          use_section_planes: (page.respond_to?(:use_section_planes?) ? page.use_section_planes? : false),
          active_section_planes: active_planes,
          use_rendering_options: (page.respond_to?(:use_rendering_options?) ? page.use_rendering_options? : false),
          display_section_cuts: rendering_options ? rendering_options['DisplaySectionCuts'] : nil,
          display_section_planes: rendering_options ? rendering_options['DisplaySectionPlanes'] : nil,
          api_capabilities: {
            has_get_drawingelement_visibility: page.respond_to?(:get_drawingelement_visibility),
            has_hidden_entities: page.respond_to?(:hidden_entities),
            has_visible_entities: page.respond_to?(:visible_entities), # Should be false in official SketchUp
            has_layer_visible: page.respond_to?(:layer_visible?)       # Should be false in official SketchUp
          }
        }

        report[:scenes] << scene_entry
      end

      report
    end

    def print_probe_report(model = Sketchup.active_model)
      report = probe_scenes(model)
      puts JSON.pretty_generate(report)
      report
    end
  end
end
