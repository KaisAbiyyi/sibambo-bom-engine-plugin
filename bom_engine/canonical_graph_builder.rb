# bom_engine/canonical_graph_builder.rb
# Builds the semantic, definition-local graph used by canonical JSON v3 and BOME2.

require 'time'
require_relative 'classifier'
require_relative 'traversal'
require_relative 'semantic_labeler'
require_relative 'scene_visibility_resolver'
require_relative 'performance_trace'

module BOMEngine
  module CanonicalGraphBuilder
    FORMAT_NAME = 'BOM Engine Canonical'.freeze
    FORMAT_VERSION = '3.0.0'.freeze
    SCHEMA_URI = 'https://sibambo.dev/schemas/bom-engine/3.0.0/schema.json'.freeze

    def self.build(model:, entities:, parent_transform:, settings:, spatial:, texture_writer: nil, progress: nil, batch_size: 24)
      Builder.new(
        model: model,
        settings: settings,
        spatial: spatial,
        texture_writer: texture_writer,
        progress: progress,
        batch_size: batch_size
      ).build(entities, parent_transform)
    end

    class Builder
      def initialize(model:, settings:, spatial:, texture_writer:, progress: nil, batch_size: 24)
        @model = model
        @settings = settings || {}
        @spatial = spatial || {}
        @texture_writer = texture_writer
        @scene_scope = (@settings[:scene_scope] || 'all').to_s
        @preserve_hidden_geometry = @settings[:preserve_hidden_geometry] == true
        @progress = progress
        @batch_size = [batch_size.to_i, 1].max
        @work_count = 0
        @scene_work_cursor = if @progress
          SceneVisibilityResolver::WorkCursor.new(on_checkpoint: lambda do |event|
            @work_count += event[:work_units]
            @progress.call(stage: 'Resolving scene visibility', processed: @work_count,
              force: true, operation_label: event[:operation_label])
          end)
        end
        @scene_context = PerformanceTrace.stage(:canonical_initial_scene_visibility) do
          SceneVisibilityResolver.prepare_capture_context(@model, work_cursor: @scene_work_cursor)
        end
        @exportable_cache = {}
        @definitions = []
        @definition_index = {}
        @meshes = []
        @nodes = []
        @transforms = []
        @transform_index = {}
        @materials = []
        @material_ids = {}
        @tags = []
        @tag_ids = {}
        @attached_labels = Hash.new { |hash, key| hash[key] = [] }
        @skipped = Hash.new(0)
        @statistics = {
          component_instances: 0,
          group_instances: 0,
          faces: 0,
          unique_vertices: 0,
          labeled_nodes: 0,
          label_role_nodes: 0,
          geometry_fallback_nodes: 0
        }
      end

      def build(entities, parent_transform)
        checkpoint('Preparing model tables', force: true)
        PerformanceTrace.stage(:canonical_label_index) { index_attached_labels(@model.entities) }
        PerformanceTrace.stage(:canonical_tags) { build_tags }
        PerformanceTrace.stage(:canonical_materials) { build_materials }
        identity_transform_id = intern_transform(Geom::Transformation.new)
        root_definition_id = root_definition_id()
        root_definition = PerformanceTrace.stage(:canonical_geometry_capture) do
          build_definition(
            id: root_definition_id,
            name: @settings[:selection_only] ? 'Selection Root' : 'Model Root',
            entities: entities,
            source_identity: model_source_identity,
            kind: 'root'
          )
        end
        root_transform_id = intern_transform(parent_transform || Geom::Transformation.new)
        root_node = {
          id: 'node:root',
          kind: 'root',
          name: root_definition[:name],
          owner_definition_id: nil,
          definition_id: root_definition_id,
          transform_id: root_transform_id,
          material_override_id: nil,
          tag_id: nil,
          source_identity: model_source_identity,
          attributes: {},
          semantic: SemanticLabeler.empty_semantic
        }
        @nodes.unshift(root_node)
        record_node_statistics(root_node)

        checkpoint('Finalizing canonical graph', force: true)
        scenes = PerformanceTrace.stage(:canonical_scene_visibility, sample_resources: true) { build_scenes }
        clip_planes = @scene_context[:clip_planes]
        statistics = PerformanceTrace.stage(:canonical_statistics) { build_statistics(identity_transform_id) }
        PerformanceTrace.increment(:canonical_work_items, @work_count)
        result = {
          format: {
            name: FORMAT_NAME,
            version: FORMAT_VERSION,
            schema: SCHEMA_URI,
            generator: {
              name: 'BOM Engine SketchUp Exporter',
              version: plugin_version
            }
          },
          source: build_source,
          units: {
            source_length_unit: source_unit_name,
            geometry_length_unit: 'meter',
            area_unit: 'square_meter',
            angle_unit: source_angle_unit
          },
          coordinate_system: {
            handedness: 'right',
            up_axis: '+Z',
            forward_axis: '-Y',
            x_axis: '+X',
            storage: 'SketchUp world axes; definition geometry is local',
            threejs_mapping: '{x,y,z}->{x,z,-y}'
          },
          metadata: build_metadata,
          tags: @tags,
          materials: @materials,
          transforms: @transforms,
          meshes: @meshes,
          definitions: @definitions,
          nodes: @nodes,
          scenes: scenes,
          clip_planes: clip_planes,
          scene_fidelity_manifest: SceneVisibilityResolver.build_fidelity_manifest(scenes, clip_planes),
          spaces: extract_spaces,
          relationships: build_relationships,
          analysis: @spatial,
          statistics: statistics
        }
        checkpoint('Canonical graph ready', force: true)
        result
      end

      private

      def build_definition(id:, name:, entities:, source_identity:, kind:, description: '', attributes: {})
        existing = @definition_index[id]
        return existing unless existing.nil?

        captured_entities = capture_entities(entities)
        definition = {
          id: id,
          kind: kind,
          name: name.to_s,
          description: description.to_s,
          source_identity: source_identity,
          mesh_id: nil,
          node_ids: [],
          bounds_m: bounds_for_entities(entities, captured_entities),
          attributes: attributes || {}
        }
        @definition_index[id] = definition
        @definitions << definition

        mesh = build_mesh(id, captured_entities)
        if mesh
          definition[:mesh_id] = mesh[:id]
          @meshes << mesh
        end

        captured_entities.each do |kind, entity|
          case kind
          when :group
            child_definition_id = group_definition_id(entity)
            build_definition(
              id: child_definition_id,
              name: entity.name.to_s.empty? ? '(Group)' : entity.name,
              entities: entity.entities,
              source_identity: definition_source_identity(entity.definition),
              kind: 'group_definition',
              attributes: Traversal.extract_dicts(entity.definition)
            )
            node = build_instance_node(entity, id, child_definition_id, 'group_instance')
            append_node(node)
            definition[:node_ids] << node[:id]
          when :component_instance
            component_definition = entity.definition
            child_definition_id = component_definition_id(component_definition)
            build_definition(
              id: child_definition_id,
              name: component_definition.name,
              description: component_definition.description,
              entities: component_definition.entities,
              source_identity: definition_source_identity(component_definition),
              kind: 'component_definition',
              attributes: Traversal.extract_dicts(component_definition)
            )
            node = build_instance_node(entity, id, child_definition_id, 'component_instance')
            node[:definition_name] = component_definition.name
            node[:dynamic_attributes] = Traversal.extract_dynamic_attrs(entity)
            append_node(node)
            definition[:node_ids] << node[:id]
          when :image
            node = build_image_node(entity, id)
            append_node(node)
            definition[:node_ids] << node[:id]
          when :text
            node = build_text_node(entity, id)
            if node
              append_node(node)
              definition[:node_ids] << node[:id]
            end
          end
        end

        definition
      end

      def build_mesh(definition_id, captured_entities)
        positions = []
        position_index = {}
        bounds_accumulator = new_bounds_accumulator
        faces = []
        edges = []

        captured_entities.each do |kind, entity|
          case kind
          when :face
            faces << build_face(entity, positions, position_index, bounds_accumulator)
          when :edge
            next unless @settings[:include_edges]
            edges << build_edge(entity, positions, position_index, bounds_accumulator)
          end
        end

        return nil if faces.empty? && edges.empty?

        {
          id: "mesh:#{definition_id}",
          definition_id: definition_id,
          coordinate_space: 'definition_local',
          positions_m: positions,
          faces: faces,
          edges: edges,
          bounds_m: bounds_from_accumulator(bounds_accumulator)
        }
      ensure
        unless faces.nil?
          @statistics[:faces] += faces.length
          @statistics[:unique_vertices] += positions.length / 3 if positions
        end
      end

      def build_face(face, positions, position_index, bounds_accumulator = nil)
        outer_loop = face.outer_loop
        loops = face.loops
        outer_vertices = outer_loop.vertices
        hole_vertex_rows = loops.reject(&:outer?).map(&:vertices)
        outer = outer_vertices.map do |vertex|
          checkpoint('Reading face vertices')
          intern_position(vertex.position, positions, position_index, bounds_accumulator)
        end
        holes = hole_vertex_rows.map do |vertices|
          vertices.map do |vertex|
            checkpoint('Reading face vertices')
            intern_position(vertex.position, positions, position_index, bounds_accumulator)
          end
        end
        face_mesh = face.mesh
        result = {
          id: "face:#{safe_persistent_id(face)}",
          source_identity: entity_source_identity(face),
          outer: outer,
          holes: holes,
          triangles: build_face_triangles(face_mesh, positions, position_index, bounds_accumulator),
          front_material_id: material_id(face.material),
          back_material_id: material_id(face.back_material),
          front_appearance_required: true,
          back_appearance_required: !face.back_material.nil?,
          tag_id: tag_id(face.layer),
          normal: vector_array(face.normal),
          area_m2: (face.area.to_f * Constants::IN2_TO_M2).round(9),
          area_space: 'definition_local',
          surface_hint: Classifier.classify(face.normal),
          semantic: semantic_for_face(face),
          hidden: face.hidden?,
          attributes: Traversal.extract_dicts(face),
          _entity: face
        }
        uv = build_face_uv(face, outer_vertices: outer_vertices, hole_vertex_rows: hole_vertex_rows)
        result[:uv] = uv unless uv.nil?
        result
      end

      def build_face_triangles(mesh, positions, position_index, bounds_accumulator = nil)
        return [] unless mesh && mesh.respond_to?(:polygons)

        mesh.polygons.each_with_object([]) do |polygon, triangles|
          checkpoint('Triangulating faces')
          indices = polygon.map do |point_index|
            point = mesh.point_at(point_index.abs)
            point ? intern_position(point, positions, position_index, bounds_accumulator) : nil
          end.compact
          triangles.concat(indices) if indices.length == 3
        end
      rescue StandardError => error
        @skipped["face_triangles:#{error.class}"] += 1
        []
      end

      def build_edge(edge, positions, position_index, bounds_accumulator = nil)
        {
          id: "edge:#{safe_persistent_id(edge)}",
          source_identity: entity_source_identity(edge),
          vertices: [
            intern_position(edge.start.position, positions, position_index, bounds_accumulator),
            intern_position(edge.end.position, positions, position_index, bounds_accumulator)
          ],
          tag_id: tag_id(edge.layer),
          hidden: edge.hidden?,
          soft: edge.soft?,
          smooth: edge.smooth?,
          _entity: edge
        }
      end

      def build_face_uv(face, outer_vertices: nil, hole_vertex_rows: nil)
        return nil if @texture_writer.nil?

        front = textured_material?(face.material)
        back = textured_material?(face.back_material)
        return nil unless front || back

        outer_vertices ||= face.outer_loop.vertices
        hole_vertex_rows ||= face.loops.reject(&:outer?).map(&:vertices)
        helper = face.get_UVHelper(front, back, @texture_writer)
        uv = {}
        if front
          uv[:front_outer] = uv_vertices(outer_vertices, helper, :front)
          uv[:front_holes] = hole_vertex_rows.map { |vertices| uv_vertices(vertices, helper, :front) }
        end
        if back
          uv[:back_outer] = uv_vertices(outer_vertices, helper, :back)
          uv[:back_holes] = hole_vertex_rows.map { |vertices| uv_vertices(vertices, helper, :back) }
        end
        uv
      rescue StandardError => error
        @skipped["uv:#{error.class}"] += 1
        nil
      end

      def textured_material?(material)
        !material.nil? && material.respond_to?(:texture) && !material.texture.nil?
      end

      def uv_vertices(vertices, helper, side)
        vertices.map do |vertex|
          checkpoint('Reading texture coordinates')
          uvq = side == :front ? helper.get_front_UVQ(vertex.position) : helper.get_back_UVQ(vertex.position)
          uvq.z.to_f.zero? ? [0.0, 0.0] : [(uvq.x / uvq.z).round(9), (uvq.y / uvq.z).round(9)]
        end
      end

      def build_instance_node(entity, owner_definition_id, definition_id, kind)
        definition_name = entity.respond_to?(:definition) ? entity.definition.name.to_s : nil
        {
          id: "node:#{owner_definition_id}:#{kind}:#{safe_persistent_id(entity)}",
          kind: kind,
          name: entity.name.to_s.empty? ? fallback_instance_name(entity) : entity.name,
          owner_definition_id: owner_definition_id,
          definition_id: definition_id,
          transform_id: intern_transform(entity.transformation),
          material_override_id: material_id(entity.material),
          tag_id: tag_id(entity.layer),
          source_identity: entity_source_identity(entity),
          attributes: Traversal.extract_dicts(entity),
          semantic: SemanticLabeler.build(
            instance_name: entity.name,
            definition_name: definition_name,
            tag_name: entity_tag_name(entity),
            attached_labels: @attached_labels[entity.object_id]
          ),
          visible: entity_visible?(entity),
          _entity: entity
        }
      end

      def build_image_node(image, owner_definition_id)
        data = Traversal.build_image(image, Geom::Transformation.new)
        {
          id: "node:#{owner_definition_id}:image:#{safe_persistent_id(image)}",
          kind: 'image',
          name: File.basename(data[:filename].to_s),
          owner_definition_id: owner_definition_id,
          definition_id: nil,
          transform_id: intern_transform(image.transformation),
          material_override_id: material_id(image.material),
          tag_id: tag_id(image.layer),
          source_identity: entity_source_identity(image),
          image: data,
          attributes: Traversal.extract_dicts(image),
          visible: entity_visible?(image),
          _entity: image
        }
      end

      def build_text_node(text, owner_definition_id)
        return nil if text.point.nil?

        {
          id: "node:#{owner_definition_id}:text:#{safe_persistent_id(text)}",
          kind: 'text',
          name: text.text.to_s,
          owner_definition_id: owner_definition_id,
          definition_id: nil,
          transform_id: intern_transform(Geom::Transformation.translation(text.point)),
          material_override_id: nil,
          tag_id: tag_id(text.layer),
          source_identity: entity_source_identity(text),
          text: text.text.to_s,
          attachment: text_attachment(text),
          attributes: Traversal.extract_dicts(text),
          visible: entity_visible?(text),
          _entity: text
        }
      end

      def build_tags
        @model.layers.each do |layer|
          checkpoint('Reading model tags')
          id = "tag:#{safe_persistent_id(layer)}"
          @tag_ids[layer.object_id] = id
          color = begin
            layer.color
          rescue StandardError
            nil
          end
          # Canonical tag state is model state. Page presentation is encoded only
          # in each SceneProfile below.
          visible = layer.respond_to?(:visible?) ? layer.visible? : true
          @tags << {
            id: id,
            source_identity: entity_source_identity(layer),
            name: layer.name,
            visible: visible,
            color: color && color_hash(color)
          }
        end
      end

      def build_materials
        @model.materials.each do |material|
          checkpoint('Reading model materials')
          id = "material:#{safe_persistent_id(material)}"
          @material_ids[material.object_id] = id
          color = material.color
          texture = material.texture
          item = {
            id: id,
            source_identity: entity_source_identity(material),
            name: material.name,
            display_name: material.display_name,
            color: color_hash(color),
            opacity: material.alpha.to_f.round(6),
            material_type: material.materialType,
            attributes: Traversal.extract_dicts(material)
          }
          if material.materialType.to_i == 2 && material.respond_to?(:colorize_deltas) && material.respond_to?(:colorize_type)
            raw_mode=material.colorize_type
            shift_constant=defined?(Sketchup::Material::COLORIZE_SHIFT) ? Sketchup::Material::COLORIZE_SHIFT : 0
            h,l,saturation=Array(material.colorize_deltas).map(&:to_f)
            item[:colorize_type]=raw_mode==shift_constant ? 'shift' : 'tint'
            item[:colorize_deltas]={h:h,l:l,s:saturation}
          end
          if texture
            item[:texture] = {
              filename: texture.filename.to_s,
              source_path: texture.filename.to_s,
              width_m: (texture.width.to_f * Constants::IN_TO_M).round(9),
              height_m: (texture.height.to_f * Constants::IN_TO_M).round(9),
              image_width_px: texture.image_width,
              image_height_px: texture.image_height
            }
          end
          @materials << item
        end
      end

      def build_source
        {
          kind: 'SketchUp',
          identity: model_source_identity,
          file_path: @model.path.to_s,
          file_name: File.basename(@model.path.to_s),
          model_name: @model.name.to_s,
          model_description: @model.description.to_s,
          sketchup_version: Sketchup.version.to_s,
          sketchup_locale: (Sketchup.get_locale rescue nil),
          exported_at: Time.now.utc.iso8601,
          scope: @settings[:selection_only] ? 'selection' : (@scene_scope == 'all' ? 'all_scenes' : 'active_scene'),
          source_modified: @model.modified?
        }
      end

      def build_metadata
        {
          model_bounds_m: bounds_hash(@model.bounds),
          georeferenced: (@model.georeferenced? rescue false),
          attributes: Traversal.extract_dicts(@model),
          export_settings: serializable_settings
        }
      end

      def build_scenes
        capture_index = SceneVisibilityResolver.build_capture_index(nodes: @nodes, definitions: @definitions, meshes: @meshes, work_cursor: @scene_work_cursor)
        scenes = SceneVisibilityResolver.resolve_scenes(
          @model,
          nodes: @nodes,
          definitions: @definitions,
          meshes: @meshes,
          capture_context: @scene_context,
          capture_index: capture_index,
          work_cursor: @scene_work_cursor
        )
        @nodes.each { |node| @scene_work_cursor&.step('scene_cleanup'); node.delete(:_entity) }
        @meshes.each do |mesh|
          Array(mesh[:faces]).each { |face| @scene_work_cursor&.step('scene_cleanup'); face.delete(:_entity) }
          Array(mesh[:edges]).each { |edge| @scene_work_cursor&.step('scene_cleanup'); edge.delete(:_entity) }
        end
        @scene_work_cursor&.flush('scene_cleanup')
        scenes
      end

      def extract_spaces
        rooms = @spatial[:rooms] || @spatial['rooms']
        rooms.is_a?(Array) ? rooms : []
      end

      def build_relationships
        {
          openings: @spatial[:openings] || @spatial['openings'] || [],
          room_boundaries: @spatial[:room_boundaries] || @spatial['room_boundaries'] || [],
          adjacency: @spatial[:adjacency] || @spatial['adjacency'] || []
        }
      end

      def build_statistics(identity_transform_id)
        {
          definitions: @definitions.length,
          meshes: @meshes.length,
          nodes: @nodes.length,
          component_instances: @statistics[:component_instances],
          group_instances: @statistics[:group_instances],
          faces: @statistics[:faces],
          unique_vertices: @statistics[:unique_vertices],
          materials: @materials.length,
          tags: @tags.length,
          transforms: @transforms.length,
          labeled_nodes: @statistics[:labeled_nodes],
          label_role_nodes: @statistics[:label_role_nodes],
          geometry_fallback_nodes: @statistics[:geometry_fallback_nodes],
          identity_transform_id: identity_transform_id,
          skipped: @skipped.sort.to_h
        }
      end

      def append_node(node)
        @nodes << node
        record_node_statistics(node)
        node
      end

      def record_node_statistics(node)
        @statistics[:component_instances] += 1 if node[:kind] == 'component_instance'
        @statistics[:group_instances] += 1 if node[:kind] == 'group_instance'
        semantic = node[:semantic]
        return if semantic.nil?

        @statistics[:labeled_nodes] += 1 unless semantic[:label].nil?
        @statistics[:label_role_nodes] += 1 unless semantic[:role].nil?
        if semantic[:classification_policy] == SemanticLabeler::GEOMETRY_FALLBACK_POLICY
          @statistics[:geometry_fallback_nodes] += 1
        end
      end

      def intern_position(point, positions, index, bounds_accumulator = nil)
        values = point_array(point)
        key = values.freeze
        existing = index[key]
        return existing unless existing.nil?

        position_id = positions.length / 3
        positions.concat(values)
        expand_bounds_accumulator(bounds_accumulator, values) if bounds_accumulator
        index[key] = position_id
        position_id
      end

      def intern_transform(transform)
        matrix = transform.to_a.map.with_index do |value, index|
          converted = [12, 13, 14].include?(index) ? value.to_f * Constants::IN_TO_M : value.to_f
          converted.round(9)
        end
        key = matrix.pack('G*')
        existing = @transform_index[key]
        return existing unless existing.nil?

        id = @transforms.length
        @transforms << matrix
        @transform_index[key] = id
        id
      end

      def each_entity(entities)
        entities.each do |entity|
          checkpoint('Converting model entities')
          unless valid_exportable_entity?(entity)
            @skipped['hidden_or_invalid_entity'] += 1
            next
          end
          yield entity
        end
      end

      def capture_entities(entities)
        captured = []
        entities.each do |entity|
          checkpoint('Converting model entities')
          unless valid_exportable_entity?(entity)
            @skipped['hidden_or_invalid_entity'] += 1
            next
          end
          kind = case entity
                 when Sketchup::Face then :face
                 when Sketchup::Edge then :edge
                 when Sketchup::Group then :group
                 when Sketchup::ComponentInstance then :component_instance
                 when Sketchup::Image then :image
                 when Sketchup::Text then :text
                 else :other
                 end
          captured << [kind, entity]
        end
        PerformanceTrace.increment(:canonical_captured_entities, captured.length)
        captured
      end

      def valid_exportable_entity?(entity)
        return false unless Traversal.valid_entity?(entity)
        # Exact retains the source universe; scene visibility is carried on
        # faces/nodes and applied by the reader, not used to drop source data.
        return true if @preserve_hidden_geometry
        cache_key = entity.object_id
        visible = @exportable_cache[cache_key]
        if visible.nil?
          visible = SceneVisibilityResolver.exportable_universe?(
            entity,
            nil,
            model: @model,
            scope: @scene_scope,
            capture_context: @scene_context
          )
          @exportable_cache[cache_key] = visible
        else
          PerformanceTrace.increment(:canonical_exportable_cache_hits, 1)
        end
        return false unless visible
        if @scene_scope == 'active'
          return false unless Traversal.exportable_entity?(entity)
        end
        true
      rescue StandardError
        false
      end

      def bounds_for_entities(entities, captured_entities = nil)
        parent = entities.respond_to?(:parent) ? entities.parent : nil
        return bounds_hash(parent.bounds) if parent && parent.respond_to?(:bounds)

        points = []
        rows = captured_entities || entities.map { |entity| [nil, entity] }
        rows.each do |_kind, entity|
          checkpoint('Calculating definition bounds')
          next unless entity.respond_to?(:bounds)
          bounds = entity.bounds
          points << bounds.min << bounds.max
        rescue StandardError
          next
        end
        bounds_from_point_objects(points)
      rescue StandardError
        empty_bounds
      end

      def new_bounds_accumulator
        {
          min: [Float::INFINITY, Float::INFINITY, Float::INFINITY],
          max: [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY],
          populated: false
        }
      end

      def expand_bounds_accumulator(bounds, vector)
        bounds[:populated] = true
        3.times do |axis|
          bounds[:min][axis] = vector[axis] if vector[axis] < bounds[:min][axis]
          bounds[:max][axis] = vector[axis] if vector[axis] > bounds[:max][axis]
        end
      end

      def bounds_from_accumulator(bounds)
        return empty_bounds unless bounds && bounds[:populated]

        {
          min: bounds[:min].map { |value| value.round(9) },
          max: bounds[:max].map { |value| value.round(9) },
          size: 3.times.map { |axis| (bounds[:max][axis] - bounds[:min][axis]).round(9) }
        }
      end

      def bounds_hash(bounds)
        return empty_bounds unless bounds && bounds.valid?

        {
          min: point_array(bounds.min),
          max: point_array(bounds.max),
          size: [
            (bounds.width.to_f * Constants::IN_TO_M).round(9),
            (bounds.height.to_f * Constants::IN_TO_M).round(9),
            (bounds.depth.to_f * Constants::IN_TO_M).round(9)
          ]
        }
      rescue StandardError
        empty_bounds
      end

      def bounds_from_point_objects(points)
        return empty_bounds if points.empty?

        converted = points.map { |point| point_array(point) }
        bounds_from_vectors(converted)
      end

      def bounds_from_positions(positions)
        return empty_bounds if positions.empty?

        bounds_from_vectors(positions.each_slice(3))
      end

      def bounds_from_vectors(vectors)
        min = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
        max = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
        vectors.each do |vector|
          checkpoint('Calculating mesh bounds')
          3.times do |axis|
            min[axis] = vector[axis] if vector[axis] < min[axis]
            max[axis] = vector[axis] if vector[axis] > max[axis]
          end
        end
        {
          min: min.map { |value| value.round(9) },
          max: max.map { |value| value.round(9) },
          size: 3.times.map { |axis| (max[axis] - min[axis]).round(9) }
        }
      end

      def empty_bounds
        { min: [0.0, 0.0, 0.0], max: [0.0, 0.0, 0.0], size: [0.0, 0.0, 0.0] }
      end

      def point_array(point)
        [
          (point.x.to_f * Constants::IN_TO_M).round(9),
          (point.y.to_f * Constants::IN_TO_M).round(9),
          (point.z.to_f * Constants::IN_TO_M).round(9)
        ]
      end

      def vector_array(vector)
        [vector.x.to_f.round(9), vector.y.to_f.round(9), vector.z.to_f.round(9)]
      end

      def color_hash(color)
        {
          r: color.red,
          g: color.green,
          b: color.blue,
          a: color.alpha,
          hex: format('#%02X%02X%02X', color.red, color.green, color.blue)
        }
      end

      def material_id(material)
        return nil if material.nil?
        @material_ids[material.object_id]
      end

      def tag_id(layer)
        return nil if layer.nil?
        @tag_ids[layer.object_id]
      end

      def root_definition_id
        scope = @settings[:selection_only] ? 'selection' : 'model'
        "definition:root:#{source_token(@model.guid)}:#{scope}"
      end

      def component_definition_id(definition)
        identity = definition.guid.to_s
        identity = safe_persistent_id(definition) if identity.empty?
        "definition:component:#{source_token(identity)}"
      end

      def group_definition_id(group)
        definition = group.definition
        identity = definition.guid.to_s
        identity = safe_persistent_id(definition) if identity.empty?
        "definition:group:#{source_token(identity)}"
      end

      def source_token(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, '-').gsub(/^-|-$/, '')
      end

      def safe_persistent_id(entity)
        value = entity.persistent_id if entity.respond_to?(:persistent_id)
        value = entity.entityID if (value.nil? || value.to_i.zero?) && entity.respond_to?(:entityID)
        value = entity.object_id if value.nil?
        value.to_s
      rescue StandardError
        entity.object_id.to_s
      end

      def entity_source_identity(entity)
        identity = {
          persistent_id: safe_persistent_id(entity),
          entity_type: entity.class.name
        }
        identity[:guid] = entity.guid.to_s if entity.respond_to?(:guid) && !entity.guid.to_s.empty?
        identity
      rescue StandardError
        { persistent_id: safe_persistent_id(entity), entity_type: entity.class.name }
      end

      def definition_source_identity(definition)
        identity = entity_source_identity(definition)
        identity[:guid] = definition.guid.to_s
        identity[:name] = definition.name.to_s
        identity
      end

      def model_source_identity
        { guid: @model.guid.to_s, entity_type: 'Sketchup::Model' }
      end

      def fallback_instance_name(entity)
        entity.respond_to?(:definition) ? entity.definition.name.to_s : '(Instance)'
      end

      def entity_visible?(entity)
        # Do not let export-time active Page contaminate canonical node state.
        # Scene overrides are resolved independently by SceneVisibilityResolver.
        SceneVisibilityResolver.effective_entity_visibility(entity, nil)
      rescue StandardError
        true
      end

      # SketchUp leader text can be attached to a nested InstancePath. Resolve it
      # to the nearest Group/Component so instance semantics remain reusable and
      # do not get duplicated across every face in the compact runtime format.
      def index_attached_labels(entities, visited = {})
        key = entities.object_id
        return if visited[key]

        visited[key] = true
        entities.each do |entity|
          checkpoint('Indexing attached labels')
          case entity
          when Sketchup::Text
            attachment = text_attachment(entity)
            next if attachment.nil? || attachment[:target_object_id].nil?

            label = SemanticLabeler.clean(entity.text)
            next if label.empty?

            @attached_labels[attachment[:target_object_id]] << {
              value: label,
              text_persistent_id: safe_persistent_id(entity),
              target_path: attachment[:target_path]
            }
          when Sketchup::Group
            index_attached_labels(entity.entities, visited)
          when Sketchup::ComponentInstance
            index_attached_labels(entity.definition.entities, visited)
          end
        end
      rescue StandardError => error
        @skipped["attached_labels:#{error.class}"] += 1
      end

      def text_attachment(text)
        attached = text.respond_to?(:attached_to) ? text.attached_to : nil
        return nil unless attached.is_a?(Array) && attached[0]

        path = attached[0]
        entities = path.respond_to?(:to_a) ? path.to_a : Array(path)
        target = entities.reverse.find do |entity|
          entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        end
        target ||= entities.last
        return nil if target.nil?

        {
          target_object_id: target.object_id,
          target_persistent_id: safe_persistent_id(target),
          target_path: path.respond_to?(:persistent_id_path) ? path.persistent_id_path.to_s : entities.map { |entity| safe_persistent_id(entity) }.join('.')
        }
      rescue StandardError => error
        @skipped["text_attachment:#{error.class}"] += 1
        nil
      end

      def semantic_for_face(face)
        labels = @attached_labels[face.object_id]
        return SemanticLabeler.empty_semantic if labels.empty?

        SemanticLabeler.build(instance_name: nil, attached_labels: labels)
      end

      def entity_tag_name(entity)
        entity.respond_to?(:layer) && entity.layer ? entity.layer.name.to_s : nil
      rescue StandardError
        nil
      end

      def serializable_settings
        @settings.each_with_object({}) do |(key, value), result|
          result[key] = value if value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
        end
      end

      def plugin_version
        defined?(BOMEngine::PLUGIN_VERSION) ? BOMEngine::PLUGIN_VERSION : 'development'
      end

      def checkpoint(stage, force: false)
        return if @progress.nil?

        @work_count += 1
        return unless force || (@work_count % @batch_size).zero?

        @progress.call(stage: stage, processed: @work_count)
      end

      UNIT_NAMES = %w[Inches Feet Millimeters Centimeters Meters Kilometers].freeze

      def source_unit_name
        options = @model.options['UnitsOptions']
        UNIT_NAMES[options['LengthUnit'].to_i] || 'Unknown'
      rescue StandardError
        'Unknown'
      end

      def source_angle_unit
        options = @model.options['UnitsOptions']
        options['AngleUnits'].to_i.zero? ? 'degree' : 'radian'
      rescue StandardError
        'degree'
      end
    end
  end
end
