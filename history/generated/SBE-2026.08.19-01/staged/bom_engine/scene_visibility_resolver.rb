# bom_engine/scene_visibility_resolver.rb
# Resolves SketchUp Page/Scene visibility semantics and builds CanonicalSceneProfiles.

require 'digest'
require 'json'
require_relative 'constants'

module SibamboHistory
  module V20260819_01
  module SceneVisibilityResolver
    module_function

    def resolve_scenes(model, active_page: nil)
      pages = model.respond_to?(:pages) ? model.pages : nil
      active = active_page || (pages.respond_to?(:selected_page) ? pages.selected_page : nil)

      if pages.nil? || pages.length.zero?
        [build_scene_profile(nil, is_active: true, model: model)]
      else
        pages.map do |page|
          is_active = (page == active)
          build_scene_profile(page, is_active: is_active, model: model)
        end
      end
    end

    def build_scene_profile(page, is_active: false, model: nil)
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
        return {
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
            visible_tag_ids: visible_tag_ids.sort,
            hidden_tag_ids: hidden_tag_ids.sort,
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
      visible_node_overrides = []
      hidden_node_overrides = []
      active_section_plane_ids = extract_active_section_planes(page)

      signature = compute_visibility_signature(
        visible_tag_ids: visible_tag_ids,
        hidden_tag_ids: hidden_tag_ids,
        visible_node_overrides: visible_node_overrides,
        hidden_node_overrides: hidden_node_overrides,
        active_section_plane_ids: active_section_plane_ids
      )

      {
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
          visible_tag_ids: visible_tag_ids.sort,
          hidden_tag_ids: hidden_tag_ids.sort,
          visible_node_overrides: visible_node_overrides.sort,
          hidden_node_overrides: hidden_node_overrides.sort
        },
        stores_tag_visibility: stores_tags,
        stores_hidden_objects: stores_objects,
        stores_hidden_geometry: stores_geometry,
        stores_section_planes: stores_sections,
        section_state: {
          active_section_plane_ids: active_section_plane_ids.sort,
          rendering_support: 'metadata-only'
        },
        visibility_signature: signature
      }
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

      if scope == 'active'
        active_scene = scenes.find { |s| s[:is_active_at_export] } || scenes.first
        return true if active_scene.nil?
        # Check tag visibility for active scene
        if entity.respond_to?(:layer) && entity.layer
          tag_id = tag_stable_id(entity.layer)
          return false if active_scene.dig(:visibility, :hidden_tag_ids)&.include?(tag_id)
        end
        return true
      end

      # scope == 'all' (Union of visible across all exported scenes)
      return true if scenes.empty?

      # An entity is in the exportable universe if visible in AT LEAST ONE scene
      if entity.respond_to?(:layer) && entity.layer
        tag_id = tag_stable_id(entity.layer)
        visible_in_any = scenes.any? do |scene|
          scene.dig(:visibility, :visible_tag_ids)&.include?(tag_id)
        end
        return false unless visible_in_any
      end

      true
    rescue StandardError
      true
    end

    def compute_visibility_signature(visible_tag_ids:, hidden_tag_ids:, visible_node_overrides:, hidden_node_overrides:, active_section_plane_ids:)
      payload = [
        Array(visible_tag_ids).map(&:to_s).sort,
        Array(hidden_tag_ids).map(&:to_s).sort,
        Array(visible_node_overrides).map(&:to_s).sort,
        Array(hidden_node_overrides).map(&:to_s).sort,
        Array(active_section_plane_ids).map(&:to_s).sort
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

end # SibamboHistory
