# bom_engine/scene_visibility_resolver.rb
# Resolves SketchUp Page/Scene visibility semantics and builds CanonicalSceneProfiles.

require 'digest'
require 'json'
require 'set'
require_relative 'constants'

module BOMEngine
  module SceneVisibilityResolver
    module_function

    def resolve_scenes(model, active_page: nil, nodes: nil, definitions: nil, meshes: nil)
      pages = model.respond_to?(:pages) ? model.pages : nil
      active = active_page || (pages.respond_to?(:selected_page) ? pages.selected_page : nil)
      pages_list = pages.respond_to?(:to_a) ? pages.to_a : Array(pages)

      if pages_list.empty?
        [build_scene_profile(nil, is_active: true, model: model, nodes: nodes, definitions: definitions, meshes: meshes)]
      else
        pages_list.map do |page|
          is_active = (page == active)
          build_scene_profile(page, is_active: is_active, model: model, nodes: nodes, definitions: definitions, meshes: meshes)
        end
      end
    end

    def resolve_effective_scene_visibility(page, model: nil, nodes: nil, definitions: nil, meshes: nil, is_active: false)
      build_scene_profile(page, is_active: is_active, model: model, nodes: nodes, definitions: definitions, meshes: meshes)
    end

    def build_scene_profile(page, is_active: false, model: nil, nodes: nil, definitions: nil, meshes: nil)
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
          visible_face_overrides: [], hidden_face_overrides: [],
          visible_edge_overrides: [], hidden_edge_overrides: [],
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
            hidden_node_overrides: [],
            visible_face_overrides: [], hidden_face_overrides: [],
            visible_edge_overrides: [], hidden_edge_overrides: [],
            unresolved_primitive_overrides: []
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
      stores_sections = page.respond_to?(:use_section_planes?) ? page.use_section_planes? : true

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
      overrides = extract_visibility_overrides(page, nodes, meshes)
      visible_node_overrides = overrides[:visible_nodes]
      hidden_node_overrides = overrides[:hidden_nodes]
      active_section_plane_ids = extract_active_section_planes(page)

      model_clip_planes = collect_model_clip_planes(model)
      rendering_support = 'none'
      if !active_section_plane_ids.empty?
        all_resolved = active_section_plane_ids.all? do |sid|
          cp = model_clip_planes.find { |p| p[:stable_id] == sid }
          cp && cp[:owner_definition_id].nil?
        end
        rendering_support = all_resolved ? 'full' : 'metadata-only'
      end

      signature = compute_visibility_signature(
        visible_tag_ids: visible_tag_ids,
        hidden_tag_ids: hidden_tag_ids,
        visible_node_overrides: visible_node_overrides,
        hidden_node_overrides: hidden_node_overrides,
        visible_face_overrides: overrides[:visible_faces],
        hidden_face_overrides: overrides[:hidden_faces],
        visible_edge_overrides: overrides[:visible_edges],
        hidden_edge_overrides: overrides[:hidden_edges],
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
          hidden_node_overrides: hidden_node_overrides.sort.uniq,
          visible_face_overrides: overrides[:visible_faces],
          hidden_face_overrides: overrides[:hidden_faces],
          visible_edge_overrides: overrides[:visible_edges],
          hidden_edge_overrides: overrides[:hidden_edges],
          unresolved_primitive_overrides: overrides[:unresolved]
        },
        stores_tag_visibility: stores_tags,
        stores_hidden_objects: stores_objects,
        stores_hidden_geometry: stores_geometry,
        stores_section_planes: stores_sections,
        section_state: {
          active_section_plane_ids: active_section_plane_ids.sort.uniq,
          rendering_support: rendering_support
        },
        visibility_signature: signature
      }

      if nodes && !nodes.empty?
        profile[:effective_visible_occurrence_count] = calculate_effective_visible_occurrences(nodes, definitions, profile)
      end

      profile
    end

    def drawingelement_scene_applicable?(entity, page, is_root: false)
      return false if page.nil? || entity.nil?

      stores_objects = page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : (page.respond_to?(:use_hidden?) ? page.use_hidden? : true)
      stores_geometry = page.respond_to?(:use_hidden_geometry?) ? page.use_hidden_geometry? : false

      is_instance = (defined?(Sketchup::ComponentInstance) && entity.is_a?(Sketchup::ComponentInstance) rescue false) ||
                    (defined?(Sketchup::Group) && entity.is_a?(Sketchup::Group) rescue false) ||
                    (defined?(Sketchup::Image) && entity.is_a?(Sketchup::Image) rescue false) ||
                    entity.respond_to?(:definition) ||
                    entity.class.name.to_s =~ /Instance|Group|Image|MockDrawingElement|DrawingElement/i

      if is_instance
        stores_objects
      else
        is_root_entity = is_root || (entity.respond_to?(:parent) && (entity.parent.is_a?(Sketchup::Model) rescue false))
        stores_geometry && is_root_entity
      end
    end

    def extract_node_overrides(page, model, nodes = nil)
      overrides = extract_visibility_overrides(page, nodes, nil)
      [overrides[:visible_nodes], overrides[:hidden_nodes]]
    end

    def extract_visibility_overrides(page, nodes = nil, meshes = nil)
      visible_overrides = []
      hidden_overrides = []
      result = {
        visible_nodes: visible_overrides, hidden_nodes: hidden_overrides,
        visible_faces: [], hidden_faces: [], visible_edges: [], hidden_edges: [], unresolved: []
      }
      return result if page.nil?

      stores_objects = page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : (page.respond_to?(:use_hidden?) ? page.use_hidden? : true)
      stores_geometry = page.respond_to?(:use_hidden_geometry?) ? page.use_hidden_geometry? : false

      hidden_entities_list = page.respond_to?(:hidden_entities) ? ((begin page.hidden_entities.to_a rescue [] end) || []) : []
      hidden_entities_set = hidden_entities_list.to_set
      hidden_pids_set = hidden_entities_list.map { |he| safe_persistent_id(he).to_s }.to_set

      nodes_by_entity = {}
      nodes_by_pid = {}
      primitives_by_entity = {}
      primitives_by_pid = {}
      Array(meshes).each do |mesh|
        Array(mesh[:faces]).each do |face|
          entity = face[:_entity] || face[:entity]
          pid = face.dig(:source_identity, :persistent_id) || face[:persistent_id]
          record = [:face, face[:id]]
          primitives_by_entity[entity] = record if entity
          primitives_by_pid[pid.to_s] = record if pid
        end
        Array(mesh[:edges]).each do |edge|
          entity = edge[:_entity] || edge[:entity]
          pid = edge.dig(:source_identity, :persistent_id) || edge[:persistent_id]
          record = [:edge, edge[:id]]
          primitives_by_entity[entity] = record if entity
          primitives_by_pid[pid.to_s] = record if pid
        end
      end

      if nodes && !nodes.empty?
        nodes.each do |node|
          next if node[:kind] == 'root'
          entity = node[:_entity] || node[:entity]
          pid = node.dig(:source_identity, :persistent_id) || node[:persistent_id]
          nodes_by_entity[entity] = node[:id] if entity
          nodes_by_pid[pid.to_s] = node[:id] if pid
        end

        has_drawingelement_visibility = page.respond_to?(:get_drawingelement_visibility)
        nodes.each do |node|
          next if node[:kind] == 'root'
          node_id = node[:id]
          entity = node[:_entity] || node[:entity]
          pid = node.dig(:source_identity, :persistent_id) || node[:persistent_id]

          applies = drawingelement_scene_applicable?(entity, page, is_root: false)
          next unless applies

          base_hidden = (entity.respond_to?(:hidden?) && entity.hidden?) || (node[:visible] == false)

          if entity && has_drawingelement_visibility
            flag = (begin page.get_drawingelement_visibility(entity) rescue nil end)
            if flag == false
              hidden_overrides << node_id
            elsif flag == true && base_hidden
              # Only encode positive visible override if the base element was hidden
              visible_overrides << node_id
            end
          else
            if (entity && hidden_entities_set.include?(entity)) || (pid && hidden_pids_set.include?(pid.to_s))
              hidden_overrides << node_id
            end
          end
        end
      end

      # Match top-level hidden entities from page.hidden_entities
      hidden_entities_list.each do |ent|
        node_id = stores_objects ? (nodes_by_entity[ent] || nodes_by_pid[safe_persistent_id(ent).to_s]) : nil
        primitive = stores_geometry ? (primitives_by_entity[ent] || primitives_by_pid[safe_persistent_id(ent).to_s]) : nil
        if node_id
          hidden_overrides << node_id
        elsif primitive
          (primitive[0] == :face ? result[:hidden_faces] : result[:hidden_edges]) << primitive[1]
        elsif (stores_objects || stores_geometry) && ent.class.to_s !~ /SectionPlane/
          result[:unresolved] << "drawingelement:#{safe_persistent_id(ent)}"
        end
      end

      result.each_value { |values| values.replace(values.compact.map(&:to_s).sort.uniq) }
      result
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
      traverse = lambda do |definition_id, path_stack|
        defn = definitions_by_id[definition_id]
        return unless defn
        child_node_ids = defn[:node_ids] || []
        child_node_ids.each do |nid|
          child_node = nodes_by_id[nid]
          next unless child_node
          if node_visible.call(child_node)
            count += 1
            child_def_id = child_node[:definition_id]
            if child_def_id && !path_stack.include?(child_def_id)
              traverse.call(child_def_id, path_stack + [child_def_id])
            end
          end
        end
      end

      root_def_id = root_node[:definition_id]
      traverse.call(root_def_id, [root_def_id]) if root_def_id
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

      # Check layer folders if supported
      if layer.respond_to?(:folder) && layer.folder
        folder = layer.folder
        if folder.respond_to?(:visible?) && !folder.visible?
          return false
        end
        if page.respond_to?(:layer_folders)
          hidden_folders = (begin page.layer_folders.to_a rescue [] end) || []
          return false if hidden_folders.include?(folder)
        end
      end

      # In official SketchUp API:
      # Page#layers returns layers whose visibility in this page differs from their default visibility.
      # Bit 0x0001 in layer.page_behavior indicates hidden by default on new pages:
      # LAYER_IS_VISIBLE_ON_NEW_PAGES = 0x0000
      # LAYER_IS_HIDDEN_ON_NEW_PAGES  = 0x0001
      page_layers = (begin page.layers.to_a rescue [] end) || []
      in_page_layers = page_layers.include?(layer)

      hidden_by_default = false
      if layer.respond_to?(:page_behavior)
        hidden_by_default = (layer.page_behavior.to_i & 0x0001) != 0
      end

      if hidden_by_default
        # If hidden by default, being in page.layers means it was made VISIBLE on this page
        in_page_layers
      else
        # If visible by default, being in page.layers means it was made HIDDEN on this page
        !in_page_layers
      end
    end

    def effective_entity_visibility(entity, page, parent_visibility: true, is_root: false)
      return false unless parent_visibility
      return false if entity.nil? || (entity.respond_to?(:deleted?) && entity.deleted?)

      # 1. Tag / Layer check
      if entity.respond_to?(:layer) && entity.layer
        return false unless effective_tag_visibility(entity.layer, page)
      end

      # 2. Base visibility
      base_visible = entity.respond_to?(:visible?) ? entity.visible? : true
      base_hidden = entity.respond_to?(:hidden?) ? entity.hidden? : false
      return false if base_hidden || !base_visible if page.nil?

      applies = drawingelement_scene_applicable?(entity, page, is_root: is_root)

      if applies
        # 3. Page DrawingElement query
        if page.respond_to?(:get_drawingelement_visibility)
          flag = (begin page.get_drawingelement_visibility(entity) rescue nil end)
          return false if flag == false
          return true if flag == true
        end

        # 4. Page hidden entities fallback
        if page.respond_to?(:hidden_entities)
          hidden_list = (begin page.hidden_entities.to_a rescue nil end)
          return false if hidden_list && hidden_list.respond_to?(:include?) && hidden_list.include?(entity)
        end
      end

      # 5. Default to base visibility
      return false if base_hidden || !base_visible
      true
    rescue StandardError
      true
    end

    def exportable_universe?(entity, scenes, model: nil, scope: 'active')
      return false if entity.nil? || (entity.respond_to?(:deleted?) && entity.deleted?)

      # If live model / pages are accessible, evaluate directly on pages
      model ||= (entity.respond_to?(:model) ? entity.model : nil)
      pages = model.respond_to?(:pages) ? (model.pages.respond_to?(:to_a) ? model.pages.to_a : Array(model.pages)) : []

      if !pages.empty?
        if scope.to_s == 'all' || scope.to_s == 'union' || scope.to_s == 'all_scenes'
          # Visible if visible in ANY page in model (or base model if none hidden)
          return pages.any? { |page| effective_entity_visibility(entity, page) }
        else
          active_page = model.pages.respond_to?(:selected_page) ? model.pages.selected_page : pages.first
          return effective_entity_visibility(entity, active_page)
        end
      end

      pid = safe_persistent_id(entity)
      tag_id = entity.respond_to?(:layer) && entity.layer ? tag_stable_id(entity.layer) : nil
      base_hidden = (entity.respond_to?(:hidden?) && entity.hidden?) || (entity.respond_to?(:visible?) && !entity.visible?)

      if scope.to_s == 'active' || scope.to_s == 'active_scene'
        active_scene = scenes.find { |s| s[:is_active_at_export] } || scenes.first
        return true if active_scene.nil?

        hidden_nodes = active_scene.dig(:visibility, :hidden_node_overrides) || []
        visible_nodes = active_scene.dig(:visibility, :visible_node_overrides) || []

        if visible_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
          return true
        end

        return false if base_hidden

        if hidden_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
          return false
        end

        if tag_id && active_scene.dig(:visibility, :hidden_tag_ids)&.include?(tag_id)
          return false
        end

        return true
      end

      # scope == 'all' / 'union' / 'all_scenes' (Union of visible across all exported scenes)
      return true if scenes.nil? || scenes.empty?

      visible_in_any = scenes.any? do |scene|
        hidden_nodes = scene.dig(:visibility, :hidden_node_overrides) || []
        visible_nodes = scene.dig(:visibility, :visible_node_overrides) || []

        next true if visible_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
        next false if hidden_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }

        if tag_id
          hidden_tags = scene.dig(:visibility, :hidden_tag_ids) || []
          visible_tags = scene.dig(:visibility, :visible_tag_ids) || []
          if hidden_tags.include?(tag_id)
            false
          elsif visible_tags.include?(tag_id)
            true
          else
            !base_hidden
          end
        else
          !base_hidden
        end
      end

      visible_in_any
    rescue StandardError
      true
    end

    def compute_visibility_signature(visible_tag_ids:, hidden_tag_ids:, visible_node_overrides:, hidden_node_overrides:, active_section_plane_ids:, visible_face_overrides: [], hidden_face_overrides: [], visible_edge_overrides: [], hidden_edge_overrides: [])
      payload = [
        Array(visible_tag_ids).map(&:to_s).sort.uniq,
        Array(hidden_tag_ids).map(&:to_s).sort.uniq,
        Array(visible_node_overrides).map(&:to_s).sort.uniq,
        Array(hidden_node_overrides).map(&:to_s).sort.uniq,
        Array(visible_face_overrides).map(&:to_s).sort.uniq,
        Array(hidden_face_overrides).map(&:to_s).sort.uniq,
        Array(visible_edge_overrides).map(&:to_s).sort.uniq,
        Array(hidden_edge_overrides).map(&:to_s).sort.uniq,
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
      fov_val = is_persp && camera.respond_to?(:fov) ? camera.fov.to_f : nil
      fov_is_height = is_persp && camera.respond_to?(:fov_is_height?) ? camera.fov_is_height? : true
      ortho_height_m = !is_persp && camera.respond_to?(:height) ? (camera.height.to_f * Constants::IN_TO_M).round(9) : nil
      aspect = camera.respond_to?(:aspect_ratio) ? camera.aspect_ratio.to_f : 0.0
      is_2d = camera.respond_to?(:is_2d?) ? camera.is_2d? : false

      {
        projection: is_persp ? 'perspective' : 'orthographic',
        eye_m: point_array(camera.eye),
        target_m: point_array(camera.target),
        up: vector_array(camera.up),
        field_of_view_degrees: fov_val,
        fov_is_height: fov_is_height,
        orthographic_height_m: ortho_height_m,
        aspect_ratio: aspect,
        is_2d: is_2d
      }
    rescue StandardError
      default_camera
    end

    def current_view_camera(model)
      view = model.respond_to?(:active_view) ? model.active_view : nil
      camera = view.respond_to?(:camera) ? view.camera : nil
      return default_camera if camera.nil?

      is_persp = camera.respond_to?(:perspective?) ? camera.perspective? : true
      fov_val = is_persp && camera.respond_to?(:fov) ? camera.fov.to_f : nil
      fov_is_height = is_persp && camera.respond_to?(:fov_is_height?) ? camera.fov_is_height? : true
      ortho_height_m = !is_persp && camera.respond_to?(:height) ? (camera.height.to_f * Constants::IN_TO_M).round(9) : nil
      aspect = camera.respond_to?(:aspect_ratio) ? camera.aspect_ratio.to_f : 0.0
      is_2d = camera.respond_to?(:is_2d?) ? camera.is_2d? : false

      {
        projection: is_persp ? 'perspective' : 'orthographic',
        eye_m: point_array(camera.eye),
        target_m: point_array(camera.target),
        up: vector_array(camera.up),
        field_of_view_degrees: fov_val,
        fov_is_height: fov_is_height,
        orthographic_height_m: ortho_height_m,
        aspect_ratio: aspect,
        is_2d: is_2d
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
        fov_is_height: true,
        orthographic_height_m: nil,
        aspect_ratio: 0.0,
        is_2d: false
      }
    end

    def extract_active_section_planes(page)
      planes = []
      return planes if page.nil?
      if page.respond_to?(:active_section_planes)
        raw = (begin page.active_section_planes.to_a rescue [] end) || []
        raw.each do |plane|
          next if plane.nil?
          if plane.is_a?(String)
            planes << (plane.start_with?('section:') ? plane : "section:#{plane}")
          else
            planes << "section:#{safe_persistent_id(plane)}"
          end
        end
      elsif page.respond_to?(:active_section_plane) && page.active_section_plane
        sp = page.active_section_plane
        if sp.is_a?(String)
          planes << (sp.start_with?('section:') ? sp : "section:#{sp}")
        else
          planes << "section:#{safe_persistent_id(sp)}"
        end
      end
      planes
    rescue StandardError
      []
    end

    def collect_model_clip_planes(model)
      planes = []
      return planes if model.nil?

      # 1. Global / root section planes
      if model.respond_to?(:entities)
        entities = (begin model.entities.to_a rescue [] end) || []
        entities.each do |entity|
          next unless entity.class.to_s =~ /SectionPlane/
          planes << create_clip_plane_record(entity)
        end
      end

      # 2. Nested section planes in definitions
      if model.respond_to?(:definitions)
        defs = (begin model.definitions.to_a rescue [] end) || []
        defs.each do |definition|
          next if definition.respond_to?(:image?) && definition.image?
          def_id = "def:#{safe_persistent_id(definition)}"
          def_entities = (begin definition.entities.to_a rescue [] end) || []
          def_entities.each do |entity|
            next unless entity.class.to_s =~ /SectionPlane/
            planes << create_clip_plane_record(entity, owner_definition_id: def_id)
          end
        end
      end

      planes
    rescue StandardError
      []
    end

    def create_clip_plane_record(plane, owner_definition_id: nil, owner_instance_id: nil)
      pid = safe_persistent_id(plane)
      stable_id = "section:#{pid}"
      orig = [0.0, 0.0, 0.0]
      norm = [0.0, 0.0, 1.0]

      if plane.respond_to?(:get_plane)
        eq = (begin plane.get_plane.to_a rescue nil end)
        if eq && eq.length == 4
          a = eq[0].to_f
          b = eq[1].to_f
          c = eq[2].to_f
          d = eq[3].to_f
          len = Math.sqrt(a * a + b * b + c * c)
          if len > 1e-9
            norm = [(a / len).round(9), (b / len).round(9), (c / len).round(9)]
            d_norm = d / len
            # Point on plane in SketchUp inches: p0 = -d_norm * norm
            # In meters:
            dist_m = d_norm * Constants::IN_TO_M
            orig = [(-norm[0] * dist_m).round(9), (-norm[1] * dist_m).round(9), (-norm[2] * dist_m).round(9)]
          end
        end
      elsif plane.respond_to?(:origin) && plane.respond_to?(:normal)
        orig = point_array(plane.origin)
        norm = vector_array(plane.normal)
      end

      flags = 0
      flags |= 0x01 if plane.respond_to?(:active?) && plane.active?
      flags |= 0x02 if plane.respond_to?(:hidden?) && plane.hidden?

      {
        stable_id: stable_id,
        source_persistent_id: pid,
        origin_m: orig,
        normal: norm,
        plane_constant: (-orig[0] * norm[0] - orig[1] * norm[1] - orig[2] * norm[2]).round(9),
        keep_side: 1,
        owner_definition_id: owner_definition_id,
        owner_instance_id: owner_instance_id,
        flags: flags
      }
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
