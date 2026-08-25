# Compact, plain-JSON runtime export for model-eval.

require 'digest'
require 'fileutils'
require 'json'
require_relative 'quantizer'

module SibamboHistory
  module V20260825_01
  module ModelEvalJSONWriter
    FORMAT_NAME = 'BOM Engine Model-Eval JSON'.freeze
    FORMAT_VERSION = '1.1.0'.freeze
    FORMAT_IDENTIFIER = 'model_eval_json_v1'.freeze
    SCHEMA_URI = 'https://sibambo.dev/schemas/bom-engine/model-eval-json/1.1.0/schema.json'.freeze

    def self.build(graph, progress: nil, batch_size: 128)
      Builder.new(graph, progress: progress, batch_size: batch_size).build
    end

    def self.write(path, graph, progress: nil, destructive: false, include_payload: true, batch_size: 128)
      payload = Builder.new(graph, progress: progress, batch_size: batch_size).build(destructive: destructive)
      validation = validate(payload, progress: progress)
      temp_path = "#{path}.#{Process.pid}.part"
      sha256 = nil
      begin
        File.open(temp_path, 'w:UTF-8') do |file|
          sha256 = StreamingJSONWriter.new(file, progress: progress, batch_size: batch_size).write(payload)
        end
        FileUtils.mv(temp_path, path, force: true)
      ensure
        File.delete(temp_path) if File.file?(temp_path)
      end
      result = {
        path: path,
        bytes: File.size(path),
        sha256: sha256,
        validation: validation
      }
      result[:payload] = payload if include_payload
      result
    end

    # Structural validation intentionally mirrors the runtime loader's bounds
    # checks. JSON Schema validates shape; this validates table references.
    def self.validate(payload, progress: nil)
      work_count = 0
      checkpoint = lambda do
        work_count += 1
        progress.call(stage: 'Validating output', processed: work_count) if progress && (work_count % 256).zero?
      end
      raise 'Model-Eval JSON invalid: format.' unless payload.dig(:format, :identifier) == FORMAT_IDENTIFIER && payload.dig(:format, :version) == FORMAT_VERSION
      strings = payload[:strings]
      seen_strings = {}
      unique_strings = strings.is_a?(Array) && strings.all? do |string|
        next false if seen_strings.key?(string)

        seen_strings[string] = true
      end
      raise 'Model-Eval JSON invalid: string table.' unless unique_strings
      transforms = payload[:transforms]
      raise 'Model-Eval JSON invalid: transform table.' unless transforms.is_a?(Array) && (transforms.length % 16).zero?

      meshes = payload[:meshes] || []
      materials = payload[:materials] || []
      tags = payload[:tags] || []
      definitions = payload[:definitions] || []
      nodes = payload[:nodes] || []
      meshes.each_with_index do |mesh, mesh_index|
        checkpoint.call
        values = mesh[:positions]
        loops = mesh[:loops]
        triangles = mesh[:triangles]
        vertex_count = mesh[:vertex_count].to_i
        raise "Model-Eval JSON invalid: mesh #{mesh_index} position count." unless values.is_a?(Array) && values.length == vertex_count * 3
        invalid_loop = !loops.is_a?(Array) || loops.any? do |index|
          checkpoint.call
          !index.is_a?(Integer) || index.negative? || index >= vertex_count
        end
        raise "Model-Eval JSON invalid: mesh #{mesh_index} loop index." if invalid_loop
        invalid_triangle = !triangles.is_a?(Array) || (triangles.length % 3) != 0 || triangles.any? do |index|
          checkpoint.call
          !index.is_a?(Integer) || index.negative? || index >= vertex_count
        end
        raise "Model-Eval JSON invalid: mesh #{mesh_index} triangle index." if invalid_triangle
        raise "Model-Eval JSON invalid: mesh #{mesh_index} triangle count." unless triangles.length / 3 == mesh[:triangle_count].to_i
        raise "Model-Eval JSON invalid: mesh #{mesh_index} definition." unless mesh[:definition].is_a?(Integer) && mesh[:definition].between?(0, definitions.length - 1)
        Array(mesh[:faces]).each do |face|
          checkpoint.call
          raise "Model-Eval JSON invalid: mesh #{mesh_index} face row." unless face.is_a?(Array) && face.length == 16
          ranges = [[face[2], face[3]]] + Array(face[4])
          ranges.each do |range|
            raise "Model-Eval JSON invalid: mesh #{mesh_index} loop range." unless range.is_a?(Array) && range.length == 2 && range[0].is_a?(Integer) && range[1].is_a?(Integer) && range[0] >= 0 && range[1] >= 3 && range[0] + range[1] <= loops.length
          end
          raise "Model-Eval JSON invalid: mesh #{mesh_index} triangle range." unless face[5].is_a?(Integer) && face[6].is_a?(Integer) && face[5] >= 0 && face[6] >= 0 && (face[6] % 3).zero? && face[5] + face[6] <= triangles.length
          [face[7], face[8]].each { |index| raise "Model-Eval JSON invalid: mesh #{mesh_index} material." unless index.is_a?(Integer) && index >= -1 && index < materials.length }
          raise "Model-Eval JSON invalid: mesh #{mesh_index} tag." unless face[9].is_a?(Integer) && face[9] >= -1 && face[9] < tags.length
          [face[0], face[1], face[10]].each { |index| raise "Model-Eval JSON invalid: mesh #{mesh_index} string." unless index.is_a?(Integer) && index >= -1 && index < strings.length }
          face[12, 4].each { |index| raise "Model-Eval JSON invalid: mesh #{mesh_index} semantic string." unless index.is_a?(Integer) && index >= -1 && index < strings.length }
        end
      end
      definitions.each_with_index do |definition, index|
        checkpoint.call
        raise "Model-Eval JSON invalid: definition #{index}." unless definition.is_a?(Array) && definition.length == 5
        raise "Model-Eval JSON invalid: definition #{index} mesh." unless definition[3].is_a?(Integer) && definition[3] >= -1 && definition[3] < meshes.length
        valid_nodes = definition[4].is_a?(Array) && definition[4].all? do |node|
          checkpoint.call
          node.is_a?(Integer) && node.between?(0, nodes.length - 1)
        end
        raise "Model-Eval JSON invalid: definition #{index} nodes." unless valid_nodes
      end
      nodes.each_with_index do |node, index|
        checkpoint.call
        raise "Model-Eval JSON invalid: node #{index}." unless node.is_a?(Array) && node.length == 13
        raise "Model-Eval JSON invalid: node #{index} definition." unless node[3].is_a?(Integer) && node[3].between?(0, definitions.length - 1)
        raise "Model-Eval JSON invalid: node #{index} transform." unless node[4].is_a?(Integer) && node[4].between?(0, transforms.length / 16 - 1)
        material_ref, tag_ref = node[5], node[6]
        unless material_ref.is_a?(Integer) && material_ref >= -1 && material_ref < materials.length
          raise "Model-Eval JSON invalid: node #{index} material reference."
        end
        unless tag_ref.is_a?(Integer) && tag_ref >= -1 && tag_ref < tags.length
          raise "Model-Eval JSON invalid: node #{index} tag reference."
        end
        node[9, 4].each { |value| raise "Model-Eval JSON invalid: node #{index} semantic string." unless value.is_a?(Integer) && value >= -1 && value < strings.length }
      end
      raise 'Model-Eval JSON invalid: root node.' unless payload[:root_node].is_a?(Integer) && payload[:root_node].between?(0, nodes.length - 1)
      { meshes: meshes.length, definitions: definitions.length, nodes: nodes.length, triangles: meshes.sum { |mesh| mesh[:triangle_count].to_i }, quantization_max_error_m: meshes.map { |mesh| mesh.dig(:quantization, :measured_max_error_m).to_f }.max || 0.0 }
    end

    class StringTable
      attr_reader :values

      def initialize
        @values = []
        @index = {}
      end

      def intern(value)
        return -1 if value.nil?
        string = value.to_s
        return @index[string] if @index.key?(string)
        @index[string] = @values.length
        @values << string
        @index[string]
      end
    end

    class Builder
      def initialize(graph, progress: nil, batch_size: 128)
        @graph = graph
        @strings = StringTable.new
        @progress = progress
        @batch_size = [batch_size.to_i, 1].max
        @work_count = 0
      end

      def build(destructive: false)
        materials = Array(@graph[:materials])
        tags = Array(@graph[:tags])
        definitions = Array(@graph[:definitions])
        # Text and image nodes do not instantiate reusable geometry. Attached
        # text has already been resolved into target semantics by the graph
        # builder, so compact runtime nodes can stay definition-only.
        nodes = Array(@graph[:nodes]).select { |node| node[:kind] == 'root' || !node[:definition_id].nil? }
        meshes = Array(@graph[:meshes])
        material_index = index_by_id(materials)
        tag_index = index_by_id(tags)
        definition_index = index_by_id(definitions)
        node_index = index_by_id(nodes)
        mesh_index = index_by_id(meshes)
        root_node = nil
        component_instances = 0
        group_instances = 0
        nodes.each_with_index do |node, index|
          checkpoint('Indexing Model-Eval nodes')
          root_node = index if root_node.nil? && node[:kind] == 'root'
          component_instances += 1 if node[:kind] == 'component_instance'
          group_instances += 1 if node[:kind] == 'group_instance'
        end
        coordinate_system = @graph[:coordinate_system]
        source = compact_source(@graph[:source] || {})

        compact_materials = transform_collection(materials, destructive, 'Compacting materials') { |material| compact_material(material) }
        compact_tags = transform_collection(tags, destructive, 'Compacting tags') do |tag|
          [@strings.intern(tag[:id]), @strings.intern(tag[:name]), tag[:visible] != false]
        end
        transforms = Array(@graph[:transforms])
        if destructive
          transforms.flatten!
          transforms.map!(&:to_f)
        else
          transforms = transforms.flatten.map(&:to_f)
        end
        compact_meshes = transform_collection(meshes, destructive, 'Compacting meshes') do |mesh|
          compact_mesh(mesh, definition_index, material_index, tag_index)
        end
        compact_definitions = transform_collection(definitions, destructive, 'Compacting definitions') do |definition|
          compact_definition(definition, node_index, mesh_index)
        end
        compact_nodes = transform_collection(nodes, destructive, 'Compacting nodes') do |node|
          compact_node(node, definition_index, material_index, tag_index)
        end

        values = {
          format: { name: FORMAT_NAME, version: FORMAT_VERSION, identifier: FORMAT_IDENTIFIER, schema: SCHEMA_URI },
          units: 'm',
          coordinate_system: coordinate_system,
          source: source,
          strings: @strings.values,
          materials: compact_materials,
          tags: compact_tags,
          transforms: transforms,
          meshes: compact_meshes,
          definitions: compact_definitions,
          nodes: compact_nodes,
          root_node: root_node,
          statistics: nil
        }
        values[:scenes] = @graph[:scenes] if @graph[:scenes] && !@graph[:scenes].empty?
        values[:statistics] = {
          unique_meshes: compact_meshes.length,
          definitions: compact_definitions.length,
          nodes: compact_nodes.length,
          component_instances: component_instances,
          group_instances: group_instances,
          labeled_nodes: compact_nodes.count { |node| node[9] >= 0 },
          label_role_nodes: compact_nodes.count { |node| node[11] >= 0 },
          geometry_fallback_nodes: compact_nodes.count { |node| @strings.values[node[12]] == 'geometry_fallback' },
          unique_vertices: compact_meshes.sum { |mesh| mesh[:vertex_count] },
          triangles: compact_meshes.sum { |mesh| mesh[:triangle_count] }
        }
        payload = destructive ? @graph.clear.merge!(values) : values
        checkpoint('Model-Eval payload ready', force: true)
        payload
      end

      private

      def compact_source(source)
        [@strings.intern(source[:file_name]), @strings.intern(source[:model_name]), @strings.intern(source[:scope]), @strings.intern(source[:exported_at])]
      end

      def compact_material(material)
        color = material[:color] || {}
        [@strings.intern(material[:id]), @strings.intern(material[:name]), @strings.intern(color[:hex]), material[:opacity].to_f]
      end

      def compact_mesh(mesh, definition_index, material_index, tag_index)
        quantized = Quantizer.quantize_positions(mesh[:positions_m], progress: @progress)
        loops = []
        triangles = []
        faces = Array(mesh[:faces]).map do |face|
          checkpoint('Compacting mesh faces')
          outer_start = loops.length
          loops.concat(face[:outer])
          holes = Array(face[:holes]).map do |hole|
            start = loops.length
            loops.concat(hole)
            [start, hole.length]
          end
          triangle_start = triangles.length
          face_triangles = Array(face[:triangles])
          triangles.concat(face_triangles)
          [
            @strings.intern(face[:id]),
            @strings.intern(face.dig(:source_identity, :persistent_id)),
            outer_start,
            Array(face[:outer]).length,
            holes,
            triangle_start,
            face_triangles.length,
            value_index(material_index, face[:front_material_id]),
            value_index(material_index, face[:back_material_id]),
            value_index(tag_index, face[:tag_id]),
            @strings.intern(face[:surface_hint]),
            face[:area_m2].to_f,
            @strings.intern(face.dig(:semantic, :label)),
            @strings.intern(face.dig(:semantic, :source) || 'none'),
            @strings.intern(face.dig(:semantic, :role)),
            @strings.intern(face.dig(:semantic, :classification_policy) || 'geometry_fallback')
          ]
        end
        {
          id: @strings.intern(mesh[:id]),
          definition: definition_index.fetch(mesh[:definition_id]),
          vertex_count: Array(mesh[:positions_m]).length / 3,
          triangle_count: triangles.length / 3,
          quantization: quantized.reject { |key, _| key == :values },
          positions: quantized[:values],
          loops: loops,
          triangles: triangles,
          faces: faces
        }
      end

      def compact_definition(definition, node_index, mesh_index)
        [
          @strings.intern(definition[:id]),
          @strings.intern(definition[:name]),
          @strings.intern(definition[:kind]),
          value_index(mesh_index, definition[:mesh_id]),
          Array(definition[:node_ids]).each_with_object([]) do |id, result|
            checkpoint('Linking definition nodes')
            index = node_index[id]
            result << index unless index.nil?
          end
        ]
      end

      def compact_node(node, definition_index, material_index, tag_index)
        semantic = node[:semantic] || {}
        [
          @strings.intern(node[:id]),
          @strings.intern(node[:name]),
          node_kind(node[:kind]),
          definition_index.fetch(node[:definition_id]),
          node[:transform_id].to_i,
          value_index(material_index, node[:material_override_id]),
          value_index(tag_index, node[:tag_id]),
          node[:visible] != false,
          @strings.intern(node.dig(:source_identity, :persistent_id)),
          @strings.intern(semantic[:label]),
          @strings.intern(semantic[:source] || 'none'),
          @strings.intern(semantic[:role]),
          @strings.intern(semantic[:classification_policy] || 'geometry_fallback')
        ]
      end

      def node_kind(kind)
        { 'root' => 1, 'component_instance' => 2, 'group_instance' => 3, 'image' => 4, 'text' => 5 }.fetch(kind, 0)
      end

      def index_by_id(items)
        items.each_with_index.each_with_object({}) do |(item, index), result|
          checkpoint('Indexing export tables')
          result[item[:id]] = index
        end
      end

      def value_index(index, value)
        value.nil? ? -1 : index.fetch(value, -1)
      end

      def transform_collection(collection, destructive, stage)
        transform = lambda do |item|
          checkpoint(stage)
          yield item
        end
        destructive ? collection.map!(&transform) : collection.map(&transform)
      end

      def checkpoint(stage, force: false)
        return if @progress.nil?

        @work_count += 1
        return unless force || (@work_count % @batch_size).zero?

        @progress.call(stage: stage, processed: @work_count)
      end
    end

    # Writes JSON recursively in small chunks. Avoids allocating a second,
    # output-sized String and keeps SketchUp responsive through checkpoints.
    class StreamingJSONWriter
      BUFFER_BYTES = 64 * 1024

      def initialize(io, progress: nil, batch_size: 512)
        @io = io
        @progress = progress
        @batch_size = [batch_size.to_i, 1].max
        @work_count = 0
        @digest = Digest::SHA256.new
        @buffer = +''
      end

      def write(value)
        write_value(value)
        flush
        @digest.hexdigest
      end

      private

      def write_value(value)
        checkpoint
        case value
        when Hash
          write_chunk('{')
          value.each_with_index do |(key, child), index|
            write_chunk(',') unless index.zero?
            write_chunk(JSON.generate(key.to_s))
            write_chunk(':')
            write_value(child)
          end
          write_chunk('}')
        when Array
          write_chunk('[')
          value.each_with_index do |child, index|
            write_chunk(',') unless index.zero?
            write_value(child)
          end
          write_chunk(']')
        else
          write_chunk(JSON.generate(value))
        end
      end

      def write_chunk(chunk)
        @buffer << chunk
        flush if @buffer.bytesize >= BUFFER_BYTES
      end

      def flush
        return if @buffer.empty?

        @io.write(@buffer)
        @digest.update(@buffer)
        @buffer.clear
      end

      def checkpoint
        return if @progress.nil?

        @work_count += 1
        return unless (@work_count % @batch_size).zero?

        @progress.call(stage: 'Writing JSON incrementally', processed: @work_count)
      end
    end
  end
end

end # SibamboHistory
