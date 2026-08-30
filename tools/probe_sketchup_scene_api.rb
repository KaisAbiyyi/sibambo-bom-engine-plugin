# frozen_string_literal: true
# tools/probe_sketchup_scene_api.rb
# Diagnostic probe to safely inspect official SketchUp Scene/Page API properties on an active model.
# Read-only: Does NOT modify model state.

require 'json'
require_relative '../bom_engine/scene_visibility_resolver'

module BOMEngine
  module Diagnostics
    module_function

    def probe_scenes(model = Sketchup.active_model)
      return { error: 'No active SketchUp model' } unless model

      pages = model.pages ? model.pages.to_a : []
      layers = model.layers ? model.layers.to_a : []
      selected_page = model.pages.respond_to?(:selected_page) ? model.pages.selected_page : nil

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
        tag_entries = layers.map do |layer|
          visible = BOMEngine::SceneVisibilityResolver.effective_tag_visibility(layer, page)
          {
            id: "tag:#{safe_entity_id(layer)}",
            name: (layer.respond_to?(:name) ? layer.name : nil),
            persistent_id: safe_entity_id(layer),
            visible: visible
          }
        end
        layer_summary = {
          use_hidden_layers: (page.respond_to?(:use_hidden_layers?) ? page.use_hidden_layers? : true),
          layers_count: page_layers.length,
          layers: page_layers.map { |l| l.respond_to?(:name) ? l.name : l.to_s },
          visible_tag_ids: tag_entries.select { |entry| entry[:visible] }.map { |entry| entry[:id] }.sort,
          hidden_tag_ids: tag_entries.reject { |entry| entry[:visible] }.map { |entry| entry[:id] }.sort,
          tags: tag_entries
        }

        # Hidden entities details
        hidden_ents = (page.respond_to?(:hidden_entities) && page.hidden_entities) ? page.hidden_entities.to_a : []
        drawingelement_visibility = drawingelement_visibility_report(model, page, hidden_ents)

        # Section planes details
        active_planes = []
        if page.respond_to?(:active_section_planes) && page.active_section_planes
          page.active_section_planes.each do |sp|
            eq = sp.respond_to?(:get_plane) ? sp.get_plane.to_a : nil
            active_planes << section_plane_report(sp)
          end
        elsif page.respond_to?(:active_section_plane) && page.active_section_plane
          sp = page.active_section_plane
          eq = sp.respond_to?(:get_plane) ? sp.get_plane.to_a : nil
          active_planes << section_plane_report(sp)
        end

        rendering_options = if page.respond_to?(:use_rendering_options?) && page.use_rendering_options? && page.respond_to?(:rendering_options)
                              page.rendering_options
                            end

        scene_entry = {
          name: page.name,
          persistent_id: (page.respond_to?(:persistent_id) ? page.persistent_id : nil),
          selected: page == selected_page,
          use_camera: (page.respond_to?(:use_camera?) ? page.use_camera? : true),
          camera: cam_info,
          layer_summary: layer_summary,
          use_hidden_layers: (page.respond_to?(:use_hidden_layers?) ? page.use_hidden_layers? : true),
          use_hidden_objects: (page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : true),
          use_hidden_geometry: (page.respond_to?(:use_hidden_geometry?) ? page.use_hidden_geometry? : false),
          hidden_entities_count: hidden_ents.length,
          hidden_entity_ids: hidden_ents.map { |entity| safe_entity_id(entity) },
          drawingelement_visibility: drawingelement_visibility,
          use_section_planes: (page.respond_to?(:use_section_planes?) ? page.use_section_planes? : false),
          active_section_planes: active_planes,
          active_section_plane_ids: active_planes.map { |plane| plane[:persistent_id] },
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

    def write_probe_report(path = 'scene-truth-sketchup.json', model = Sketchup.active_model)
      report = probe_scenes(model)
      File.write(path, JSON.pretty_generate(report))
      path
    end

    def safe_entity_id(entity)
      return nil if entity.nil?
      if entity.respond_to?(:persistent_id) && entity.persistent_id
        entity.persistent_id
      elsif entity.respond_to?(:entityID) && entity.entityID
        entity.entityID
      else
        entity.object_id
      end
    rescue StandardError
      entity.object_id
    end

    def section_plane_report(plane)
      equation = plane.respond_to?(:get_plane) ? (plane.get_plane.to_a rescue nil) : nil
      {
        persistent_id: safe_entity_id(plane),
        plane_equation: equation,
        get_plane: equation,
        parent_context: parent_context_report(plane)
      }
    rescue StandardError => error
      { persistent_id: safe_entity_id(plane), plane_equation: nil, get_plane: nil, parent_context: nil, error: error.message.to_s }
    end

    def parent_context_report(entity)
      chain = []
      current = entity
      seen = {}
      8.times do
        break unless current.respond_to?(:parent)
        parent = current.parent rescue nil
        break if parent.nil? || seen[parent.object_id]
        seen[parent.object_id] = true
        chain << {
          class: parent.class.to_s,
          persistent_id: safe_entity_id(parent),
          name: (parent.respond_to?(:name) ? parent.name : nil)
        }
        current = parent
      end
      chain
    rescue StandardError
      []
    end

    def drawingelement_visibility_report(model, page, hidden_entities)
      api_available = page.respond_to?(:get_drawingelement_visibility)
      hidden = hidden_entities.map do |entity|
        { class: entity.class.to_s, persistent_id: safe_entity_id(entity), name: (entity.respond_to?(:name) ? entity.name : nil) }
      end
      return { api_available: api_available, hidden_entities: hidden, records: [] } unless api_available

      containers = []
      containers << ['model', model.entities] if model.respond_to?(:entities)
      if model.respond_to?(:definitions)
        model.definitions.to_a.each do |definition|
          containers << ["definition:#{safe_entity_id(definition)}", definition.entities] if definition.respond_to?(:entities)
        end
      end
      records = []
      containers.each do |scope, entities|
        entities.to_a.each do |entity|
          page_visibility = page.get_drawingelement_visibility(entity) rescue nil
          records << {
            scope: scope,
            class: entity.class.to_s,
            persistent_id: safe_entity_id(entity),
            name: (entity.respond_to?(:name) ? entity.name : nil),
            base_visible: (entity.respond_to?(:visible?) ? entity.visible? : nil),
            base_hidden: (entity.respond_to?(:hidden?) ? entity.hidden? : nil),
            page_visibility: page_visibility
          }
        end
      end
      { api_available: true, hidden_entities: hidden, records: records }
    rescue StandardError => error
      { api_available: api_available, hidden_entities: hidden, records: [], error: error.message.to_s }
    end

    def print_probe_report(model = Sketchup.active_model)
      report = probe_scenes(model)
      puts JSON.pretty_generate(report)
      report
    end
  end
end
