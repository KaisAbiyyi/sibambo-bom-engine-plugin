# frozen_string_literal: true

require 'json'
require_relative 'evolution_document'
require_relative 'evolution_cleanpkg/section_writer'
require_relative 'evolution_cleanpkg/deterministic_zip'

module BOMEngine
  module EvolutionCleanPKGWriter
    UINT32_NONE = 0xffff_ffff
    module_function

    def build(document)
      EvolutionDocument.validate!(document)
      graph = document.fetch('graph')
      writer = EvolutionCleanPKG::SectionWriter.new
      material_index = Array(graph['materials']).each_with_index.to_h { |material, index| [material['id'], index] }
      definition_index = Array(graph['definitions']).each_with_index.to_h { |definition, index| [definition['id'], index] }
      mesh_index = Array(graph['meshes']).each_with_index.to_h { |mesh, index| [mesh['id'], index] }

      mesh_rows = Array(graph['meshes']).each_with_index.map do |mesh, index|
        encode_mesh(writer, mesh, index, material_index)
      end
      instances = encode_instances(writer, graph, definition_index, material_index)
      raw_sections = writer.sections
      section_index = raw_sections.keys.each_with_index.to_h
      manifest = {
        'format' => { 'identifier' => 'bom_engine_clean_package', 'version' => '1.1.0' },
        'evolution' => EvolutionDocument.deep_copy(graph.fetch('evolution')),
        'units' => EvolutionDocument.deep_copy(graph['units'] || {}),
        'coordinate_system' => EvolutionDocument.deep_copy(graph['coordinate_system'] || {}),
        'source' => EvolutionDocument.deep_copy(graph['source'] || {}),
        'metadata' => EvolutionDocument.deep_copy(graph['metadata'] || {}),
        'tags' => EvolutionDocument.deep_copy(graph['tags'] || []),
        'materials' => clean_materials(graph['materials']),
        'definitions' => Array(graph['definitions']).map do |definition|
          EvolutionDocument.deep_copy(definition).merge('mesh_index' => definition['mesh_id'] ? mesh_index.fetch(definition['mesh_id']) : nil)
        end,
        'meshes' => mesh_rows,
        'instances_v1_1' => instances,
        'scenes' => EvolutionDocument.deep_copy(graph['scenes'] || []),
        'clip_planes' => EvolutionDocument.deep_copy(graph['clip_planes'] || []),
        'scene_fidelity_manifest' => EvolutionDocument.deep_copy(graph['scene_fidelity_manifest'] || {}),
        'assets' => Array(document['assets']).map { |asset| asset.reject { |key, _| key == 'bytes' } },
        'buffers' => {
          'uri' => 'buffers.bin',
          'byte_length' => writer.bytes.bytesize,
          'padding_bytes' => writer.padding_bytes,
          'endianness' => 'little',
          'section_descriptor_fields' => %w[byte_offset byte_length count component_count component_type],
          'sections' => raw_sections.values.map do |descriptor|
            [descriptor['byte_offset'], descriptor['byte_length'], descriptor['count'], descriptor['component_count'], descriptor['component_type']]
          end
        }
      }
      replace_section_names!(manifest, section_index)
      { manifest: manifest, buffers: writer.bytes }
    end

    def write(path, document)
      built = build(document)
      entries = {
        'manifest.json' => JSON.generate(built.fetch(:manifest)),
        'buffers.bin' => built.fetch(:buffers)
      }
      Array(document.fetch('assets')).each { |asset| entries[asset.fetch('path')] = asset.fetch('bytes') }
      EvolutionCleanPKG::DeterministicZip.write(path, entries)
      { path: path, bytes: File.size(path) }
    end

    def encode_mesh(writer, mesh, index, material_index)
      prefix = format('mesh_%06d', index)
      positions = Array(mesh.fetch('positions_m')).map(&:to_f)
      triangles = []
      triangle_offsets = [0]
      outer = []
      outer_offsets = [0]
      holes = []
      hole_offsets = [0]
      face_hole_offsets = [0]
      normals = []
      areas = []
      front_materials = []
      back_materials = []
      face_meta = []
      front_uv_values = []
      front_uv_offsets = [0]
      back_uv_values = []
      back_uv_offsets = [0]
      edge_vertices = []
      edge_metadata = []

      Array(mesh['faces']).each_with_index do |face, face_index|
        outer.concat(Array(face['outer']).map { |value| Integer(value) })
        outer_offsets << outer.length
        Array(face['holes']).each do |loop|
          holes.concat(Array(loop).map { |value| Integer(value) })
          hole_offsets << holes.length
        end
        face_hole_offsets << hole_offsets.length - 1
        triangles.concat(Array(face['triangles']).map { |value| Integer(value) })
        triangle_offsets << triangles.length
        normals.concat(Array(face['normal'] || [0.0, 0.0, 1.0]).map(&:to_f))
        areas << Float(face['area_m2'] || 0.0)
        front_materials << material_ref(material_index, face['front_material_id'])
        back_materials << material_ref(material_index, face['back_material_id'])
        uv = face['uv'] || {}
        append_uv(front_uv_values, front_uv_offsets, uv['front_outer'], uv['front_holes'])
        append_uv(back_uv_values, back_uv_offsets, uv['back_outer'], uv['back_holes'])
        front_uv_loops = [uv['front_outer'], *Array(uv['front_holes'])].select { |loop| loop.is_a?(Array) }
        back_uv_loops = [uv['back_outer'], *Array(uv['back_holes'])].select { |loop| loop.is_a?(Array) }
        face_meta << {
          'id' => face['id'],
          'source_identity' => EvolutionDocument.deep_copy(face['source_identity'] || {}),
          'tag_id' => face['tag_id'],
          'hidden' => face['hidden'] == true,
          'surface_hint' => face['surface_hint'],
          'semantic' => EvolutionDocument.deep_copy(face['semantic'] || {}),
          'front_appearance_required' => face['front_appearance_required'] != false,
          'back_appearance_required' => face['back_appearance_required'] == true,
          'front_uv_loop_lengths' => front_uv_loops.map(&:length),
          'back_uv_loop_lengths' => back_uv_loops.map(&:length)
        }
      end

      Array(mesh['edges']).each do |edge|
        vertices = Array(edge.fetch('vertices')).map { |value| Integer(value) }
        raise ArgumentError, "Edge #{edge['id']} must have exactly two vertex indices" unless vertices.length == 2
        edge_vertices.concat(vertices)
        edge_metadata << EvolutionDocument.deep_copy(edge.reject { |key, _| key == 'vertices' })
      end

      {
        'id' => mesh['id'],
        'definition_id' => mesh['definition_id'],
        'source_mesh_index' => index,
        'face_metadata' => face_meta,
        'edge_metadata' => edge_metadata,
        'binary' => {
          'positions' => section(writer, "#{prefix}_positions", positions, 'float64', 3),
          'outer_indices' => section(writer, "#{prefix}_outer_indices", outer, 'uint32', 1),
          'outer_offsets' => section(writer, "#{prefix}_outer_offsets", outer_offsets, 'uint32', 1),
          'hole_indices' => section(writer, "#{prefix}_hole_indices", holes, 'uint32', 1),
          'hole_offsets' => section(writer, "#{prefix}_hole_offsets", hole_offsets, 'uint32', 1),
          'face_hole_offsets' => section(writer, "#{prefix}_face_hole_offsets", face_hole_offsets, 'uint32', 1),
          'triangles' => section(writer, "#{prefix}_triangles", triangles, 'uint32', 3),
          'triangle_offsets' => section(writer, "#{prefix}_triangle_offsets", triangle_offsets, 'uint32', 1),
          'normals' => section(writer, "#{prefix}_normals", normals, 'float64', 3),
          'areas' => section(writer, "#{prefix}_areas", areas, 'float64', 1),
          'front_material_indices' => section(writer, "#{prefix}_front_materials", front_materials, 'uint32', 1),
          'back_material_indices' => section(writer, "#{prefix}_back_materials", back_materials, 'uint32', 1),
          'front_uv_values' => section(writer, "#{prefix}_front_uv_values", front_uv_values, 'float64', 2),
          'front_uv_offsets' => section(writer, "#{prefix}_front_uv_offsets", front_uv_offsets, 'uint32', 1),
          'back_uv_values' => section(writer, "#{prefix}_back_uv_values", back_uv_values, 'float64', 2),
          'back_uv_offsets' => section(writer, "#{prefix}_back_uv_offsets", back_uv_offsets, 'uint32', 1),
          'edge_vertices' => section(writer, "#{prefix}_edge_vertices", edge_vertices, 'uint32', 2)
        }
      }
    end
    private_class_method :encode_mesh

    def encode_instances(writer, graph, definition_index, material_index)
      nodes = Array(graph['nodes'])
      node_index = nodes.each_with_index.to_h { |node, index| [node['id'], index] }
      transforms = []
      definitions = []
      materials = []
      parents = []
      metadata = []
      nodes.each do |node|
        matrix = Array(graph.fetch('transforms').fetch(Integer(node['transform_id'] || 0)))
        raise ArgumentError, "Instance #{node['id']} transform must be full 4x4" unless matrix.length == 16 && matrix.all? { |value| value.is_a?(Numeric) && value.finite? }
        transforms.concat(matrix.map(&:to_f))
        definitions << (node['definition_id'] ? definition_index.fetch(node['definition_id']) : UINT32_NONE)
        materials << material_ref(material_index, node['material_override_id'])
        parent = parent_node_id(node['id'])
        parents << (parent && node_index.key?(parent) ? node_index.fetch(parent) : UINT32_NONE)
        metadata << EvolutionDocument.deep_copy(node.reject { |key, _| %w[transform_id definition_id material_override_id].include?(key) })
      end
      {
        'metadata' => metadata,
        'count' => nodes.length,
        'transforms' => section(writer, 'instance_transforms', transforms, 'float64', 16),
        'definition_indices' => section(writer, 'instance_definition_indices', definitions, 'uint32', 1),
        'material_indices' => section(writer, 'instance_material_indices', materials, 'uint32', 1),
        'parent_indices' => section(writer, 'instance_parent_indices', parents, 'uint32', 1)
      }
    end
    private_class_method :encode_instances

    def section(writer, name, values, type, components)
      writer.add(name, values, component_type: type, components: components)
      { 'section' => name, 'component_type' => type, 'components' => components }
    end
    private_class_method :section

    def material_ref(index, id)
      id.nil? ? UINT32_NONE : index.fetch(id)
    end
    private_class_method :material_ref

    def append_uv(values, offsets, outer, holes)
      loops = []
      loops << outer if outer.is_a?(Array)
      loops.concat(Array(holes))
      if loops.empty?
        offsets << UINT32_NONE
        return
      end
      offsets << values.length / 2
      loops.flatten(1).each do |pair|
        values << Float(pair.fetch(0)) << Float(pair.fetch(1))
      end
    end
    private_class_method :append_uv

    def clean_materials(materials)
      Array(materials).map do |material|
        result = EvolutionDocument.deep_copy(material)
        texture = result['texture']
        if texture && texture['asset_id']
          result['texture'] = texture.reject { |key, _| key == 'data_base64' }.merge('asset' => texture['asset_id'])
        end
        result
      end
    end
    private_class_method :clean_materials

    def parent_node_id(id)
      text = id.to_s
      return nil unless text.include?('/')
      text.split('/')[0...-1].join('/')
    end
    private_class_method :parent_node_id

    def replace_section_names!(value, indices)
      case value
      when Hash
        value.each do |key, child|
          if key == 'section' && child.is_a?(String)
            value[key] = indices.fetch(child)
          else
            replace_section_names!(child, indices)
          end
        end
      when Array
        value.each { |child| replace_section_names!(child, indices) }
      end
    end
    private_class_method :replace_section_names!
  end
end
