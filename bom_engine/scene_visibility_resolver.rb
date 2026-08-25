# bom_engine/scene_visibility_resolver.rb
# Resolves SketchUp Page/Scene visibility semantics and builds CanonicalSceneProfiles.

require 'digest'
require 'json'
require 'set'
require_relative 'constants'

module BOMEngine
  module SceneVisibilityResolver
    module_function

    def resolve_scenes(model, active_page: nil, nodes: nil, definitions: nil)
      pages = model.respond_to?(:pages) ? model.pages : nil
      active = active_page || (pages.respond_to?(:selected_page) ? pages.selected_page : nil)
      pages_list = pages.respond_to?(:to_a) ? pages.to_a : Array(pages)

      if pages_list.empty?
        [build_scene_profile(nil, is_active: true, model: model, nodes: nodes, definitions: definitions)]
      else
        pages_list.map do |page|
          is_active = (page == active)
          build_scene_profile(page, is_active: is_active, model: model, nodes: nodes, definitions: definitions)
        end
      end
    end

    def build_scene_profile(page, is_active: false, model: nil, nodes: nil, definitions: nil)
      if page.nil?
        camera_data = current_view_camera(model)
        visible_tag_ids = []
        hidden_tag_ids = []
        if model && model.respond_to?(:layers)
          model.layers.each do |layer|
            id = tag_stable_id(layer)
            if layer.visible?
              visible_tag_ids << id
            else
              hidden_tag_ids << id
            end
          end
        end
        signature = compute_visibility_signature(
          visible_tag_ids: visible_tag_ids,
          hidden_tag_ids: hidden_tag_ids,
          visible_node_overrides: [],
          hidden_node_overrides: [],
          active_section_plane_ids: []
        )
        profile = {
          id: 'scene:doc:current_view',
          name: 'Current View',
          description: '',
          is_active_at_export: is_active,
          source: 'current-view',
          source_binding: {
            provider: 'sketchup',
            persistent_id: 'current_view'
          },
          camera: camera_data,
          use_camera: true,
          transition_time_seconds: 0.0,
          visibility: {
            visible_tag_ids: visible_tag_ids.sort.uniq,
            hidden_tag_ids: hidden_tag_ids.sort.uniq,
            visible_node_overrides: [],
            hidden_node_overrides: []
          },
          stores_tag_visibility: true,
          stores_hidden_objects: true,
          stores_hidden_geometry: false,
          stores_section_planes: false,
          section_state: {
            active_section_plane_ids: [],
            rendering_support: 'metadata-only'
          },
          visibility_signature: signature
        }
        if nodes && !nodes.empty?
          profile[:effective_visible_occurrence_count] = calculate_effective_visible_occurrences(nodes, definitions, profile)
        end
        return profile
      end

      page_pid = safe_persistent_id(page)
      scene_id = "scene:doc:#{page_pid}"
      camera_data = extract_page_camera(page)
      stores_tags = page.respond_to?(:use_hidden_layers?) ? page.use_hidden_layers? : true
      stores_objects = page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : (page.respond_to?(:use_hidden?) ? page.use_hidden? : true)
      stores_geometry = page.respond_to?(:use_hidden_geometry?) ? page.use_hidden_geometry? : false
      stores_sections = page.respond_to?(:use_section_planes?) ? page.use_section_planes? : false

      visible_tag_ids = []
      hidden_tag_ids = []
      if model && model.respond_to?(:layers)
        model.layers.each do |layer|
          id = tag_stable_id(layer)
          if effective_tag_visibility(layer, page)
            visible_tag_ids << id
          else
            hidden_tag_ids << id
          end
        end
      end

      # DrawingElement visibility overrides
      visible_node_overrides, hidden_node_overrides = extract_node_overrides(page, model, nodes)
      active_section_plane_ids = extract_active_section_planes(page)

      signature = compute_visibility_signature(
        visible_tag_ids: visible_tag_ids,
        hidden_tag_ids: hidden_tag_ids,
        visible_node_overrides: visible_node_overrides,
        hidden_node_overrides: hidden_node_overrides,
        active_section_plane_ids: active_section_plane_ids
      )

      profile = {
        id: scene_id,
        name: page.name.to_s,
        description: page.description.to_s,
        is_active_at_export: is_active,
        source: 'sketchup-page',
        source_binding: {
          provider: 'sketchup',
          persistent_id: page_pid
        },
        camera: camera_data,
        use_camera: page.respond_to?(:use_camera?) ? page.use_camera? : true,
        transition_time_seconds: page.respond_to?(:transition_time) ? page.transition_time.to_f : 0.0,
        visibility: {
          visible_tag_ids: visible_tag_ids.sort.uniq,
          hidden_tag_ids: hidden_tag_ids.sort.uniq,
          visible_node_overrides: visible_node_overrides.sort.uniq,
          hidden_node_overrides: hidden_node_overrides.sort.uniq
        },
        stores_tag_visibility: stores_tags,
        stores_hidden_objects: stores_objects,
        stores_hidden_geometry: stores_geometry,
        stores_section_planes: stores_sections,
        section_state: {
          active_section_plane_ids: active_section_plane_ids.sort.uniq,
          rendering_support: 'metadata-only'
        },
        visibility_signature: signature
      }

      if nodes && !nodes.empty?
        profile[:effective_visible_occurrence_count] = calculate_effective_visible_occurrences(nodes, definitions, profile)
      end

      profile
    end

    def extract_node_overrides(page, model, nodes = nil)
      visible_overrides = []
      hidden_overrides = []

      # 1. If nodes list is provided, inspect each node's underlying entity
      if nodes && !nodes.empty?
        nodes.each do |node|
          next if node[:kind] == 'root'
          node_id = node[:id]
          entity = node[:_entity] || node[:entity]
          pid = node.dig(:source_identity, :persistent_id) || node[:persistent_id]

          if entity
            if page.respond_to?(:get_drawingelement_visibility)
              flag = (begin page.get_drawingelement_visibility(entity) rescue nil end)
              if flag == 1
                hidden_overrides << node_id
                next
              elsif flag == 2
                visible_overrides << node_id
                next
              end
            end

            if page.respond_to?(:hidden_entities)
              hidden_list = (begin page.hidden_entities rescue nil end)
              if hidden_list && hidden_list.respond_to?(:include?) && hidden_list.include?(entity)
                hidden_overrides << node_id
                next
              end
            end

            if page.respond_to?(:use_hidden_objects?) && !page.use_hidden_objects?
              if entity.respond_to?(:hidden?) && entity.hidden?
                hidden_overrides << node_id
                next
              end
            end
          elsif pid
            # Check by persistent id if entity object is not directly bound
            if page.respond_to?(:hidden_entities)
              hidden_list = (begin page.hidden_entities rescue nil end) || []
              if hidden_list.any? { |he| safe_persistent_id(he) == pid.to_s }
                hidden_overrides << node_id
                next
              end
            end
          end
        end
      end

      # 2. Extract from page.hidden_entities for any items not covered
      if page.respond_to?(:hidden_entities)
        hidden_list = (begin page.hidden_entities rescue nil end) || []
        Array(hidden_list).each do |ent|
          ent_pid = safe_persistent_id(ent)
          node_ref = "node:pid:#{ent_pid}"
          hidden_overrides << node_ref unless hidden_overrides.any? { |id| id.include?(ent_pid) }
        end
      end

      if page.respond_to?(:visible_entities)
        vis_list = (begin page.visible_entities rescue nil end) || []
        Array(vis_list).each do |ent|
          ent_pid = safe_persistent_id(ent)
          node_ref = "node:pid:#{ent_pid}"
          visible_overrides << node_ref unless visible_overrides.any? { |id| id.include?(ent_pid) }
        end
      end

      [visible_overrides, hidden_overrides]
    rescue StandardError
      [[], []]
    end

    def calculate_effective_visible_occurrences(nodes, definitions, scene)
      return 0 if nodes.nil? || nodes.empty?

      hidden_nodes = Array(scene.dig(:visibility, :hidden_node_overrides)).to_set
      visible_nodes = Array(scene.dig(:visibility, :visible_node_overrides)).to_set
      hidden_tags = Array(scene.dig(:visibility, :hidden_tag_ids)).to_set
      visible_tags = Array(scene.dig(:visibility, :visible_tag_ids)).to_set
      stores_tags = scene[:stores_tag_visibility] != false

      nodes_by_id = {}
      nodes.each { |n| nodes_by_id[n[:id]] = n }

      definitions_by_id = {}
      Array(definitions).each { |d| definitions_by_id[d[:id]] = d }

      root_node = nodes.find { |n| n[:kind] == 'root' }
      return nodes.count { |n| n[:visible] != false } if root_node.nil?

      node_visible = lambda do |node|
        return false if hidden_nodes.include?(node[:id])
        pid = node.dig(:source_identity, :persistent_id) || node[:persistent_id]
        return false if pid && (hidden_nodes.include?(pid.to_s) || hidden_nodes.include?("node:pid:#{pid}"))
        return true if visible_nodes.include?(node[:id])
        return true if pid && (visible_nodes.include?(pid.to_s) || visible_nodes.include?("node:pid:#{pid}"))

        tag_id = node[:tag_id]
        if stores_tags && tag_id
          return false if hidden_tags.include?(tag_id)
          return true if visible_tags.include?(tag_id)
        end
        node[:visible] != false
      end

      count = 0
      traverse = lambda do |definition_id|
        defn = definitions_by_id[definition_id]
        return unless defn
        child_node_ids = defn[:node_ids] || []
        child_node_ids.each do |nid|
          child_node = nodes_by_id[nid]
          next unless child_node
          if node_visible.call(child_node)
            count += 1
            traverse.call(child_node[:definition_id]) if child_node[:definition_id]
          end
        end
      end

      traverse.call(root_node[:definition_id])
      count
    rescue StandardError
      0
    end

    def effective_tag_visibility(layer, page)
      return true if layer.nil?

      base_visible = layer.respond_to?(:visible?) ? layer.visible? : true
      return base_visible if page.nil?

      # If page does not store hidden layers, inherit base visibility
      if page.respond_to?(:use_hidden_layers?) && !page.use_hidden_layers?
        return base_visible
      end

      # Check explicit page query if available
      if page.respond_to?(:layer_visible?)
        return page.layer_visible?(layer)
      end

      # Check layer folders if supported
      if layer.respond_to?(:folder) && layer.folder
        folder = layer.folder
        if folder.respond_to?(:visible?) && !folder.visible?
          return false
        end
        if page.respond_to?(:layer_folders)
          hidden_folders = (begin page.layer_folders rescue [] end) || []
          return false if hidden_folders.include?(folder)
        end
      end

      # Page#layers contains layers whose visibility is altered by the page
      page_layers = (begin page.layers rescue [] end) || []
      if page_layers.include?(layer)
        # In SketchUp Page API, layers returned by page.layers are hidden layers on that page
        # unless page specifies visible layers.
        false
      else
        # Not in page's hidden layer list => visible on page
        true
      end
    end

    def effective_entity_visibility(entity, page)
      return false if entity.nil? || (entity.respond_to?(:deleted?) && entity.deleted?)

      # 1. Tag / Layer check
      if entity.respond_to?(:layer) && entity.layer
        return false unless effective_tag_visibility(entity.layer, page)
      end

      # 2. Base visibility
      base_visible = entity.respond_to?(:visible?) ? entity.visible? : true
      base_hidden = entity.respond_to?(:hidden?) ? entity.hidden? : false
      return false if base_hidden || !base_visible if page.nil?

      # 3. Page DrawingElement override
      if page.respond_to?(:get_drawingelement_visibility)
        flag = page.get_drawingelement_visibility(entity) rescue nil
        # 1 = HIDDEN, 2 = VISIBLE, 0 = LAYER_VISIBLE (default)
        return false if flag == 1
        return true if flag == 2
      end

      # 4. Page hidden entities
      if page.respond_to?(:hidden_entities)
        hidden_list = page.hidden_entities rescue nil
        return false if hidden_list && hidden_list.respond_to?(:include?) && hidden_list.include?(entity)
      end

      # 5. Hidden objects / geometry flags
      stores_objects = page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : (page.respond_to?(:use_hidden?) ? page.use_hidden? : true)
      if stores_objects && base_hidden
        return false
      end
      if !stores_objects && (base_hidden || !base_visible)
        return false
      end

      true
    rescue StandardError
      true
    end

    def exportable_universe?(entity, scenes, scope: 'active')
      return false if entity.nil? || (entity.respond_to?(:deleted?) && entity.deleted?)

      pid = safe_persistent_id(entity)
      tag_id = entity.respond_to?(:layer) && entity.layer ? tag_stable_id(entity.layer) : nil

      if scope == 'active'
        active_scene = scenes.find { |s| s[:is_active_at_export] } || scenes.first
        return true if active_scene.nil?

        hidden_nodes = active_scene.dig(:visibility, :hidden_node_overrides) || []
        visible_nodes = active_scene.dig(:visibility, :visible_node_overrides) || []

        if visible_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
          return true
        end

        if hidden_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
          return false
        end

        if tag_id && active_scene.dig(:visibility, :hidden_tag_ids)&.include?(tag_id)
          return false
        end

        return true
      end

      # scope == 'all' (Union of visible across all exported scenes)
      return true if scenes.nil? || scenes.empty?

      visible_in_any = scenes.any? do |scene|
        hidden_nodes = scene.dig(:visibility, :hidden_node_overrides) || []
        visible_nodes = scene.dig(:visibility, :visible_node_overrides) || []

        next true if visible_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
        next false if hidden_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }

        if tag_id
          scene.dig(:visibility, :visible_tag_ids)&.include?(tag_id) != false
        else
          true
        end
      end

      visible_in_any
    rescue StandardError
      true
    end

    def compute_visibility_signature(visible_tag_ids:, hidden_tag_ids:, visible_node_overrides:, hidden_node_overrides:, active_section_plane_ids:)
      payload = [
        Array(visible_tag_ids).map(&:to_s).sort.uniq,
        Array(hidden_tag_ids).map(&:to_s).sort.uniq,
        Array(visible_node_overrides).map(&:to_s).sort.uniq,
        Array(hidden_node_overrides).map(&:to_s).sort.uniq,
        Array(active_section_plane_ids).map(&:to_s).sort.uniq
      ]
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def tag_stable_id(layer)
      return 'tag:0' if layer.nil?
      "tag:#{safe_persistent_id(layer)}"
    end

    def safe_persistent_id(entity)
      return '0' if entity.nil?
      if entity.respond_to?(:persistent_id) && entity.persistent_id && !entity.persistent_id.to_s.empty?
        entity.persistent_id.to_s
      elsif entity.respond_to?(:entityID) && entity.entityID && !entity.entityID.to_i.zero?
        entity.entityID.to_s
      elsif entity.respond_to?(:name) && entity.name && !entity.name.to_s.empty?
        source_token(entity.name)
      else
        entity.object_id.to_s
      end
    rescue StandardError
      entity.object_id.to_s
    end

    def source_token(value)
      value.to_s.gsub(/[^A-Za-z0-9._-]+/, '-').gsub(/^-|-$/, '')
    end

    def extract_page_camera(page)
      camera = page.respond_to?(:camera) ? page.camera : nil
      return default_camera if camera.nil?

      is_persp = camera.respond_to?(:perspective?) ? camera.perspective? : true
      {
        projection: is_persp ? 'perspective' : 'orthographic',
        eye_m: point_array(camera.eye),
        target_m: point_array(camera.target),
        up: vector_array(camera.up),
        field_of_view_degrees: is_persp && camera.respond_to?(:fov) ? camera.fov.to_f : nil,
        orthographic_height_m: !is_persp && camera.respond_to?(:height) ? (camera.height.to_f * Constants::IN_TO_M).round(9) : nil,
        aspect_ratio: camera.respond_to?(:aspect_ratio) ? camera.aspect_ratio.to_f : 0.0
      }
    rescue StandardError
      default_camera
    end

    def current_view_camera(model)
      view = model.respond_to?(:active_view) ? model.active_view : nil
      camera = view.respond_to?(:camera) ? view.camera : nil
      return default_camera if camera.nil?

      is_persp = camera.respond_to?(:perspective?) ? camera.perspective? : true
      {
        projection: is_persp ? 'perspective' : 'orthographic',
        eye_m: point_array(camera.eye),
        target_m: point_array(camera.target),
        up: vector_array(camera.up),
        field_of_view_degrees: is_persp && camera.respond_to?(:fov) ? camera.fov.to_f : nil,
        orthographic_height_m: !is_persp && camera.respond_to?(:height) ? (camera.height.to_f * Constants::IN_TO_M).round(9) : nil,
        aspect_ratio: camera.respond_to?(:aspect_ratio) ? camera.aspect_ratio.to_f : 0.0
      }
    rescue StandardError
      default_camera
    end

    def default_camera
      {
        projection: 'perspective',
        eye_m: [10.0, -10.0, 10.0],
        target_m: [0.0, 0.0, 0.0],
        up: [0.0, 0.0, 1.0],
        field_of_view_degrees: 35.0,
        orthographic_height_m: nil,
        aspect_ratio: 0.0
      }
    end

    def extract_active_section_planes(page)
      planes = []
      if page.respond_to?(:active_section_planes)
        raw = (begin page.active_section_planes rescue [] end) || []
        Array(raw).each do |plane|
          planes << "section:#{safe_persistent_id(plane)}"
        end
      end
      planes
    rescue StandardError
      []
    end

    def point_array(point)
      return [0.0, 0.0, 0.0] if point.nil?
      [
        (point.x.to_f * Constants::IN_TO_M).round(9),
        (point.y.to_f * Constants::IN_TO_M).round(9),
        (point.z.to_f * Constants::IN_TO_M).round(9)
      ]
    rescue StandardError
      [0.0, 0.0, 0.0]
    end

    def vector_array(vector)
      return [0.0, 0.0, 1.0] if vector.nil?
      [vector.x.to_f.round(9), vector.y.to_f.round(9), vector.z.to_f.round(9)]
    rescue StandardError
      [0.0, 0.0, 1.0]
    end
  end
end
