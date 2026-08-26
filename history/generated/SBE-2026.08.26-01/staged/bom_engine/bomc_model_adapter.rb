# Normalizes Canonical v3 or compact Model-Eval JSON into BOMC compiler input.

require 'digest'

module SibamboHistory
  module V20260826_01
  module BOMC
    module ModelAdapter
      IDENTITY = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0].freeze
      NODE_KINDS = { 0 => 'unknown', 1 => 'root', 2 => 'component_instance', 3 => 'group_instance', 4 => 'image', 5 => 'text' }.freeze

      module_function

      def normalize(graph, base_path: nil, checkpoint: nil)
        payload = symbolize_if_needed(graph)
        if payload.dig(:format, :identifier).to_s == 'model_eval_json_v1'
          from_model_eval(payload, base_path: base_path, checkpoint: checkpoint)
        else
          from_canonical(payload, base_path: base_path, checkpoint: checkpoint)
        end
      end

      def from_canonical(graph, base_path: nil, checkpoint: nil)
        payload = symbolize_if_needed(graph)
        raw_materials = Array(payload[:materials])
        raw_tags = Array(payload[:tags])
        raw_definitions = Array(payload[:definitions])
        raw_meshes = Array(payload[:meshes])
        raw_nodes = Array(payload[:nodes])
        material_index = index_ids(raw_materials)
        tag_index = index_ids(raw_tags)
        definition_index = index_ids(raw_definitions)
        mesh_index = index_ids(raw_meshes)
        node_index = index_node_ids(raw_nodes)

        materials = raw_materials.each_with_index.map do |material, index|
          notify(checkpoint, :compile_metadata, index + 1, raw_materials.length)
          canonical_material(material, base_path)
        end
        tags = raw_tags.each_with_index.map do |tag, index|
          notify(checkpoint, :compile_metadata, index + 1, raw_tags.length)
          { stable_id: tag[:id].to_s, name: tag[:name].to_s, visible: tag[:visible] != false }
        end
        meshes = raw_meshes.each_with_index.map do |mesh, mesh_index_value|
          notify(checkpoint, :encode_positions, mesh_index_value + 1, raw_meshes.length)
          positions = Array(mesh[:positions_m]).map(&:to_f)
          raw_faces = Array(mesh[:faces])
          {
            stable_id: mesh[:id].to_s,
            definition: fetch_reference(definition_index, mesh[:definition_id], 'mesh definition'),
            positions: positions,
            faces: raw_faces.each_with_index.map do |face, face_index|
              notify(checkpoint, :encode_topology, face_index + 1, raw_faces.length)
              canonical_face(face, positions, material_index, tag_index, materials)
            end,
            edges: Array(mesh[:edges]).map { |edge| canonical_edge(edge, tag_index) }
          }
        end
        definitions = raw_definitions.each_with_index.map do |definition, index|
          notify(checkpoint, :build_definitions, index + 1, raw_definitions.length)
          {
            stable_id: definition[:id].to_s,
            name: definition[:name].to_s,
            kind: definition[:kind].to_s,
            mesh: optional_reference(mesh_index, definition[:mesh_id]),
            nodes: Array(definition[:node_ids]).map { |id| node_index[id] }.compact
          }
        end
        instances = raw_nodes.each_with_index.map do |node, index|
          notify(checkpoint, :build_instances, index + 1, raw_nodes.length)
          semantic = node[:semantic] || {}
          {
            stable_id: node[:id].to_s,
            persistent_id: source_identity_value(node[:source_identity]),
            name: node[:name].to_s,
            kind: node[:kind].to_s,
            owner_definition: optional_reference(definition_index, node[:owner_definition_id]),
            definition: optional_reference(definition_index, node[:definition_id]),
            transform: Integer(node[:transform_id] || 0),
            material: optional_reference(material_index, node[:material_override_id]),
            tag: optional_reference(tag_index, node[:tag_id]),
            visible: node[:visible] != false,
            semantic_label: semantic[:label],
            semantic_role: semantic[:role],
            semantic_source: semantic[:source],
            classification_policy: semantic[:classification_policy],
            fallback: canonical_fallback(node, base_path)
          }
        end
        root_node = instances.index { |node| node[:kind] == 'root' }
        raise 'BOMC source invalid: exactly one root instance is required.' if root_node.nil? || instances.count { |node| node[:kind] == 'root' } != 1

        scenes = adapt_scenes(payload[:scenes], tag_index, node_index)

        finalize(
          source: payload[:source] || {},
          coordinate_system: payload[:coordinate_system] || {},
          materials: materials,
          tags: tags,
          transforms: normalize_transforms(payload[:transforms], checkpoint),
          meshes: meshes,
          definitions: definitions,
          instances: instances,
          root_node: root_node,
          scenes: scenes
        )
      end

      def from_model_eval(graph, base_path: nil, checkpoint: nil)
        payload = symbolize_if_needed(graph)
        strings = Array(payload[:strings])
        raw_materials = Array(payload[:materials])
        materials = raw_materials.each_with_index.map do |row, index|
          notify(checkpoint, :compile_metadata, index + 1, raw_materials.length)
          color = parse_hex(string_at(strings, row[2]))
          {
            stable_id: string_at(strings, row[0]).to_s,
            persistent_id: nil,
            name: string_at(strings, row[1]).to_s,
            display_name: string_at(strings, row[1]).to_s,
            color: color,
            opacity: row[3].to_f,
            texture: nil
          }
        end
        raw_tags = Array(payload[:tags])
        tags = raw_tags.each_with_index.map do |row, index|
          notify(checkpoint, :compile_metadata, index + 1, raw_tags.length)
          { stable_id: string_at(strings, row[0]).to_s, name: string_at(strings, row[1]).to_s, visible: row[2] != false }
        end
        raw_definitions = Array(payload[:definitions])
        definitions = raw_definitions.each_with_index.map do |row, index|
          notify(checkpoint, :build_definitions, index + 1, raw_definitions.length)
          {
            stable_id: string_at(strings, row[0]).to_s,
            name: string_at(strings, row[1]).to_s,
            kind: string_at(strings, row[2]).to_s == 'root' ? 'model_definition' : string_at(strings, row[2]).to_s,
            mesh: optional_numeric(row[3]),
            nodes: Array(row[4]).map(&:to_i)
          }
        end
        owner_by_node = {}
        definitions.each_with_index do |definition, definition_index|
          definition[:nodes].each { |node_index| owner_by_node[node_index] = definition_index }
        end
        raw_nodes = Array(payload[:nodes])
        instances = raw_nodes.each_with_index.map do |row, index|
          notify(checkpoint, :build_instances, index + 1, raw_nodes.length)
          {
            stable_id: string_at(strings, row[0]).to_s,
            persistent_id: string_at(strings, row[8]),
            name: string_at(strings, row[1]).to_s,
            kind: NODE_KINDS.fetch(row[2].to_i, 'unknown'),
            owner_definition: owner_by_node[index],
            definition: row[3].to_i,
            transform: row[4].to_i,
            material: optional_numeric(row[5]),
            tag: optional_numeric(row[6]),
            visible: row[7] != false,
            semantic_label: string_at(strings, row[9]),
            semantic_source: string_at(strings, row[10]),
            semantic_role: string_at(strings, row[11]),
            classification_policy: string_at(strings, row[12])
          }
        end
        raw_meshes = Array(payload[:meshes])
        meshes = raw_meshes.each_with_index.map do |mesh, mesh_index_value|
          notify(checkpoint, :encode_positions, mesh_index_value + 1, raw_meshes.length)
          positions = decode_model_eval_positions(mesh)
          loops = Array(mesh[:loops])
          triangles = Array(mesh[:triangles])
          raw_faces = Array(mesh[:faces])
          faces = raw_faces.each_with_index.map do |row, face_index|
            notify(checkpoint, :encode_topology, face_index + 1, raw_faces.length)
            outer = loops[row[2].to_i, row[3].to_i] || []
            holes = Array(row[4]).map { |range| loops[range[0].to_i, range[1].to_i] || [] }
            face_triangles = triangles[row[5].to_i, row[6].to_i] || []
            role = string_at(strings, row[14])
            {
              stable_id: string_at(strings, row[0]).to_s,
              persistent_id: string_at(strings, row[1]),
              outer: outer.map(&:to_i),
              holes: holes.map { |hole| hole.map(&:to_i) },
              triangles: face_triangles.map(&:to_i),
              front_material: optional_numeric(row[7]),
              back_material: optional_numeric(row[8]),
              front_appearance_required: true,
              back_appearance_required: !optional_numeric(row[8]).nil?,
              tag: optional_numeric(row[9]),
              normal: face_normal(positions, outer),
              area_m2: row[11].to_f,
              surface_type: role || string_at(strings, row[10]),
              hidden: false,
              semantic_label: string_at(strings, row[12]),
              semantic_role: role,
              semantic_source: string_at(strings, row[13]),
              classification_policy: string_at(strings, row[15]),
              uv: nil
            }
          end
          {
            stable_id: string_at(strings, mesh[:id]).to_s,
            definition: mesh[:definition].to_i,
            positions: positions,
            faces: faces,
            edges: []
          }
        end
        source_row = Array(payload[:source])
        source = {
          file_name: string_at(strings, source_row[0]),
          model_name: string_at(strings, source_row[1]),
          scope: string_at(strings, source_row[2]),
          exported_at: string_at(strings, source_row[3])
        }
        tag_index = tags.each_with_index.each_with_object({}) { |(tag, idx), h| h[tag[:stable_id]] = idx }
        node_index = index_node_ids(instances)
        scenes = adapt_scenes(payload[:scenes], tag_index, node_index)
        finalize(
          source: source,
          coordinate_system: payload[:coordinate_system] || {},
          materials: materials,
          tags: tags,
          transforms: normalize_transforms(payload[:transforms], checkpoint),
          meshes: meshes,
          definitions: definitions,
          instances: instances,
          root_node: payload[:root_node].to_i,
          scenes: scenes
        )
      end

      def adapt_scenes(raw_scenes, tag_index, node_index)
        return [] if raw_scenes.nil? || raw_scenes.empty?

        raw_scenes.map do |scene|
          camera = scene[:camera] || {}
          visibility = scene[:visibility] || {}
          visible_tag_ids = Array(visibility[:visible_tag_ids]).map(&:to_s)
          hidden_tag_ids = Array(visibility[:hidden_tag_ids]).map(&:to_s)
          visible_node_overrides = Array(visibility[:visible_node_overrides]).map(&:to_s)
          hidden_node_overrides = Array(visibility[:hidden_node_overrides]).map(&:to_s)

          visible_tag_indices = visible_tag_ids.map { |id| tag_index[id] }.compact.uniq.sort
          hidden_tag_indices = hidden_tag_ids.map { |id| tag_index[id] }.compact.uniq.sort

          unresolved_visible_overrides = []
          visible_node_indices = []
          visible_node_overrides.each do |id|
            idx = node_index[id]
            if idx
              visible_node_indices << idx
            else
              unresolved_visible_overrides << id
            end
          end
          visible_node_indices = visible_node_indices.uniq.sort

          unresolved_hidden_overrides = []
          hidden_node_indices = []
          hidden_node_overrides.each do |id|
            idx = node_index[id]
            if idx
              hidden_node_indices << idx
            else
              unresolved_hidden_overrides << id
            end
          end
          hidden_node_indices = hidden_node_indices.uniq.sort

          {
            stable_id: scene[:id].to_s,
            name: scene[:name].to_s,
            description: scene[:description].to_s,
            is_active_at_export: scene[:is_active_at_export] == true,
            source: (scene[:source] || 'sketchup-page').to_s,
            source_binding: scene[:source_binding] || {},
            camera: {
              projection: camera[:projection].to_s == 'orthographic' ? 'orthographic' : 'perspective',
              eye_m: Array(camera[:eye_m]).map(&:to_f),
              target_m: Array(camera[:target_m]).map(&:to_f),
              up: Array(camera[:up]).map(&:to_f),
              field_of_view_degrees: camera[:field_of_view_degrees]&.to_f,
              fov_is_height: camera[:fov_is_height] != false,
              orthographic_height_m: camera[:orthographic_height_m]&.to_f,
              aspect_ratio: camera[:aspect_ratio].to_f,
              is_2d: camera[:is_2d] == true
            },
            use_camera: scene[:use_camera] != false,
            transition_time_seconds: scene[:transition_time_seconds].to_f,
            visibility: {
              visible_tag_ids: visible_tag_ids,
              hidden_tag_ids: hidden_tag_ids,
              visible_node_overrides: visible_node_overrides,
              hidden_node_overrides: hidden_node_overrides,
              visible_tag_indices: visible_tag_indices,
              hidden_tag_indices: hidden_tag_indices,
              visible_node_indices: visible_node_indices,
              hidden_node_indices: hidden_node_indices,
              source_visible_node_override_count: visible_node_overrides.length,
              source_hidden_node_override_count: hidden_node_overrides.length,
              resolved_visible_node_override_count: visible_node_indices.length,
              resolved_hidden_node_override_count: hidden_node_indices.length,
              unresolved_visible_node_overrides: unresolved_visible_overrides,
              unresolved_hidden_node_overrides: unresolved_hidden_overrides,
              unresolved_visible_node_override_count: unresolved_visible_overrides.length,
              unresolved_hidden_node_override_count: unresolved_hidden_overrides.length
            },
            stores_tag_visibility: scene[:stores_tag_visibility] != false,
            stores_hidden_objects: scene[:stores_hidden_objects] != false,
            stores_hidden_geometry: scene[:stores_hidden_geometry] == true,
            stores_section_planes: scene[:stores_section_planes] == true,
            section_state: scene[:section_state] || { active_section_plane_ids: [], rendering_support: 'metadata-only' },
            visibility_signature: scene[:visibility_signature].to_s
          }
        end
      end
      private_class_method :adapt_scenes

      def canonical_material(material, base_path)
        color = material[:color] || {}
        texture = material[:texture]
        {
          stable_id: material[:id].to_s,
          persistent_id: source_identity_value(material[:source_identity]),
          name: material[:name].to_s,
          display_name: (material[:display_name] || material[:name]).to_s,
          color: {
            r: Integer(color[:r] || 0), g: Integer(color[:g] || 0), b: Integer(color[:b] || 0), a: Integer(color[:a] || 255)
          },
          opacity: material.key?(:opacity) ? material[:opacity].to_f : (material[:alpha] || 1.0).to_f,
          texture: normalize_texture(texture, base_path)
        }
      end
      private_class_method :canonical_material

      def normalize_texture(texture, base_path)
        return nil if texture.nil?

        bytes = texture[:bytes]
        if bytes.nil?
          candidates = [texture[:source_path], texture[:filename]].compact.map(&:to_s)
          if base_path
            candidates += candidates.reject { |path| absolute_path?(path) }.map { |path| File.join(base_path, path) }
          end
          path = candidates.find { |candidate| File.file?(candidate) }
          bytes = File.binread(path) if path
        end
        return nil if bytes.nil?

        content = bytes.b
        {
          bytes: content,
          sha256: Digest::SHA256.hexdigest(content),
          media_type: texture_media_type(texture, content),
          image_width_px: Integer(texture[:image_width_px] || 0),
          image_height_px: Integer(texture[:image_height_px] || 0),
          width_m: (texture[:width_m] || 0.0).to_f,
          height_m: (texture[:height_m] || 0.0).to_f,
          encoding_evidence: texture[:encoding_evidence]
        }
      end
      private_class_method :normalize_texture

      def texture_media_type(texture, bytes)
        filename = (texture[:filename] || texture[:source_path]).to_s.downcase
        return :png if bytes.start_with?("\x89PNG\r\n\x1a\n".b) || filename.end_with?('.png')
        return :jpeg if bytes.start_with?("\xff\xd8".b) || filename.end_with?('.jpg', '.jpeg')
        return :webp if bytes.bytesize >= 12 && bytes.byteslice(0, 4) == 'RIFF' && bytes.byteslice(8, 4) == 'WEBP'
        return :avif if filename.end_with?('.avif')
        return :ktx2 if bytes.start_with?("\xabKTX 20\xbb\r\n\x1a\n".b) || filename.end_with?('.ktx2')

        :binary
      end
      private_class_method :texture_media_type

      def canonical_face(face, positions, material_index, tag_index, materials)
        semantic = face[:semantic] || {}
        outer = Array(face[:outer]).map(&:to_i)
        front_material = optional_reference(material_index, face[:front_material_id])
        back_material = optional_reference(material_index, face[:back_material_id])
        {
          stable_id: face[:id].to_s,
          persistent_id: source_identity_value(face[:source_identity]),
          outer: outer,
          holes: Array(face[:holes]).map { |hole| Array(hole).map(&:to_i) },
          triangles: Array(face[:triangles]).map(&:to_i),
          front_material: front_material,
          back_material: back_material,
          front_appearance_required: true,
          back_appearance_required: !back_material.nil?,
          tag: optional_reference(tag_index, face[:tag_id]),
          normal: Array(face[:normal]).empty? ? face_normal(positions, outer) : Array(face[:normal]).map(&:to_f),
          area_m2: face[:area_m2].to_f,
          surface_type: semantic[:role] || face[:surface_hint],
          hidden: face[:hidden] == true,
          semantic_label: semantic[:label],
          semantic_role: semantic[:role],
          semantic_source: semantic[:source],
          classification_policy: semantic[:classification_policy],
          uv: normalize_uv_for_materials(face[:uv], front_material, back_material, materials)
        }
      end
      private_class_method :canonical_face

      def normalize_uv_for_materials(uv, front_material, back_material, materials)
        normalized = normalize_uv(uv)
        return nil if normalized.nil?

        result = {}
        if textured_material_reference?(front_material, materials)
          result[:front_outer] = normalized[:front_outer]
          result[:front_holes] = normalized[:front_holes]
        end
        if textured_material_reference?(back_material, materials)
          result[:back_outer] = normalized[:back_outer]
          result[:back_holes] = normalized[:back_holes]
        end
        result.empty? ? nil : result
      end
      private_class_method :normalize_uv_for_materials

      def textured_material_reference?(reference, materials)
        !reference.nil? && !Array(materials).dig(reference, :texture).nil?
      end
      private_class_method :textured_material_reference?

      def canonical_edge(edge, tag_index)
        {
          stable_id: edge[:id].to_s,
          persistent_id: source_identity_value(edge[:source_identity]),
          vertices: Array(edge[:vertices]).map(&:to_i),
          tag: optional_reference(tag_index, edge[:tag_id]),
          hidden: edge[:hidden] == true,
          soft: edge[:soft] == true,
          smooth: edge[:smooth] == true
        }
      end
      private_class_method :canonical_edge

      def canonical_fallback(node, base_path)
        kind = node[:kind].to_s
        case kind
        when 'image'
          image = node[:image] || {}
          texture = normalize_texture(
            {
              bytes: image[:bytes], filename: image[:filename], source_path: image[:filename],
              image_width_px: image[:image_width_px], image_height_px: image[:image_height_px],
              width_m: image[:width_m], height_m: image[:height_m]
            },
            base_path
          )
          {
            kind: 'image', position: Array(image[:position]).map(&:to_f),
            width_m: image[:width_m].to_f, height_m: image[:height_m].to_f,
            text: node[:name].to_s, texture: texture
          }
        when 'text'
          {
            kind: 'text', position: [0.0, 0.0, 0.0], width_m: 0.0, height_m: 0.0,
            text: (node[:text] || node[:name]).to_s, texture: nil,
            attachment: node.dig(:attachment, :target_persistent_id)
          }
        end
      end
      private_class_method :canonical_fallback

      def normalize_uv(uv)
        return nil unless uv.is_a?(Hash)

        result = {}
        [:front_outer, :back_outer].each do |key|
          result[key] = Array(uv[key]).map { |pair| Array(pair).map(&:to_f) }
        end
        [:front_holes, :back_holes].each do |key|
          result[key] = Array(uv[key]).map { |loop| Array(loop).map { |pair| Array(pair).map(&:to_f) } }
        end
        result
      end
      private_class_method :normalize_uv

      def normalize_transforms(transforms, checkpoint = nil)
        values = Array(transforms)
        return [IDENTITY.dup] if values.empty?
        if values[0].is_a?(Array)
          values.each_with_index.map do |matrix, index|
            notify(checkpoint, :encode_transforms, index + 1, values.length)
            Array(matrix).map(&:to_f)
          end
        else
          raise 'BOMC source invalid: transform table is not divisible by 16.' unless (values.length % 16).zero?
          values.each_slice(16).map { |matrix| matrix.map(&:to_f) }
        end
      end
      private_class_method :normalize_transforms

      def notify(checkpoint, stage, processed, total)
        checkpoint.call(stage: stage, processed: processed, total: total) if checkpoint
      end
      private_class_method :notify

      def decode_model_eval_positions(mesh)
        quantization = mesh[:quantization] || {}
        minimum = Array(quantization[:minimum_m]).map(&:to_f)
        scale = Array(quantization[:scale_m]).map(&:to_f)
        Array(mesh[:positions]).each_with_index.map do |value, index|
          minimum[index % 3].to_f + value.to_f * scale[index % 3].to_f
        end
      end
      private_class_method :decode_model_eval_positions

      def face_normal(positions, indices)
        return [0.0, 0.0, 0.0] if Array(indices).length < 3
        first = positions[indices[0].to_i * 3, 3]
        second = positions[indices[1].to_i * 3, 3]
        third = positions[indices[2].to_i * 3, 3]
        return [0.0, 0.0, 0.0] unless first && second && third
        left = 3.times.map { |axis| second[axis] - first[axis] }
        right = 3.times.map { |axis| third[axis] - first[axis] }
        cross = [
          left[1] * right[2] - left[2] * right[1],
          left[2] * right[0] - left[0] * right[2],
          left[0] * right[1] - left[1] * right[0]
        ]
        length = Math.sqrt(cross.map { |value| value * value }.inject(0.0, :+))
        length.zero? ? [0.0, 0.0, 0.0] : cross.map { |value| value / length }
      end
      private_class_method :face_normal

      def finalize(model)
        faces = model[:meshes].map { |mesh| mesh[:faces] }.flatten
        analytical = faces.count { |face| classified_surface?(face[:surface_type]) }
        fallback = faces.length - analytical
        model[:coverage] = {
          eligible: faces.length,
          analytical: analytical,
          visual_retained: model[:meshes].map { |mesh| mesh[:edges].length }.inject(0, :+) + model[:instances].count { |instance| !instance[:fallback].nil? },
          fallback: fallback,
          excluded: 0,
          unaccounted: faces.length - analytical - fallback
        }
        model[:bounds] = model_bounds(model[:meshes])
        model[:scenes] = Array(model[:scenes])
        model
      end
      private_class_method :finalize

      def classified_surface?(value)
        string = value.to_s.strip.downcase
        !string.empty? && !['unknown', 'none', 'geometry_fallback'].include?(string)
      end
      private_class_method :classified_surface?

      def model_bounds(meshes)
        values = Array(meshes).map { |mesh| mesh[:positions] }.flatten
        return { min: [0.0, 0.0, 0.0], max: [0.0, 0.0, 0.0] } if values.empty?
        minimum = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
        maximum = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
        values.each_with_index do |value, index|
          axis = index % 3
          minimum[axis] = value if value < minimum[axis]
          maximum[axis] = value if value > maximum[axis]
        end
        { min: minimum, max: maximum }
      end
      private_class_method :model_bounds

      def index_ids(items)
        result = {}
        Array(items).each_with_index { |item, index| result[item[:id]] = index }
        result
      end
      private_class_method :index_ids

      def index_node_ids(raw_nodes)
        result = {}
        Array(raw_nodes).each_with_index do |node, index|
          id = node[:id].to_s
          result[id] = index
          pid = source_identity_value(node[:source_identity]) || node[:persistent_id]
          if pid && !pid.to_s.empty?
            result[pid.to_s] ||= index
            result["node:pid:#{pid}"] ||= index
            result["node:#{pid}"] ||= index
          end
        end
        result
      end
      private_class_method :index_node_ids

      def fetch_reference(index, value, label)
        result = index[value]
        raise "BOMC source invalid: missing #{label} #{value}." if result.nil?
        result
      end
      private_class_method :fetch_reference

      def optional_reference(index, value)
        value.nil? ? nil : index[value]
      end
      private_class_method :optional_reference

      def optional_numeric(value)
        integer = value.nil? ? -1 : value.to_i
        integer < 0 ? nil : integer
      end
      private_class_method :optional_numeric

      def string_at(strings, index)
        return nil if index.nil? || index.to_i < 0
        strings[index.to_i]
      end
      private_class_method :string_at

      def parse_hex(value)
        hex = value.to_s.delete('#')
        return { r: 0, g: 0, b: 0, a: 255 } unless hex.length >= 6
        { r: hex[0, 2].to_i(16), g: hex[2, 2].to_i(16), b: hex[4, 2].to_i(16), a: 255 }
      end
      private_class_method :parse_hex

      def source_identity_value(identity)
        return nil unless identity.is_a?(Hash)
        identity[:persistent_id] || identity[:guid]
      end
      private_class_method :source_identity_value

      def absolute_path?(path)
        path =~ /\A(?:[A-Za-z]:[\\\/]|[\\\/]{2}|\/)/
      end
      private_class_method :absolute_path?

      def symbolize(value)
        case value
        when Hash
          result = {}
          value.each { |key, child| result[key.to_sym] = symbolize(child) }
          result
        when Array
          value.map { |child| symbolize(child) }
        else
          value
        end
      end
      private_class_method :symbolize

      def symbolize_if_needed(value)
        if value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(Symbol) }
          value
        else
          symbolize(value)
        end
      end
      private_class_method :symbolize_if_needed
    end
  end
end

end # SibamboHistory
