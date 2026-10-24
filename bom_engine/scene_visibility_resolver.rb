# bom_engine/scene_visibility_resolver.rb
# Resolves SketchUp Page/Scene visibility semantics and builds CanonicalSceneProfiles.

require 'digest'
require 'json'
require 'set'
require_relative 'constants'
require_relative 'performance_trace'

module BOMEngine
  module SceneVisibilityResolver
    # Job-local cooperative polling. No SDK work moves off the caller's Fiber.
    class WorkCursor
      class CheckpointError < StandardError; end

      def initialize(on_checkpoint:, clock: nil)
        @on_checkpoint = on_checkpoint
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @last_emission = @clock.call if @on_checkpoint
        @pending = 0
        @total = 0
      end

      def step(operation_label)
        return unless @on_checkpoint
        @pending += 1
        @total += 1
        time_due = @clock.call - @last_emission >= 0.006
        # Unit polling checks cancellation/progress without forcing a Windows
        # timer round trip for every tiny batch. The controller still enforces
        # its unchanged time/item budgets; elapsed work forces a timely yield.
        flush(operation_label, force: time_due) if @pending >= 256 || time_due
      end

      def flush(operation_label, force: true)
        return unless @on_checkpoint
        begin
          @on_checkpoint.call(work_units: @pending, operation_label: operation_label, force: force)
        rescue StandardError => error
          raise if PerformanceTrace.cancellation_error?(error)
          raise CheckpointError, "Scene checkpoint failed: #{error.message}", cause: error
        end
        @pending = 0
        @last_emission = @clock.call
      end
    end

    module_function

    def resolve_scenes(model, active_page: nil, nodes: nil, definitions: nil, meshes: nil, capture_context: nil, capture_index: nil, work_cursor: nil)
      PerformanceTrace.stage(:scene_visibility_resolve) do
        context = capture_context || prepare_capture_context(model, active_page: active_page, work_cursor: work_cursor)
        pages_list = context[:pages]
        active = active_page || context[:active_page]
        index = capture_index || build_capture_index(nodes: nodes, definitions: definitions, meshes: meshes, work_cursor: work_cursor)
        PerformanceTrace.increment(:scene_profiles, [pages_list.length, 1].max)

        if pages_list.empty?
          [build_scene_profile(nil, is_active: true, model: model, nodes: nodes, definitions: definitions, meshes: meshes,
            page_context: context[:current_view], clip_planes: context[:clip_planes], capture_index: index, work_cursor: work_cursor)]
        else
          pages_list.map do |page|
            work_cursor&.step('scene_context')
            work_cursor&.flush('scene_context')
            is_active = (page == active)
            profile = build_scene_profile(page, is_active: is_active, model: model, nodes: nodes, definitions: definitions, meshes: meshes,
              page_context: context[:page_contexts][page.object_id], clip_planes: context[:clip_planes], capture_index: index, work_cursor: work_cursor)
            work_cursor&.flush('scene_occurrences')
            profile
          end
        end
      end
    end

    def resolve_effective_scene_visibility(page, model: nil, nodes: nil, definitions: nil, meshes: nil, is_active: false, capture_context: nil, capture_index: nil, work_cursor: nil)
      context = capture_context || prepare_capture_context(model, active_page: (is_active ? page : nil), work_cursor: work_cursor)
      page_context = page.nil? ? context[:current_view] : context[:page_contexts][page.object_id]
      build_scene_profile(page, is_active: is_active, model: model, nodes: nodes, definitions: definitions, meshes: meshes,
        page_context: page_context, clip_planes: context[:clip_planes], capture_index: capture_index, work_cursor: work_cursor)
    end

    def prepare_capture_context(model, active_page: nil, work_cursor: nil)
      pages_collection = model.respond_to?(:pages) ? model.pages : nil
      pages = pages_collection.respond_to?(:to_a) ? pages_collection.to_a : Array(pages_collection)
      active = active_page || (pages_collection.respond_to?(:selected_page) ? pages_collection.selected_page : nil)
      layers = model && model.respond_to?(:layers) ? model.layers.to_a : []
      page_contexts = {}
      pages.each do |page|
        work_cursor&.step('scene_context')
        page_contexts[page.object_id] = prepare_page_context(page, layers, work_cursor: work_cursor)
      end
      current_view = prepare_page_context(nil, layers, work_cursor: work_cursor)
      clip_planes = PerformanceTrace.stage(:clip_plane_collection) { collect_model_clip_planes(model, work_cursor: work_cursor) }
      work_cursor&.flush('scene_context')
      PerformanceTrace.increment(:scene_capture_context_builds, 1)
      {
        pages: pages,
        active_page: active,
        page_contexts: page_contexts,
        current_view: current_view,
        clip_planes: clip_planes
      }
    end

    def prepare_page_context(page, layers, work_cursor: nil)
      visible_tag_ids = []
      hidden_tag_ids = []
      tag_visibility_by_object_id = {}
      layers.each do |layer|
        work_cursor&.step('scene_context')
        visible = page.nil? ? live_tag_visibility(layer) : effective_tag_visibility(layer, page)
        tag_visibility_by_object_id[layer.object_id] = visible
        (visible ? visible_tag_ids : hidden_tag_ids) << tag_stable_id(layer)
      end
      PerformanceTrace.increment(:scene_tag_visibility_queries, layers.length)

      hidden_entities = if page && page.respond_to?(:hidden_entities)
                          begin
                            (page.hidden_entities.to_a rescue []) || []
                          rescue StandardError
                            []
                          end
                        else
                          []
                        end
      work_cursor&.flush('scene_context')
      PerformanceTrace.increment(:scene_hidden_entity_rows, hidden_entities.length)
      {
        visible_tag_ids: visible_tag_ids.sort.uniq,
        hidden_tag_ids: hidden_tag_ids.sort.uniq,
        tag_visibility_by_object_id: tag_visibility_by_object_id,
        hidden_entities: hidden_entities,
        hidden_entities_set: hidden_entities.to_set,
        hidden_pids_set: hidden_entities.map { |entity| work_cursor&.step('scene_context'); safe_persistent_id(entity).to_s }.to_set.tap { work_cursor&.flush('scene_context') },
        drawing_visibility: {},
        camera: page.nil? ? nil : extract_page_camera(page),
        active_section_plane_ids: page.nil? ? [] : extract_active_section_planes(page),
        section_rendering_state: page.nil? ? { section_cuts_displayed: false, section_planes_displayed: false } : extract_section_rendering_state(page)
      }
    end
    private_class_method :prepare_page_context

    def build_capture_index(nodes: nil, definitions: nil, meshes: nil, work_cursor: nil)
      index = {
        nodes_by_entity: {}, nodes_by_pid: {}, primitives_by_entity: {}, primitives_by_pid: {},
        nodes_by_id: {}, definitions_by_id: {}
      }
      Array(nodes).each do |node|
        work_cursor&.step('scene_index')
        index[:nodes_by_id][node[:id]] = node
        next if node[:kind] == 'root'

        entity = node[:_entity] || node[:entity]
        pid = node.dig(:source_identity, :persistent_id) || node[:persistent_id]
        index[:nodes_by_entity][entity] = node[:id] if entity
        index[:nodes_by_pid][pid.to_s] = node[:id] if pid
      end
      Array(definitions).each do |definition|
        work_cursor&.step('scene_index')
        index[:definitions_by_id][definition[:id]] = definition
      end
      Array(meshes).each do |mesh|
        work_cursor&.step('scene_index')
        Array(mesh[:faces]).each do |face|
          work_cursor&.step('scene_index')
          entity = face[:_entity] || face[:entity]
          pid = face.dig(:source_identity, :persistent_id) || face[:persistent_id]
          record = [:face, face[:id]]
          index[:primitives_by_entity][entity] = record if entity
          index[:primitives_by_pid][pid.to_s] = record if pid
        end
        Array(mesh[:edges]).each do |edge|
          work_cursor&.step('scene_index')
          entity = edge[:_entity] || edge[:entity]
          pid = edge.dig(:source_identity, :persistent_id) || edge[:persistent_id]
          record = [:edge, edge[:id]]
          index[:primitives_by_entity][entity] = record if entity
          index[:primitives_by_pid][pid.to_s] = record if pid
        end
      end
      work_cursor&.flush('scene_index')
      PerformanceTrace.increment(:scene_capture_index_builds, 1)
      PerformanceTrace.increment(:scene_capture_index_nodes, index[:nodes_by_id].length)
      PerformanceTrace.increment(:scene_capture_index_primitives, index[:primitives_by_entity].length)
      index
    end

    def build_scene_profile(page, is_active: false, model: nil, nodes: nil, definitions: nil, meshes: nil,
      page_context: nil, clip_planes: nil, capture_index: nil, work_cursor: nil)
      context = page_context || prepare_page_context(page, model && model.respond_to?(:layers) ? model.layers.to_a : [], work_cursor: work_cursor)
      if page.nil?
        camera_data = current_view_camera(model)
        visible_tag_ids = context[:visible_tag_ids]
        hidden_tag_ids = context[:hidden_tag_ids]
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
            section_cuts_displayed: false,
            section_planes_displayed: false,
            rendering_support: 'metadata-only'
          },
          visibility_signature: signature
        }
        if nodes && !nodes.empty?
          profile[:effective_visible_occurrence_count] = calculate_effective_visible_occurrences(nodes, definitions, profile, capture_index: capture_index, work_cursor: work_cursor)
        end
        return profile
      end

      page_pid = safe_persistent_id(page)
      scene_id = "scene:doc:#{page_pid}"
      camera_data = context[:camera] || extract_page_camera(page)
      stores_tags = page.respond_to?(:use_hidden_layers?) ? page.use_hidden_layers? : true
      stores_objects = page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : (page.respond_to?(:use_hidden?) ? page.use_hidden? : true)
      stores_geometry = page.respond_to?(:use_hidden_geometry?) ? page.use_hidden_geometry? : false
      stores_sections = page.respond_to?(:use_section_planes?) ? page.use_section_planes? : true

      visible_tag_ids = context[:visible_tag_ids]
      hidden_tag_ids = context[:hidden_tag_ids]

      # DrawingElement visibility overrides
      overrides = extract_visibility_overrides(page, nodes, meshes, capture_index: capture_index, page_context: context, work_cursor: work_cursor)
      visible_node_overrides = overrides[:visible_nodes]
      hidden_node_overrides = overrides[:hidden_nodes]
      active_section_plane_ids = context[:active_section_plane_ids]
      section_rendering_state = context[:section_rendering_state]
      section_cuts_displayed = section_rendering_state[:section_cuts_displayed]

      model_clip_planes = clip_planes || collect_model_clip_planes(model, work_cursor: work_cursor)
      rendering_support = 'none'
      if !active_section_plane_ids.empty?
        all_resolved = active_section_plane_ids.all? do |sid|
          cp = model_clip_planes.find { |p| p[:stable_id] == sid }
          cp && cp[:owner_definition_id].nil?
        end
        rendering_support = all_resolved && section_cuts_displayed ? 'full' : 'metadata-only'
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
        active_section_plane_ids: active_section_plane_ids,
        section_cuts_displayed: section_cuts_displayed,
        section_planes_displayed: section_rendering_state[:section_planes_displayed]
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
          section_cuts_displayed: section_cuts_displayed,
          section_planes_displayed: section_rendering_state[:section_planes_displayed],
          rendering_support: rendering_support
        },
        visibility_signature: signature,
        scene_diagnostics: overrides[:diagnostics]
      }

      if nodes && !nodes.empty?
        profile[:effective_visible_occurrence_count] = calculate_effective_visible_occurrences(nodes, definitions, profile, capture_index: capture_index, work_cursor: work_cursor)
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
        parent = entity.respond_to?(:parent) ? entity.parent : nil
        is_root_entity = is_root || (parent && (parent.is_a?(Sketchup::Model) rescue false))
        stores_geometry && is_root_entity
      end
    end

    def extract_node_overrides(page, model, nodes = nil)
      overrides = extract_visibility_overrides(page, nodes, nil)
      [overrides[:visible_nodes], overrides[:hidden_nodes]]
    end

    def extract_visibility_overrides(page, nodes = nil, meshes = nil, capture_index: nil, page_context: nil, work_cursor: nil)
      visible_overrides = []
      hidden_overrides = []
      result = {
        visible_nodes: visible_overrides, hidden_nodes: hidden_overrides,
        visible_faces: [], hidden_faces: [], visible_edges: [], hidden_edges: [], unresolved: [], diagnostics: []
      }
      return result if page.nil?

      stores_objects = page.respond_to?(:use_hidden_objects?) ? page.use_hidden_objects? : (page.respond_to?(:use_hidden?) ? page.use_hidden? : true)
      stores_geometry = page.respond_to?(:use_hidden_geometry?) ? page.use_hidden_geometry? : false

      context = page_context || prepare_page_context(page, [], work_cursor: work_cursor)
      hidden_entities_list = context[:hidden_entities]
      hidden_entities_set = context[:hidden_entities_set]
      hidden_pids_set = context[:hidden_pids_set]
      index = capture_index || build_capture_index(nodes: nodes, definitions: nil, meshes: meshes, work_cursor: work_cursor)
      nodes_by_entity = index[:nodes_by_entity]
      nodes_by_pid = index[:nodes_by_pid]
      primitives_by_entity = index[:primitives_by_entity]
      primitives_by_pid = index[:primitives_by_pid]

      if nodes && !nodes.empty?
        has_drawingelement_visibility = page.respond_to?(:get_drawingelement_visibility)
        node_visibility_queries = 0
        nodes.each do |node|
          work_cursor&.step('scene_overrides')
          next if node[:kind] == 'root'
          node_id = node[:id]
          entity = node[:_entity] || node[:entity]
          pid = node.dig(:source_identity, :persistent_id) || node[:persistent_id]

          applies = drawingelement_scene_applicable?(entity, page, is_root: false)
          next unless applies

          base_hidden = (entity.respond_to?(:hidden?) && entity.hidden?) || (node[:visible] == false)

          if entity && has_drawingelement_visibility
            begin
              flag, queried = drawingelement_visibility(page, entity, context)
              node_visibility_queries += 1 if queried
            rescue StandardError => error
              result[:diagnostics] << extraction_failure(page, entity, :drawingelement_visibility, error, :base_visibility)
              flag = nil
            end
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
        PerformanceTrace.increment(:scene_node_visibility_queries, node_visibility_queries)
      end

      # Faces and edges are DrawingElements too, but only top-level geometry is
      # independently scene-controlled. Preserve both negative and positive
      # page overrides without treating nested definition geometry as scoped.
      if stores_geometry && page.respond_to?(:get_drawingelement_visibility)
        primitive_visibility_queries = 0
        primitives_by_entity.each do |entity, primitive|
          work_cursor&.step('scene_overrides')
          next unless entity && drawingelement_scene_applicable?(entity, page, is_root: false)
          base_hidden = (entity.respond_to?(:hidden?) && entity.hidden?) || (entity.respond_to?(:visible?) && !entity.visible?)
          begin
            flag, queried = drawingelement_visibility(page, entity, context)
            primitive_visibility_queries += 1 if queried
            if flag == false
              (primitive[0] == :face ? result[:hidden_faces] : result[:hidden_edges]) << primitive[1]
            elsif flag == true && base_hidden
              (primitive[0] == :face ? result[:visible_faces] : result[:visible_edges]) << primitive[1]
            end
          rescue StandardError => error
            result[:diagnostics] << extraction_failure(page, entity, :primitive_drawingelement_visibility, error, :base_visibility)
          end
        end
        PerformanceTrace.increment(:scene_primitive_visibility_queries, primitive_visibility_queries)
      end

      # Match top-level hidden entities from page.hidden_entities
      hidden_entities_list.each do |ent|
        work_cursor&.step('scene_overrides')
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

      work_cursor&.flush('scene_overrides')
      result.each do |key, values|
        next if key == :diagnostics
        values.replace(values.compact.map(&:to_s).sort.uniq)
      end
      result
    end

    def calculate_effective_visible_occurrences(nodes, definitions, scene, capture_index: nil, work_cursor: nil)
      return 0 if nodes.nil? || nodes.empty?

      hidden_nodes = Array(scene.dig(:visibility, :hidden_node_overrides)).to_set
      visible_nodes = Array(scene.dig(:visibility, :visible_node_overrides)).to_set
      hidden_tags = Array(scene.dig(:visibility, :hidden_tag_ids)).to_set
      visible_tags = Array(scene.dig(:visibility, :visible_tag_ids)).to_set
      stores_tags = scene[:stores_tag_visibility] != false

      index = capture_index || build_capture_index(nodes: nodes, definitions: definitions, meshes: nil, work_cursor: work_cursor)
      nodes_by_id = index[:nodes_by_id]
      definitions_by_id = index[:definitions_by_id]

      root_node = nodes.find { |n| work_cursor&.step('scene_occurrences'); n[:kind] == 'root' }
      return nodes.count { |n| work_cursor&.step('scene_occurrences'); n[:visible] != false } if root_node.nil?

      node_visible = lambda do |node|
        return false if hidden_nodes.include?(node[:id])
        pid = node.dig(:source_identity, :persistent_id) || node[:persistent_id]
        return false if pid && (hidden_nodes.include?(pid.to_s) || hidden_nodes.include?("node:pid:#{pid}"))
        tag_id = node[:tag_id]
        if stores_tags && tag_id
          return false if hidden_tags.include?(tag_id)
          return true if visible_tags.include?(tag_id)
        end
        return true if visible_nodes.include?(node[:id])
        return true if pid && (visible_nodes.include?(pid.to_s) || visible_nodes.include?("node:pid:#{pid}"))
        node[:visible] != false
      end

      count = 0
      traverse = lambda do |definition_id, path_stack|
        defn = definitions_by_id[definition_id]
        return unless defn
        child_node_ids = defn[:node_ids] || []
        child_node_ids.each do |nid|
          work_cursor&.step('scene_occurrences')
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
      work_cursor&.flush('scene_occurrences')
      count
    end

    def page_selected?(page)
      return false if page.nil? || !page.respond_to?(:parent)

      pages = page.parent
      pages && pages.respond_to?(:selected_page) && pages.selected_page.equal?(page)
    rescue StandardError
      false
    end

    def layer_folder_chain(layer)
      folders = []
      folder = layer.respond_to?(:folder) ? layer.folder : nil
      seen = {}
      while folder && !seen[folder.object_id]
        seen[folder.object_id] = true
        folders << folder
        folder = folder.respond_to?(:folder) ? folder.folder : nil
      end
      folders
    rescue StandardError
      []
    end

    def live_tag_visibility(layer)
      return true if layer.nil?
      return false if layer.respond_to?(:visible?) && !layer.visible?

      layer_folder_chain(layer).all? do |folder|
        !folder.respond_to?(:visible?) || folder.visible?
      end
    rescue StandardError
      true
    end

    def effective_tag_visibility(layer, page)
      return true if layer.nil?

      # SketchUp exposes the currently selected Page through live Layer / LayerFolder
      # state. Page#layers and Page#layer_folders are snapshots for other Pages, so
      # never let the selected Page's current folder state veto another Scene.
      return live_tag_visibility(layer) if page.nil? || page_selected?(page)

      # A Page that does not store tag visibility inherits the current/live model state.
      if page.respond_to?(:use_hidden_layers?) && !page.use_hidden_layers?
        return live_tag_visibility(layer)
      end

      folder_chain = layer_folder_chain(layer)
      if page.respond_to?(:layer_folders)
        hidden_folders = (begin page.layer_folders.to_a rescue [] end) || []
        return false if folder_chain.any? { |folder| hidden_folders.include?(folder) }
      end

      # Page#layers contains tags whose Page visibility differs from their default.
      # Bit 0x0001 means hidden by default on new Pages.
      page_layers = (begin page.layers.to_a rescue [] end) || []
      in_page_layers = page_layers.include?(layer)
      hidden_by_default = layer.respond_to?(:page_behavior) && (layer.page_behavior.to_i & 0x0001) != 0

      hidden_by_default ? in_page_layers : !in_page_layers
    rescue StandardError
      live_tag_visibility(layer)
    end

    def drawingelement_visibility(page, entity, page_context = nil)
      cache = page_context && page_context[:drawing_visibility]
      key = entity.object_id
      if cache && cache.key?(key)
        PerformanceTrace.increment(:scene_drawing_visibility_cache_hits, 1)
        return [cache[key], false]
      end

      value = page.get_drawingelement_visibility(entity)
      cache[key] = value if cache
      [value, true]
    end
    private_class_method :drawingelement_visibility

    def effective_entity_visibility(entity, page, parent_visibility: true, is_root: false, diagnostics: nil, page_context: nil)
      return false unless parent_visibility
      return false if entity.nil? || (entity.respond_to?(:deleted?) && entity.deleted?)

      # 1. Tag / Layer check
      if entity.respond_to?(:layer) && entity.layer
        visible = if page_context && page_context[:tag_visibility_by_object_id].key?(entity.layer.object_id)
                    page_context[:tag_visibility_by_object_id][entity.layer.object_id]
                  else
                    effective_tag_visibility(entity.layer, page)
                  end
        return false unless visible
      end

      # 2. Base visibility
      base_visible = entity.respond_to?(:visible?) ? entity.visible? : true
      base_hidden = entity.respond_to?(:hidden?) ? entity.hidden? : false
      return false if base_hidden || !base_visible if page.nil?

      applies = drawingelement_scene_applicable?(entity, page, is_root: is_root)

      if applies
        # 3. Page DrawingElement query
        if page.respond_to?(:get_drawingelement_visibility)
          begin
            flag, queried = drawingelement_visibility(page, entity, page_context)
            PerformanceTrace.increment(:scene_entity_visibility_queries, 1) if queried
          rescue StandardError => error
            diagnostics << extraction_failure(page, entity, :drawingelement_visibility, error, :base_visibility) if diagnostics
            flag = nil
          end
          return false if flag == false
          return true if flag == true
        end

        # 4. Page hidden entities fallback
        if page_context
          return false if page_context[:hidden_entities_set].include?(entity) ||
            page_context[:hidden_pids_set].include?(safe_persistent_id(entity).to_s)
        elsif page.respond_to?(:hidden_entities)
          begin
            hidden_list = page.hidden_entities.to_a
          rescue StandardError => error
            diagnostics << extraction_failure(page, entity, :hidden_entities, error, :base_visibility) if diagnostics
            hidden_list = nil
          end
          return false if hidden_list && hidden_list.respond_to?(:include?) && hidden_list.include?(entity)
        end
      end

      # 5. Default to base visibility
      return false if base_hidden || !base_visible
      true
    rescue StandardError => error
      diagnostics << extraction_failure(page, entity, :effective_entity_visibility, error, :retain_conservatively) if diagnostics
      true
    end

    def exportable_universe?(entity, scenes, model: nil, scope: 'active', capture_context: nil)
      return false if entity.nil? || (entity.respond_to?(:deleted?) && entity.deleted?)

      # If live model / pages are accessible, evaluate directly on pages
      model ||= (entity.respond_to?(:model) ? entity.model : nil)
      pages = if capture_context
                capture_context[:pages]
              else
                model.respond_to?(:pages) ? (model.pages.respond_to?(:to_a) ? model.pages.to_a : Array(model.pages)) : []
              end

      if !pages.empty?
        if scope.to_s == 'all' || scope.to_s == 'union' || scope.to_s == 'all_scenes'
          # Visible if visible in ANY page in model (or base model if none hidden)
          return pages.any? do |page|
            context = capture_context && capture_context[:page_contexts][page.object_id]
            effective_entity_visibility(entity, page, page_context: context)
          end
        else
          active_page = if capture_context
                          capture_context[:active_page] || pages.first
                        else
                          model.pages.respond_to?(:selected_page) ? model.pages.selected_page : pages.first
                        end
          context = capture_context && capture_context[:page_contexts][active_page.object_id]
          return effective_entity_visibility(entity, active_page, page_context: context)
        end
      end

      # No saved Pages means the exported universe is the current model view.
      # Reusing the prepared current-view context must still honor each
      # entity's base Hidden/Visible state; scene-scope caching cannot turn a
      # hidden source entity into visible geometry.
      if capture_context && capture_context[:current_view]
        return effective_entity_visibility(entity, nil, page_context: capture_context[:current_view])
      end

      pid = safe_persistent_id(entity)
      tag_id = entity.respond_to?(:layer) && entity.layer ? tag_stable_id(entity.layer) : nil
      base_hidden = (entity.respond_to?(:hidden?) && entity.hidden?) || (entity.respond_to?(:visible?) && !entity.visible?)

      if scope.to_s == 'active' || scope.to_s == 'active_scene'
        active_scene = scenes.find { |s| s[:is_active_at_export] } || scenes.first
        return true if active_scene.nil?

        hidden_nodes = active_scene.dig(:visibility, :hidden_node_overrides) || []
        visible_nodes = active_scene.dig(:visibility, :visible_node_overrides) || []

        if tag_id && active_scene.dig(:visibility, :hidden_tag_ids)&.include?(tag_id)
          return false
        end
        if visible_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
          return true
        end
        return false if base_hidden
        if hidden_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
          return false
        end

        return true
      end

      # scope == 'all' / 'union' / 'all_scenes' (Union of visible across all exported scenes)
      return true if scenes.nil? || scenes.empty?

      visible_in_any = scenes.any? do |scene|
        hidden_nodes = scene.dig(:visibility, :hidden_node_overrides) || []
        visible_nodes = scene.dig(:visibility, :visible_node_overrides) || []
        hidden_tags = scene.dig(:visibility, :hidden_tag_ids) || []
        next false if tag_id && hidden_tags.include?(tag_id)
        next true if visible_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
        next false if hidden_nodes.any? { |id| id == pid || id == "node:pid:#{pid}" || id.end_with?(":#{pid}") }
        # A visible tag only admits an otherwise visible entity. In a model
        # without Pages it cannot override the entity's own Hidden flag.
        !base_hidden
      end

      visible_in_any
    end

    def compute_visibility_signature(visible_tag_ids:, hidden_tag_ids:, visible_node_overrides:, hidden_node_overrides:, active_section_plane_ids:, section_cuts_displayed: false, section_planes_displayed: false, visible_face_overrides: [], hidden_face_overrides: [], visible_edge_overrides: [], hidden_edge_overrides: [])
      payload = [
        Array(visible_tag_ids).map(&:to_s).sort.uniq,
        Array(hidden_tag_ids).map(&:to_s).sort.uniq,
        Array(visible_node_overrides).map(&:to_s).sort.uniq,
        Array(hidden_node_overrides).map(&:to_s).sort.uniq,
        Array(visible_face_overrides).map(&:to_s).sort.uniq,
        Array(hidden_face_overrides).map(&:to_s).sort.uniq,
        Array(visible_edge_overrides).map(&:to_s).sort.uniq,
        Array(hidden_edge_overrides).map(&:to_s).sort.uniq,
        Array(active_section_plane_ids).map(&:to_s).sort.uniq,
        section_cuts_displayed == true,
        section_planes_displayed == true
      ]
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def build_fidelity_manifest(scenes, clip_planes)
      planes = Array(clip_planes)
      Array(scenes).map do |scene|
        visibility = scene[:visibility] || {}
        active_ids = Array(scene.dig(:section_state, :active_section_plane_ids)).map(&:to_s).sort
        active_planes = planes.select { |plane| active_ids.include?(plane[:stable_id].to_s) || active_ids.include?(plane[:source_persistent_id].to_s) }
        {
          scene_id: scene[:id].to_s,
          camera_hash: Digest::SHA256.hexdigest(JSON.generate(scene[:camera] || {})),
          visible_tag_hash: Digest::SHA256.hexdigest(JSON.generate([visibility[:visible_tag_ids], visibility[:hidden_tag_ids]])),
          effective_occurrence_visibility_hash: Digest::SHA256.hexdigest(JSON.generate([
            visibility[:visible_node_overrides], visibility[:hidden_node_overrides],
            visibility[:visible_face_overrides], visibility[:hidden_face_overrides],
            visibility[:visible_edge_overrides], visibility[:hidden_edge_overrides]
          ])),
          primitive_visibility_hash: Digest::SHA256.hexdigest(JSON.generate([
            visibility[:visible_face_overrides], visibility[:hidden_face_overrides],
            visibility[:visible_edge_overrides], visibility[:hidden_edge_overrides]
          ])),
          active_section_plane_ids: active_ids,
          active_clip_indices: active_planes.map { |plane| planes.index(plane) },
          clip_plane_equation_hash: Digest::SHA256.hexdigest(JSON.generate(active_planes.map { |plane| [plane[:stable_id], plane[:origin_m], plane[:normal], plane[:plane_constant], plane[:keep_side]] })),
          rendering_support: scene.dig(:section_state, :rendering_support).to_s,
          section_cuts_displayed: scene.dig(:section_state, :section_cuts_displayed) == true,
          unresolved_scene_semantics_count: Array(visibility[:unresolved_primitive_overrides]).length + Array(scene[:scene_diagnostics]).length
        }
      end
    end

    def extraction_failure(page, entity, operation, error, fallback)
      {
        stage: 'scene_visibility_extraction',
        entity_identity: entity.nil? ? nil : safe_persistent_id(entity),
        scene_identity: page.nil? ? nil : safe_persistent_id(page),
        api_operation: operation.to_s,
        error_class: error.class.name,
        error_message: error.message.to_s,
        fallback_decision: fallback.to_s
      }
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
      # Page#active_section_planes is stored Page state. Current model state
      # must not leak when this Page does not store section planes.
      return planes if page.respond_to?(:use_section_planes?) && !page.use_section_planes?
      if page.respond_to?(:active_section_planes)
        stored = (begin page.active_section_planes rescue nil end)
        raw = stored.nil? ? [] : (begin stored.to_a rescue [] end)
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
      PerformanceTrace.increment(:clip_plane_records, planes.length)
      planes
    rescue StandardError
      []
    end

    def extract_section_rendering_state(page)
      return { section_cuts_displayed: false, section_planes_displayed: false } unless page.respond_to?(:use_rendering_options?) && page.use_rendering_options?
      return { section_cuts_displayed: false, section_planes_displayed: false } unless page.respond_to?(:rendering_options)

      options = page.rendering_options
      {
        section_cuts_displayed: options['DisplaySectionCuts'] == true,
        section_planes_displayed: options['DisplaySectionPlanes'] == true
      }
    rescue StandardError
      { section_cuts_displayed: false, section_planes_displayed: false }
    end

    def collect_model_clip_planes(model, work_cursor: nil)
      planes = []
      return planes if model.nil?

      # 1. Global / root section planes
      if model.respond_to?(:entities)
        entities = (begin model.entities.to_a rescue [] end) || []
        entities.each do |entity|
          work_cursor&.step('scene_clips')
          next unless entity.class.to_s =~ /SectionPlane/
          planes << create_clip_plane_record(entity)
        end
      end

      # 2. Nested section planes in definitions
      if model.respond_to?(:definitions)
        defs = (begin model.definitions.to_a rescue [] end) || []
        defs.each do |definition|
          work_cursor&.step('scene_clips')
          next if definition.respond_to?(:image?) && definition.image?
          def_id = "def:#{safe_persistent_id(definition)}"
          def_entities = (begin definition.entities.to_a rescue [] end) || []
          def_entities.each do |entity|
            work_cursor&.step('scene_clips')
            next unless entity.class.to_s =~ /SectionPlane/
            planes << create_clip_plane_record(entity, owner_definition_id: def_id)
          end
        end
      end

      work_cursor&.flush('scene_clips')
      planes
    rescue StandardError => error
      raise if PerformanceTrace.cancellation_error?(error) || error.is_a?(WorkCursor::CheckpointError)
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
