# frozen_string_literal: true

require_relative 'section_writer'
require_relative 'position_codec'

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    module Binary
      class DocumentEncoder
        FORMAT_IDENTIFIER = 'bom_engine_clean_package'.freeze
        FORMAT_VERSION = '1.0.0'.freeze
        LOGICAL_FORMAT_IDENTIFIER = 'bom_engine_clean_v1'.freeze
        POSITION_TOLERANCE_M = 1.0e-6
        UINT16_NONE = 65_535
        UINT32_NONE = 4_294_967_295
        AFFINE_INDICES = [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14].freeze

        class << self
          def encode(document)
            new(document).encode
          end
        end

        def initialize(document)
          unless document.is_a?(Hash) && document.dig('format', 'identifier') == LOGICAL_FORMAT_IDENTIFIER
            raise ArgumentError, 'binary package encoder requires a CleanV1 document'
          end

          @document = document
          @writer = SectionWriter.new
          @materials = document.fetch('materials').each_with_index.each_with_object({}) do |(item, index), result|
            result[item.fetch('id')] = index
          end
          @definitions = document.fetch('definitions').each_with_index.each_with_object({}) do |(item, index), result|
            result[item.fetch('id')] = index
          end
          @position_statistics = []
        end

        def encode
          root_metadata, root_binary = encode_surface_table(
            'root', @document.fetch('surfaces'), coordinate_loops: true,
            uv_pool: @document.fetch('uvs', []), compact_polygon_type: false
          )
          definitions = encode_definitions
          instances, instance_binary = encode_instances
          fallback_metadata, fallback_binary = encode_surface_table(
            'fallback', @document.fetch('fallback_geometry'), coordinate_loops: true,
            uv_pool: [], compact_polygon_type: false
          )
          encode_fallback_definition_indices!(fallback_metadata, fallback_binary)
          visual_edges, visual_edge_binary = encode_visual_edges
          sections = @writer.sections
          buffers = @writer.bytes
          section_indices = sections.keys.each_with_index.each_with_object({}) { |(name, index), result| result[name] = index }
          manifest = {
            'format' => {
              'identifier' => FORMAT_IDENTIFIER,
              'version' => FORMAT_VERSION,
              'logical_identifier' => @document.dig('format', 'identifier'),
              'logical_version' => @document.dig('format', 'version')
            },
            'units' => @document.fetch('units'),
            'coordinate_system' => deep_copy(@document.fetch('coordinate_system')),
            'model' => deep_copy(@document.fetch('model')),
            'materials' => deep_copy(@document.fetch('materials')),
            'surfaces' => root_metadata,
            'definitions' => definitions,
            'instances' => instances,
            'components' => deep_copy(@document.fetch('components', [])),
            'visual_edges' => visual_edges,
            'excluded_objects' => deep_copy(@document.fetch('excluded_objects', [])),
            'fallback_geometry' => fallback_metadata,
            'diagnostics' => deep_copy(@document.fetch('diagnostics')),
            'binary_tables' => {
              'root_surfaces' => root_binary,
              'instances' => instance_binary,
              'visual_edges' => visual_edge_binary,
              'fallback_geometry' => fallback_binary
            },
            'buffers' => {
              'uri' => 'buffers.bin',
              'byte_length' => buffers.bytesize,
              'padding_bytes' => @writer.padding_bytes,
              'endianness' => 'little',
              'section_descriptor_fields' => %w[byte_offset byte_length count component_count component_type],
              'sections' => compact_sections(sections)
            },
            'encoding' => {
              'position_tolerance_m' => POSITION_TOLERANCE_M,
              'uv_component_type' => 'float32',
              'transform_layout' => 'column_major_affine_3x4',
              'transform_component_type' => 'float64'
            }
          }
          replace_section_references!(manifest, section_indices)
          {
            manifest: manifest.freeze,
            buffers: buffers.freeze,
            statistics: {
              definition_geometry_count: definitions.length,
              section_count: sections.length,
              buffer_bytes: buffers.bytesize,
              padding_bytes: @writer.padding_bytes,
              section_names: sections.keys.freeze,
              section_descriptors: sections.freeze,
              position_codecs: @position_statistics.freeze
            }.freeze
          }.freeze
        end

        private

        def compact_sections(sections)
          sections.map do |_name, descriptor|
            [descriptor.fetch('byte_offset'), descriptor.fetch('byte_length'),
             descriptor.fetch('count'), descriptor.fetch('component_count'), descriptor.fetch('component_type')]
          end
        end

        def replace_section_references!(value, indices)
          case value
          when Hash
            value.each do |key, child|
              if key == 'section'
                value[key] = indices.fetch(child)
              else
                replace_section_references!(child, indices)
              end
            end
          when Array
            value.each { |child| replace_section_references!(child, indices) }
          end
        end

        def encode_definitions
          @document.fetch('definitions').each_with_index.map do |definition, index|
            geometry = definition.fetch('geometry')
            metadata, binary = encode_surface_table(
              format('definition_%06d', index), geometry.fetch('surfaces'),
              coordinate_loops: false, positions: geometry.fetch('vertices'),
              uv_pool: geometry.fetch('uvs', []), edges: geometry.fetch('edges', []),
              compact_polygon_type: true
            )
            result = deep_copy(definition)
            encoded_geometry = result.fetch('geometry')
            %w[vertices surfaces edges uvs].each { |key| encoded_geometry.delete(key) }
            encoded_geometry['surface_metadata'] = metadata
            encoded_geometry['binary'] = binary
            result
          end
        end

        def encode_surface_table(prefix, surfaces, coordinate_loops:, uv_pool:, compact_polygon_type:,
                                 positions: nil, edges: [])
          position_pool, indexed_loops = indexed_surface_loops(surfaces, coordinate_loops, positions)
          position_info = add_position_section("#{prefix}_positions", position_pool)
          loop_indices = []
          loop_offsets = [0]
          polygon_loop_offsets = [0]
          front_uv_offsets = []
          back_uv_offsets = []
          front_uv_indices = []
          back_uv_indices = []
          front_materials = []
          back_materials = []
          inherited_materials = []
          surface_flags = []
          normals = []
          areas = []
          metadata = []

          surfaces.each_with_index do |surface, surface_index|
            loops = indexed_loops.fetch(surface_index)
            loops.each do |loop|
              loop_indices.concat(loop)
              loop_offsets << loop_indices.length
            end
            polygon_loop_offsets << polygon_loop_offsets.last + loops.length
            encode_uv_side(surface['front_uv'], front_uv_offsets, front_uv_indices)
            encode_uv_side(surface['back_uv'], back_uv_offsets, back_uv_indices)
            front_materials << material_index(surface['front_material_id'])
            back_materials << material_index(surface['back_material_id'])
            inherited_materials << material_index(surface['inherited_material_id'])
            surface_flags << surface_presence_flags(surface)
            normals.concat(surface.fetch('normal', [Float::NAN, Float::NAN, Float::NAN]))
            areas << surface.fetch('area_m2', Float::NAN)
            metadata << compact_surface_metadata(surface, compact_polygon_type)
          end

          topology_type = index_type(loop_indices)
          uv_index_values = front_uv_indices + back_uv_indices
          uv_index_type = index_type(uv_index_values)
          binary = {
            'surface_count' => surfaces.length,
            'positions' => position_info,
            'loop_vertex_indices' => add_values("#{prefix}_loop_vertex_indices", loop_indices, topology_type),
            'loop_offsets' => add_values("#{prefix}_loop_offsets", loop_offsets, 'uint32'),
            'polygon_loop_offsets' => add_values("#{prefix}_polygon_loop_offsets", polygon_loop_offsets, 'uint32'),
            'front_material_indices' => add_values("#{prefix}_front_material_indices", front_materials, 'uint16'),
            'back_material_indices' => add_values("#{prefix}_back_material_indices", back_materials, 'uint16'),
            'inherited_material_indices' => add_values("#{prefix}_inherited_material_indices", inherited_materials, 'uint16'),
            'surface_flags' => add_values("#{prefix}_surface_flags", surface_flags, 'uint16'),
            'normals' => add_values("#{prefix}_normals", normals, 'float32', 3),
            'areas' => add_values("#{prefix}_areas", areas, 'float64'),
            'uvs' => add_uv_section("#{prefix}_uvs", uv_pool),
            'front_uv_offsets' => add_values("#{prefix}_front_uv_offsets", front_uv_offsets, 'uint32'),
            'front_uv_indices' => add_values("#{prefix}_front_uv_indices", front_uv_indices, uv_index_type),
            'back_uv_offsets' => add_values("#{prefix}_back_uv_offsets", back_uv_offsets, 'uint32'),
            'back_uv_indices' => add_values("#{prefix}_back_uv_indices", back_uv_indices, uv_index_type),
            'default_surface_type' => compact_polygon_type ? 'polygon' : nil
          }
          binary['edges'] = encode_edges(prefix, edges, topology_type) unless edges.empty?
          [metadata, binary]
        end

        def indexed_surface_loops(surfaces, coordinate_loops, supplied_positions)
          return [supplied_positions, surfaces.map { |surface| [surface.fetch('outer')] + surface.fetch('holes') }] unless coordinate_loops

          pool = []
          indices = {}
          loops = surfaces.map do |surface|
            ([surface.fetch('outer')] + surface.fetch('holes')).map do |loop|
              loop.map do |point|
                key = point.map(&:to_f).freeze
                indices[key] ||= begin
                  pool << key
                  pool.length - 1
                end
              end
            end
          end
          [pool, loops]
        end

        def add_position_section(name, points)
          encoded = PositionCodec.encode(points, tolerance: POSITION_TOLERANCE_M)
          @writer.add(name, encoded.fetch(:values), component_type: encoded.fetch(:component_type), components: 3,
                      count: encoded.fetch(:count))
          @position_statistics << {
            name: name, component_type: encoded.fetch(:component_type), count: encoded.fetch(:count),
            metrics: encoded.fetch(:metrics), benchmark: encoded.fetch(:benchmark)
          }.freeze
          {
            'section' => name,
            'origin' => encoded.fetch(:origin),
            'scale' => encoded.fetch(:scale),
            'component_type' => encoded.fetch(:component_type)
          }
        end

        def add_uv_section(name, uv_pool)
          flattened = uv_pool.flatten.map(&:to_f)
          values = flattened.pack('e*').unpack('e*')
          @writer.add(name, values, component_type: 'float32', components: 2, count: uv_pool.length)
          errors = flattened.zip(values).map { |left, right| (left - right).abs }
          {
            'section' => name,
            'max_error' => errors.empty? ? 0.0 : errors.max,
            'component_type' => 'float32'
          }
        end

        def encode_uv_side(mapping, offsets, indices)
          if mapping.nil?
            offsets << UINT32_NONE
          else
            offsets << indices.length
            indices.concat(mapping.fetch('outer'))
            mapping.fetch('holes').each { |loop| indices.concat(loop) }
          end
        end

        def encode_edges(prefix, edges, index_component_type)
          add_values("#{prefix}_edges", edges.flatten, index_component_type, 2)
        end

        def compact_surface_metadata(surface, compact_polygon_type)
          result = deep_copy(surface)
          %w[outer holes normal area_m2 front_material_id back_material_id inherited_material_id front_uv back_uv].each do |key|
            result.delete(key)
          end
          result.delete('type') if compact_polygon_type && result['type'] == 'polygon'
          result
        end

        def surface_presence_flags(surface)
          %w[normal area_m2 front_material_id back_material_id inherited_material_id front_uv back_uv].each_with_index.inject(0) do |flags, (key, bit)|
            surface.key?(key) ? flags | (1 << bit) : flags
          end
        end

        def encode_instances
          ids = @document.fetch('instances').each_with_index.each_with_object({}) do |(item, index), result|
            result[item.fetch('id')] = index
          end
          metadata = []
          transforms = []
          definition_indices = []
          material_indices = []
          parent_indices = []
          @document.fetch('instances').each do |instance|
            matrix = instance.fetch('transform')
            validate_affine_transform!(matrix)
            transforms.concat(AFFINE_INDICES.map { |index| matrix.fetch(index) })
            definition_indices << @definitions.fetch(instance.fetch('definition_id'))
            material_indices << material_index(instance['material_id'])
            parent_indices << (instance['parent_instance_id'] ? ids.fetch(instance.fetch('parent_instance_id')) : UINT32_NONE)
            item = deep_copy(instance)
            %w[transform definition_id material_id parent_instance_id].each { |key| item.delete(key) }
            metadata << item
          end
          definition_type = index_type(definition_indices)
          binary = {
            'count' => metadata.length,
            'transforms' => add_values('instance_transforms', transforms, 'float64', 12),
            'definition_indices' => add_values('instance_definition_indices', definition_indices, definition_type),
            'material_indices' => add_values('instance_material_indices', material_indices, 'uint16'),
            'parent_indices' => add_values('instance_parent_indices', parent_indices, 'uint32')
          }
          [metadata, binary]
        end

        def validate_affine_transform!(matrix)
          unless matrix.length == 16 && [matrix[3], matrix[7], matrix[11]].all? { |value| value.to_f.zero? } &&
                 matrix[15].to_f == 1.0
            raise ArgumentError, 'Clean package only supports affine 4x4 instance transforms'
          end
        end

        def encode_visual_edges
          edges = @document.fetch('visual_edges', [])
          points = edges.flat_map { |edge| edge.fetch('vertices') }
          metadata = edges.map do |edge|
            item = deep_copy(edge)
            item.delete('vertices')
            item
          end
          [metadata, { 'count' => edges.length, 'positions' => add_position_section('visual_edge_positions', points) }]
        end

        def encode_fallback_definition_indices!(metadata, binary)
          values = @document.fetch('fallback_geometry').map do |item|
            item['definition_id'] ? @definitions.fetch(item.fetch('definition_id')) : UINT16_NONE
          end
          metadata.each { |item| item.delete('definition_id') }
          binary['definition_indices'] = add_values('fallback_definition_indices', values, 'uint16')
        end

        def material_index(id)
          id.nil? ? UINT16_NONE : @materials.fetch(id)
        end

        def index_type(values)
          maximum = values.reject { |value| value == UINT32_NONE }.max.to_i
          maximum <= UINT16_NONE ? 'uint16' : 'uint32'
        end

        def add_values(name, values, component_type, components = 1)
          @writer.add(name, values, component_type: component_type, components: components)
          { 'section' => name, 'component_type' => component_type }
        end

        def deep_copy(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, child), result| result[key] = deep_copy(child) }
          when Array
            value.map { |child| deep_copy(child) }
          else
            value
          end
        end
      end
    end
  end
end

end # SibamboHistory
