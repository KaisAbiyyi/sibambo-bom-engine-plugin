# frozen_string_literal: true

require 'json'
require 'tempfile'
require_relative 'evolution_document'
require_relative 'evolution_cleanpkg/section_writer'
require_relative 'evolution_cleanpkg/deterministic_zip'
require_relative 'performance_trace'

module BOMEngine
  module EvolutionCleanPKGWriter
    UINT32_NONE = 0xffff_ffff
    module_function

    def build(document)
      PerformanceTrace.stage(:e3_binary_build) do
        EvolutionDocument.validate!(document)
        writer = EvolutionCleanPKG::SectionWriter.new
        manifest = build_manifest(document, writer)
        { manifest: manifest, buffers: writer.bytes }
      end
    end

    def write(path, document)
      EvolutionDocument.validate!(document)
      buffer_file = Tempfile.new(['evolution-cleanpkg-', '.bin'])
      buffer_file.binmode
      result = nil
      PerformanceTrace.stage(:e3_binary_build) do
        writer = EvolutionCleanPKG::SectionWriter.new(io: buffer_file)
        manifest = build_manifest(document, writer)
        buffer_file.flush
        entries = {
          'manifest.json' => JSON.generate(manifest),
          'buffers.bin' => EvolutionCleanPKG::DeterministicZip.file_source(buffer_file.path)
        }
        Array(document.fetch('assets')).each { |asset| entries[asset.fetch('path')] = asset.fetch('bytes') }
        result = PerformanceTrace.stage(:e3_zip_write) { EvolutionCleanPKG::DeterministicZip.write(path, entries) }
      end
      result
    ensure
      buffer_file&.close!
    end

    def build_manifest(document, writer)
      graph = document.fetch('graph')
      material_index = {}
      Array(graph['materials']).each_with_index { |material, index| material_index[material['id']] = index }
      definition_index = {}
      Array(graph['definitions']).each_with_index { |definition, index| definition_index[definition['id']] = index }
      mesh_index = {}
      Array(graph['meshes']).each_with_index { |mesh, index| mesh_index[mesh['id']] = index }

      mesh_rows = Array(graph['meshes']).each_with_index.map do |mesh, index|
        encode_mesh(writer, mesh, index, material_index)
      end
      instances = encode_instances(writer, graph, definition_index, material_index)
      raw_sections = writer.sections
      section_index = {}
      raw_sections.keys.each_with_index { |name, index| section_index[name] = index }
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
          'byte_length' => writer.bytesize,
          'padding_bytes' => writer.padding_bytes,
          'endianness' => 'little',
          'section_descriptor_fields' => %w[byte_offset byte_length count component_count component_type],
          'sections' => raw_sections.values.map do |descriptor|
            [descriptor['byte_offset'], descriptor['byte_length'], descriptor['count'], descriptor['component_count'], descriptor['component_type']]
          end
        }
      }
      replace_section_names!(manifest, section_index)
      manifest
    end
    private_class_method :build_manifest

    def encode_mesh(writer, mesh, index, material_index)
      prefix = format('mesh_%06d', index)
      positions = Array(mesh.fetch('positions_m'))
      faces = Array(mesh['faces'])
      edges = Array(mesh['edges'])
      triangle_offsets = [0]
      outer_offsets = [0]
      hole_offsets = [0]
      face_hole_offsets = [0]
      face_meta = []
      front_uv_offsets = [0]
      back_uv_offsets = [0]
      edge_metadata = []
      outer_count = 0
      hole_count = 0
      triangle_count = 0
      front_uv_pair_count = 0
      back_uv_pair_count = 0

      faces.each_with_index do |face, face_index|
        outer_count += Array(face['outer']).length
        outer_offsets << outer_count
        Array(face['holes']).each do |loop|
          hole_count += Array(loop).length
          hole_offsets << hole_count
        end
        face_hole_offsets << hole_offsets.length - 1
        triangle_count += Array(face['triangles']).length
        triangle_offsets << triangle_count
        uv = face['uv'] || {}
        front_uv_loops = [uv['front_outer'], *Array(uv['front_holes'])].select { |loop| loop.is_a?(Array) }
        back_uv_loops = [uv['back_outer'], *Array(uv['back_holes'])].select { |loop| loop.is_a?(Array) }
        if front_uv_loops.empty?
          front_uv_offsets << UINT32_NONE
        else
          front_uv_offsets << front_uv_pair_count
          front_uv_pair_count += front_uv_loops.sum(&:length)
        end
        if back_uv_loops.empty?
          back_uv_offsets << UINT32_NONE
        else
          back_uv_offsets << back_uv_pair_count
          back_uv_pair_count += back_uv_loops.sum(&:length)
        end
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

      edges.each do |edge|
        vertices = Array(edge.fetch('vertices')).map { |value| Integer(value) }
        raise ArgumentError, "Edge #{edge['id']} must have exactly two vertex indices" unless vertices.length == 2
        edge_metadata << EvolutionDocument.deep_copy(edge.reject { |key, _| key == 'vertices' })
      end

      outer_values = Enumerator.new do |out|
        faces.each { |face| Array(face['outer']).each { |value| out << Integer(value) } }
      end
      hole_values = Enumerator.new do |out|
        faces.each { |face| Array(face['holes']).each { |loop| Array(loop).each { |value| out << Integer(value) } } }
      end
      triangle_values = Enumerator.new do |out|
        faces.each { |face| Array(face['triangles']).each { |value| out << Integer(value) } }
      end
      normal_values = Enumerator.new do |out|
        faces.each { |face| Array(face['normal'] || [0.0, 0.0, 1.0]).each { |value| out << Float(value) } }
      end
      area_values = Enumerator.new { |out| faces.each { |face| out << Float(face['area_m2'] || 0.0) } }
      front_material_values = Enumerator.new { |out| faces.each { |face| out << material_ref(material_index, face['front_material_id']) } }
      back_material_values = Enumerator.new { |out| faces.each { |face| out << material_ref(material_index, face['back_material_id']) } }
      front_uv_values = uv_value_enumerator(faces, 'front_outer', 'front_holes')
      back_uv_values = uv_value_enumerator(faces, 'back_outer', 'back_holes')
      edge_values = Enumerator.new do |out|
        edges.each { |edge| Array(edge.fetch('vertices')).each { |value| out << Integer(value) } }
      end

      {
        'id' => mesh['id'],
        'definition_id' => mesh['definition_id'],
        'source_mesh_index' => index,
        'face_metadata' => face_meta,
        'edge_metadata' => edge_metadata,
        'binary' => {
          'positions' => section(writer, "#{prefix}_positions", positions, 'float64', 3, count: positions.length / 3),
          'outer_indices' => section(writer, "#{prefix}_outer_indices", outer_values, 'uint32', 1, count: outer_count),
          'outer_offsets' => section(writer, "#{prefix}_outer_offsets", outer_offsets, 'uint32', 1),
          'hole_indices' => section(writer, "#{prefix}_hole_indices", hole_values, 'uint32', 1, count: hole_count),
          'hole_offsets' => section(writer, "#{prefix}_hole_offsets", hole_offsets, 'uint32', 1),
          'face_hole_offsets' => section(writer, "#{prefix}_face_hole_offsets", face_hole_offsets, 'uint32', 1),
          'triangles' => section(writer, "#{prefix}_triangles", triangle_values, 'uint32', 3, count: triangle_count / 3),
          'triangle_offsets' => section(writer, "#{prefix}_triangle_offsets", triangle_offsets, 'uint32', 1),
          'normals' => section(writer, "#{prefix}_normals", normal_values, 'float64', 3, count: faces.length),
          'areas' => section(writer, "#{prefix}_areas", area_values, 'float64', 1, count: faces.length),
          'front_material_indices' => section(writer, "#{prefix}_front_materials", front_material_values, 'uint32', 1, count: faces.length),
          'back_material_indices' => section(writer, "#{prefix}_back_materials", back_material_values, 'uint32', 1, count: faces.length),
          'front_uv_values' => section(writer, "#{prefix}_front_uv_values", front_uv_values, 'float64', 2, count: front_uv_pair_count),
          'front_uv_offsets' => section(writer, "#{prefix}_front_uv_offsets", front_uv_offsets, 'uint32', 1),
          'back_uv_values' => section(writer, "#{prefix}_back_uv_values", back_uv_values, 'float64', 2, count: back_uv_pair_count),
          'back_uv_offsets' => section(writer, "#{prefix}_back_uv_offsets", back_uv_offsets, 'uint32', 1),
          'edge_vertices' => section(writer, "#{prefix}_edge_vertices", edge_values, 'uint32', 2, count: edges.length)
        }
      }
    end
    private_class_method :encode_mesh

    def encode_instances(writer, graph, definition_index, material_index)
      nodes = Array(graph['nodes'])
      node_index = {}
      nodes.each_with_index { |node, index| node_index[node['id']] = index }
      metadata = []
      nodes.each do |node|
        matrix = Array(graph.fetch('transforms').fetch(Integer(node['transform_id'] || 0)))
        raise ArgumentError, "Instance #{node['id']} transform must be full 4x4" unless matrix.length == 16 && matrix.all? { |value| value.is_a?(Numeric) && value.finite? }
        metadata << EvolutionDocument.deep_copy(node.reject { |key, _| %w[transform_id definition_id material_override_id].include?(key) })
      end
      transforms = Enumerator.new do |out|
        nodes.each do |node|
          Array(graph.fetch('transforms').fetch(Integer(node['transform_id'] || 0))).each { |value| out << Float(value) }
        end
      end
      definitions = Enumerator.new do |out|
        nodes.each { |node| out << (node['definition_id'] ? definition_index.fetch(node['definition_id']) : UINT32_NONE) }
      end
      materials = Enumerator.new do |out|
        nodes.each { |node| out << material_ref(material_index, node['material_override_id']) }
      end
      parents = Enumerator.new do |out|
        nodes.each do |node|
          parent = parent_node_id(node['id'])
          out << (parent && node_index.key?(parent) ? node_index.fetch(parent) : UINT32_NONE)
        end
      end
      {
        'metadata' => metadata,
        'count' => nodes.length,
        'transforms' => section(writer, 'instance_transforms', transforms, 'float64', 16, count: nodes.length),
        'definition_indices' => section(writer, 'instance_definition_indices', definitions, 'uint32', 1, count: nodes.length),
        'material_indices' => section(writer, 'instance_material_indices', materials, 'uint32', 1, count: nodes.length),
        'parent_indices' => section(writer, 'instance_parent_indices', parents, 'uint32', 1, count: nodes.length)
      }
    end
    private_class_method :encode_instances

    def section(writer, name, values, type, components, count: nil)
      writer.add(name, values, component_type: type, components: components, count: count)
      { 'section' => name, 'component_type' => type, 'components' => components }
    end
    private_class_method :section

    def material_ref(index, id)
      id.nil? ? UINT32_NONE : index.fetch(id)
    end
    private_class_method :material_ref

    def uv_value_enumerator(faces, outer_key, holes_key)
      Enumerator.new do |out|
        faces.each do |face|
          uv = face['uv'] || {}
          loops = []
          loops << uv[outer_key] if uv[outer_key].is_a?(Array)
          loops.concat(Array(uv[holes_key]))
          loops.each do |loop|
            Array(loop).each do |pair|
              out << Float(pair.fetch(0)) << Float(pair.fetch(1))
            end
          end
        end
      end
    end
    private_class_method :uv_value_enumerator

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
