# frozen_string_literal: true

require 'json'
require_relative 'evolution_document'
require_relative 'evolution_stream'
require_relative 'performance_trace'

module BOMEngine
  module EvolutionTreeWriter
    module_function

    def build(document)
      PerformanceTrace.stage(:e1_occurrence_expansion) do
        EvolutionDocument.validate!(document)
        graph = document.fetch('graph')
        definitions = index_by_id(graph['definitions'])
        meshes = index_by_id(graph['meshes'])
        nodes = index_by_id(graph['nodes'])
        transforms = Array(graph['transforms'])
        prepared_definitions = prepare_definitions(definitions, meshes)
        root = Array(graph['nodes']).find { |node| node['kind'] == 'root' }
        raise ArgumentError, 'E1 requires exactly one root node' unless root

        root_matrix = transform_at(transforms, root['transform_id'])
        entities = instantiate_definition(
          root.fetch('definition_id'), root_matrix, root.fetch('id'), nil,
          prepared_definitions: prepared_definitions, nodes: nodes, transforms: transforms, ancestry: []
        )
        {
          'schema_version' => '2.2',
          'format' => 'sibambo-evolution-e1',
          'profile' => document.fetch('profile'),
          'evolution' => EvolutionDocument.deep_copy(graph.fetch('evolution')),
          'units' => EvolutionDocument.deep_copy(graph['units'] || {}),
          'coordinate_system' => EvolutionDocument.deep_copy(graph['coordinate_system'] || {}),
          'source' => EvolutionDocument.deep_copy(graph['source'] || {}),
          'metadata' => EvolutionDocument.deep_copy(graph['metadata'] || {}),
          'tags' => EvolutionDocument.deep_copy(graph['tags'] || []),
          'materials' => EvolutionDocument.deep_copy(graph['materials'] || []),
          'assets' => EvolutionDocument.json_asset_table(document),
          'scenes' => EvolutionDocument.deep_copy(graph['scenes'] || []),
          'clip_planes' => EvolutionDocument.deep_copy(graph['clip_planes'] || []),
          'scene_fidelity_manifest' => EvolutionDocument.deep_copy(graph['scene_fidelity_manifest'] || {}),
          'entities' => entities
        }
      end
    end

    def write(path, document)
      PerformanceTrace.stage(:e1_serialize) do
        EvolutionDocument.validate!(document)
        graph = document.fetch('graph')
        definitions = index_by_id(graph['definitions'])
        meshes = index_by_id(graph['meshes'])
        nodes = index_by_id(graph['nodes'])
        transforms = Array(graph['transforms'])
        prepared_definitions = prepare_definitions(definitions, meshes)
        root = Array(graph['nodes']).find { |node| node['kind'] == 'root' }
        raise ArgumentError, 'E1 requires exactly one root node' unless root
        root_matrix = transform_at(transforms, root['transform_id'])
        result = nil
        PerformanceTrace.stage(:e1_file_write) do
          File.open(path, 'wb') do |file|
            digest_io = EvolutionStream::DigestIO.new(file)
            io = EvolutionStream::BufferedIO.new(digest_io)
            io.write('{')
            write_pair(io, 'schema_version', '2.2', true)
            write_pair(io, 'format', 'sibambo-evolution-e1')
            write_pair(io, 'profile', document.fetch('profile'))
            write_pair(io, 'evolution', graph.fetch('evolution'))
            write_pair(io, 'units', graph['units'] || {})
            write_pair(io, 'coordinate_system', graph['coordinate_system'] || {})
            write_pair(io, 'source', graph['source'] || {})
            write_pair(io, 'metadata', graph['metadata'] || {})
            write_pair(io, 'tags', graph['tags'] || [])
            write_pair(io, 'materials', graph['materials'] || [])
            io.write(',')
            io.write(JSON.generate('assets'))
            io.write(':')
            EvolutionStream.write_assets(io, document.fetch('assets'))
            write_pair(io, 'scenes', graph['scenes'] || [])
            write_pair(io, 'clip_planes', graph['clip_planes'] || [])
            write_pair(io, 'scene_fidelity_manifest', graph['scene_fidelity_manifest'] || {})
            io.write(',')
            io.write(JSON.generate('entities'))
            io.write(':')
            write_definition_entities(
              io, root.fetch('definition_id'), root_matrix, root.fetch('id'), nil,
              prepared_definitions: prepared_definitions, nodes: nodes, transforms: transforms, ancestry: []
            )
            io.write('}')
            io.flush
            digest_io.flush
            result = { path: path, bytes: digest_io.bytes, sha256: digest_io.sha256 }
          end
        end
        result
      end
    end

    def instantiate_definition(definition_id, world, path, inherited_material_id, prepared_definitions:, nodes:, transforms:, ancestry:)
      raise ArgumentError, "Recursive definition cycle: #{(ancestry + [definition_id]).join(' -> ')}" if ancestry.include?(definition_id)
      prepared = prepared_definitions.fetch(definition_id) { raise ArgumentError, "Missing definition #{definition_id}" }
      definition = prepared.fetch(:definition)
      next_ancestry = ancestry + [definition_id]
      context = occurrence_context(world, path)
      children = []
      if prepared[:mesh]
        prepared.fetch(:faces).each do |face, face_index|
          children << world_face(face, face_index, prepared, definition, context, path, inherited_material_id)
        end
        prepared.fetch(:edges).each do |edge, edge_index|
          children << world_edge(edge, edge_index, prepared, definition, world, path)
        end
      end

      Array(definition['node_ids']).each do |node_id|
        node = nodes.fetch(node_id) { raise ArgumentError, "Missing node #{node_id}" }
        unless node['definition_id']
          children << fallback_entity(node, world, transforms, path)
          next
        end
        child_world = multiply(world, transform_at(transforms, node['transform_id']))
        child_path = "#{path}/#{node.fetch('id')}"
        nested = instantiate_definition(
          node.fetch('definition_id'), child_world, child_path, node['material_override_id'] || inherited_material_id,
          prepared_definitions: prepared_definitions, nodes: nodes, transforms: transforms, ancestry: next_ancestry
        )
        children << {
          'id' => child_path,
          'type' => node['kind'] == 'component_instance' ? 'ComponentInstance' : 'Group',
          'name' => node['name'].to_s,
          'source_node_id' => node['id'],
          'source_definition_id' => node['definition_id'],
          'instance_path' => child_path,
          'tag_id' => node['tag_id'],
          'material_override_id' => node['material_override_id'],
          'inherited_material_id' => inherited_material_id,
          'visible' => node.key?('visible') ? node['visible'] : true,
          'semantic' => EvolutionDocument.deep_copy(node['semantic'] || {}),
          'children' => nested
        }
      end
      children
    end
    private_class_method :instantiate_definition

    def world_face(face, face_index, prepared, definition, context, path, inherited_material_id)
      mirrored = context.fetch(:mirrored)
      positions = prepared.fetch(:positions)
      world = context.fetch(:world)
      point = ->(index) { transform_point(position_at(positions, index), world) }
      outer = Array(face.fetch('outer')).map(&point)
      holes = Array(face['holes']).map { |loop| Array(loop).map(&point) }
      triangles = Array(face['triangles']).each_slice(3).map { |triangle| triangle.map(&point) }
      uv = EvolutionDocument.deep_copy(face['uv'] || {})
      if mirrored
        outer.reverse!
        holes.each(&:reverse!)
        triangles.each { |triangle| triangle[1], triangle[2] = triangle[2], triangle[1] if triangle.length == 3 }
        reverse_uv_loops!(uv)
      end
      normal = transform_normal(Array(face['normal'] || [0.0, 0.0, 1.0]), context.fetch(:normal_matrix))
      source_identity = face['source_identity'] || {}
      {
        'id' => "#{path}:#{face.fetch('id')}",
        'type' => 'Face',
        'source_face_id' => face['id'],
        'source_definition_id' => definition['id'],
        'instance_path' => path,
        'source_indices' => { 'face' => face_index, 'persistent_id' => source_identity['persistent_id'] },
        'vertices' => outer,
        'holes' => holes,
        'triangles' => triangles,
        'uv' => uv,
        'normal' => normal,
        'area_m2' => triangles.sum { |triangle| triangle_area(triangle) },
        'front_material_id' => face['front_material_id'],
        'back_material_id' => face['back_material_id'],
        'inherited_material_id' => inherited_material_id,
        'front_appearance_required' => face['front_appearance_required'] != false,
        'back_appearance_required' => face['back_appearance_required'] == true,
        'tag_id' => face['tag_id'],
        'hidden' => face['hidden'] == true,
        'surface_hint' => face['surface_hint'],
        'semantic' => EvolutionDocument.deep_copy(face['semantic'] || {}),
        'mirrored' => mirrored
      }
    end
    private_class_method :world_face

    def world_edge(edge, edge_index, prepared, definition, world, path)
      positions = prepared.fetch(:positions)
      vertices = Array(edge.fetch('vertices')).map { |index| transform_point(position_at(positions, index), world) }
      source_identity = edge['source_identity'] || {}
      {
        'id' => "#{path}:#{edge.fetch('id')}",
        'type' => 'Edge',
        'source_edge_id' => edge['id'],
        'source_definition_id' => definition['id'],
        'instance_path' => path,
        'source_indices' => { 'edge' => edge_index, 'persistent_id' => source_identity['persistent_id'] },
        'vertices' => vertices,
        'tag_id' => edge['tag_id'],
        'hidden' => edge['hidden'] == true,
        'soft' => edge['soft'] == true,
        'smooth' => edge['smooth'] == true
      }
    end
    private_class_method :world_edge

    def write_pair(io, key, value, first = false)
      io.write(',') unless first
      io.write(JSON.generate(key))
      io.write(':')
      EvolutionStream.write_json(io, value)
    end
    private_class_method :write_pair

    def write_definition_entities(io, definition_id, world, path, inherited_material_id, prepared_definitions:, nodes:, transforms:, ancestry:)
      raise ArgumentError, "Recursive definition cycle: #{(ancestry + [definition_id]).join(' -> ')}" if ancestry.include?(definition_id)
      prepared = prepared_definitions.fetch(definition_id) { raise ArgumentError, "Missing definition #{definition_id}" }
      definition = prepared.fetch(:definition)
      next_ancestry = ancestry + [definition_id]
      context = occurrence_context(world, path)
      first = true
      io.write('[')
      if prepared[:mesh]
        prepared.fetch(:faces).each do |face, face_index|
          io.write(',') unless first
          first = false
          io.write(JSON.generate(world_face(face, face_index, prepared, definition, context, path, inherited_material_id)))
        end
        prepared.fetch(:edges).each do |edge, edge_index|
          io.write(',') unless first
          first = false
          io.write(JSON.generate(world_edge(edge, edge_index, prepared, definition, world, path)))
        end
      end
      Array(definition['node_ids']).each do |node_id|
        node = nodes.fetch(node_id) { raise ArgumentError, "Missing node #{node_id}" }
        io.write(',') unless first
        first = false
        unless node['definition_id']
          io.write(JSON.generate(fallback_entity(node, world, transforms, path)))
          next
        end
        child_world = multiply(world, transform_at(transforms, node['transform_id']))
        child_path = "#{path}/#{node.fetch('id')}"
        io.write('{')
        write_pair(io, 'id', child_path, true)
        write_pair(io, 'type', node['kind'] == 'component_instance' ? 'ComponentInstance' : 'Group')
        write_pair(io, 'name', node['name'].to_s)
        write_pair(io, 'source_node_id', node['id'])
        write_pair(io, 'source_definition_id', node['definition_id'])
        write_pair(io, 'instance_path', child_path)
        write_pair(io, 'tag_id', node['tag_id'])
        write_pair(io, 'material_override_id', node['material_override_id'])
        write_pair(io, 'inherited_material_id', inherited_material_id)
        write_pair(io, 'visible', node.key?('visible') ? node['visible'] : true)
        write_pair(io, 'semantic', node['semantic'] || {})
        io.write(',')
        io.write(JSON.generate('children'))
        io.write(':')
        write_definition_entities(
          io, node.fetch('definition_id'), child_world, child_path, node['material_override_id'] || inherited_material_id,
          prepared_definitions: prepared_definitions, nodes: nodes, transforms: transforms, ancestry: next_ancestry
        )
        io.write('}')
      end
      io.write(']')
    end
    private_class_method :write_definition_entities

    def prepare_definitions(definitions, meshes)
      definitions.each_with_object({}) do |(id, definition), result|
        mesh = definition['mesh_id'] ? meshes.fetch(definition['mesh_id']) { raise ArgumentError, "Missing mesh #{definition['mesh_id']}" } : nil
        result[id] = {
          definition: definition,
          mesh: mesh,
          positions: mesh ? Array(mesh.fetch('positions_m')) : [],
          faces: mesh ? Array(mesh['faces']).each_with_index.map { |face, index| [face, index] } : [],
          edges: mesh ? Array(mesh['edges']).each_with_index.map { |edge, index| [edge, index] } : []
        }
      end
    end
    private_class_method :prepare_definitions

    def occurrence_context(world, path)
      determinant = determinant3(world)
      raise ArgumentError, "Singular transform for occurrence #{path}" if determinant.abs < 1.0e-12
      {
        world: world,
        mirrored: determinant.negative?,
        normal_matrix: inverse_transpose3(world, determinant)
      }
    end
    private_class_method :occurrence_context

    def fallback_entity(node, parent_world, transforms, path)
      world = multiply(parent_world, transform_at(transforms, node['transform_id']))
      {
        'id' => "#{path}/#{node.fetch('id')}",
        'type' => node.fetch('kind').to_s == 'image' ? 'Image' : 'Text',
        'source_node_id' => node['id'],
        'instance_path' => path,
        'name' => node['name'].to_s,
        'tag_id' => node['tag_id'],
        'material_override_id' => node['material_override_id'],
        'visible' => node.key?('visible') ? node['visible'] : true,
        'world_transform' => world,
        'image' => EvolutionDocument.deep_copy(node['image']),
        'text' => node['text'],
        'attachment' => EvolutionDocument.deep_copy(node['attachment']),
        'source_identity' => EvolutionDocument.deep_copy(node['source_identity'] || {}),
        'semantic' => EvolutionDocument.deep_copy(node['semantic'] || {})
      }
    end
    private_class_method :fallback_entity

    def reverse_uv_loops!(uv)
      %w[front_outer back_outer].each { |key| uv[key].reverse! if uv[key].is_a?(Array) }
      %w[front_holes back_holes].each { |key| Array(uv[key]).each(&:reverse!) if uv[key].is_a?(Array) }
    end
    private_class_method :reverse_uv_loops!

    def position_at(flat, index)
      offset = Integer(index) * 3
      [Float(flat.fetch(offset)), Float(flat.fetch(offset + 1)), Float(flat.fetch(offset + 2))]
    end
    private_class_method :position_at

    def transform_at(transforms, index)
      matrix = transforms.fetch(Integer(index || 0))
      raise ArgumentError, 'Transform must contain 16 finite numbers' unless matrix.is_a?(Array) && matrix.length == 16 && matrix.all? { |value| value.is_a?(Numeric) && value.finite? }
      matrix.map(&:to_f)
    end
    private_class_method :transform_at

    def multiply(left, right)
      Array.new(16, 0.0).tap do |output|
        4.times do |column|
          4.times do |row|
            output[column * 4 + row] = 4.times.sum { |k| left[k * 4 + row] * right[column * 4 + k] }
          end
        end
      end
    end
    private_class_method :multiply

    def transform_point(point, matrix)
      x, y, z = point
      [
        matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
        matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
        matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14]
      ]
    end
    private_class_method :transform_point

    def determinant3(matrix)
      matrix[0] * (matrix[5] * matrix[10] - matrix[9] * matrix[6]) -
        matrix[4] * (matrix[1] * matrix[10] - matrix[9] * matrix[2]) +
        matrix[8] * (matrix[1] * matrix[6] - matrix[5] * matrix[2])
    end
    private_class_method :determinant3

    def inverse_transpose3(matrix, determinant = determinant3(matrix))
      a, b, c = matrix[0], matrix[4], matrix[8]
      d, e, f = matrix[1], matrix[5], matrix[9]
      g, h, i = matrix[2], matrix[6], matrix[10]
      raise ArgumentError, 'Singular transform cannot preserve normals' if determinant.abs < 1.0e-12
      [
        (e * i - f * h) / determinant, (c * h - b * i) / determinant, (b * f - c * e) / determinant,
        (f * g - d * i) / determinant, (a * i - c * g) / determinant, (c * d - a * f) / determinant,
        (d * h - e * g) / determinant, (b * g - a * h) / determinant, (a * e - b * d) / determinant
      ]
    end
    private_class_method :inverse_transpose3

    def transform_normal(normal, inverse)
      x, y, z = normal.map(&:to_f)
      result = [
        inverse[0] * x + inverse[3] * y + inverse[6] * z,
        inverse[1] * x + inverse[4] * y + inverse[7] * z,
        inverse[2] * x + inverse[5] * y + inverse[8] * z
      ]
      length = Math.sqrt(result.sum { |value| value * value })
      raise ArgumentError, 'Transformed normal is degenerate' if length <= 1.0e-15
      result.map { |value| value / length }
    end
    private_class_method :transform_normal

    def triangle_area(triangle)
      return 0.0 unless triangle.length == 3
      a, b, c = triangle
      ab = [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
      ac = [c[0] - a[0], c[1] - a[1], c[2] - a[2]]
      cross = [
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0]
      ]
      Math.sqrt(cross.sum { |value| value * value }) * 0.5
    end
    private_class_method :triangle_area

    def index_by_id(items)
      Array(items).each_with_object({}) { |item, result| result[item.fetch('id')] = item }
    end
    private_class_method :index_by_id
  end
end
