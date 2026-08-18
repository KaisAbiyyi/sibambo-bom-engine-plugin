# frozen_string_literal: true

require 'json'
require_relative 'document_encoder'
require_relative 'position_codec'

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    module Binary
      class ReferenceDecoder
        UINT16_NONE = 65_535
        UINT32_NONE = 4_294_967_295
        AFFINE_INDICES = [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14].freeze
        UNPACK_DIRECTIVES = {
          'float32' => 'e*', 'float64' => 'E*', 'uint16' => 'S<*',
          'uint32' => 'L<*', 'int32' => 'l<*'
        }.freeze

        class << self
          def decode(manifest, buffers)
            new(manifest, buffers).decode
          end
        end

        def initialize(manifest, buffers)
          @manifest = manifest.is_a?(String) ? JSON.parse(manifest) : deep_copy(manifest)
          unless @manifest.dig('format', 'identifier') == DocumentEncoder::FORMAT_IDENTIFIER
            raise ArgumentError, 'reference decoder requires a Clean binary package manifest'
          end

          @buffers = String(buffers).b
          fields = @manifest.dig('buffers', 'section_descriptor_fields') || []
          @sections = (@manifest.dig('buffers', 'sections') || []).map do |values|
            fields.zip(values).each_with_object({}) { |(key, value), item| item[key] = value }
          end
          @material_ids = @manifest.fetch('materials').map { |item| item.fetch('id') }
          @definition_ids = @manifest.fetch('definitions').map { |item| item.fetch('id') }
        end

        def decode
          root = decode_surface_table(
            @manifest.fetch('surfaces'), @manifest.dig('binary_tables', 'root_surfaces'), coordinate_loops: true
          )
          definitions = decode_definitions
          instances = decode_instances
          visual_edges = decode_visual_edges
          fallback = decode_surface_table(
            @manifest.fetch('fallback_geometry'), @manifest.dig('binary_tables', 'fallback_geometry'), coordinate_loops: true
          )
          restore_fallback_definition_ids!(fallback)
          {
            'format' => {
              'identifier' => @manifest.dig('format', 'logical_identifier'),
              'version' => @manifest.dig('format', 'logical_version')
            },
            'units' => @manifest.fetch('units'),
            'coordinate_system' => deep_copy(@manifest.fetch('coordinate_system')),
            'model' => deep_copy(@manifest.fetch('model')),
            'materials' => deep_copy(@manifest.fetch('materials')),
            'uvs' => decode_uv_pool(@manifest.dig('binary_tables', 'root_surfaces', 'uvs')),
            'surfaces' => root,
            'definitions' => definitions,
            'instances' => instances,
            'components' => deep_copy(@manifest.fetch('components', [])),
            'visual_edges' => visual_edges,
            'excluded_objects' => deep_copy(@manifest.fetch('excluded_objects', [])),
            'fallback_geometry' => fallback,
            'diagnostics' => deep_copy(@manifest.fetch('diagnostics'))
          }
        end

        private

        def decode_definitions
          @manifest.fetch('definitions').map do |definition|
            item = deep_copy(definition)
            geometry = item.fetch('geometry')
            metadata = geometry.delete('surface_metadata')
            binary = geometry.delete('binary')
            positions = decode_positions(binary.fetch('positions'))
            geometry['vertices'] = positions
            geometry['surfaces'] = decode_surface_table(metadata, binary, coordinate_loops: false, positions: positions)
            geometry['edges'] = binary['edges'] ? section_values(binary.dig('edges', 'section')).each_slice(2).map(&:dup) : []
            geometry['uvs'] = decode_uv_pool(binary.fetch('uvs'))
            item
          end
        end

        def decode_surface_table(metadata, binary, coordinate_loops:, positions: nil)
          positions ||= decode_positions(binary.fetch('positions'))
          loop_indices = section_values(binary.dig('loop_vertex_indices', 'section'))
          loop_offsets = section_values(binary.dig('loop_offsets', 'section'))
          polygon_offsets = section_values(binary.dig('polygon_loop_offsets', 'section'))
          loops = loop_offsets.each_cons(2).map { |left, right| loop_indices.slice(left, right - left) }
          front_materials = section_values(binary.dig('front_material_indices', 'section'))
          back_materials = section_values(binary.dig('back_material_indices', 'section'))
          inherited_materials = section_values(binary.dig('inherited_material_indices', 'section'))
          flags = section_values(binary.dig('surface_flags', 'section'))
          normals = section_values(binary.dig('normals', 'section')).each_slice(3).map(&:dup)
          areas = section_values(binary.dig('areas', 'section'))
          front_uv_offsets = section_values(binary.dig('front_uv_offsets', 'section'))
          front_uv_indices = section_values(binary.dig('front_uv_indices', 'section'))
          back_uv_offsets = section_values(binary.dig('back_uv_offsets', 'section'))
          back_uv_indices = section_values(binary.dig('back_uv_indices', 'section'))

          metadata.each_with_index.map do |surface, index|
            item = deep_copy(surface)
            selected = loops.slice(polygon_offsets.fetch(index), polygon_offsets.fetch(index + 1) - polygon_offsets.fetch(index))
            decoded_loops = coordinate_loops ? selected.map { |loop| loop.map { |vertex| positions.fetch(vertex).dup } } : selected.map(&:dup)
            item['type'] = binary['default_surface_type'] if !item.key?('type') && binary['default_surface_type']
            item['outer'] = decoded_loops.fetch(0)
            item['holes'] = decoded_loops.drop(1)
            mask = flags.fetch(index)
            item['normal'] = normals.fetch(index) if present?(mask, 0)
            item['area_m2'] = areas.fetch(index) if present?(mask, 1)
            restore_material!(item, 'front_material_id', front_materials.fetch(index), mask, 2)
            restore_material!(item, 'back_material_id', back_materials.fetch(index), mask, 3)
            restore_material!(item, 'inherited_material_id', inherited_materials.fetch(index), mask, 4)
            restore_uv!(item, 'front_uv', front_uv_offsets.fetch(index), front_uv_indices, decoded_loops, mask, 5)
            restore_uv!(item, 'back_uv', back_uv_offsets.fetch(index), back_uv_indices, decoded_loops, mask, 6)
            item
          end
        end

        def restore_material!(item, key, index, mask, bit)
          return unless present?(mask, bit)

          item[key] = index == UINT16_NONE ? nil : @material_ids.fetch(index)
        end

        def restore_uv!(item, key, offset, indices, loops, mask, bit)
          return unless present?(mask, bit)

          lengths = loops.map(&:length)
          cursor = offset
          mapped = lengths.map do |length|
            value = indices.slice(cursor, length)
            cursor += length
            value
          end
          item[key] = { 'outer' => mapped.fetch(0), 'holes' => mapped.drop(1) }
        end

        def decode_instances
          binary = @manifest.dig('binary_tables', 'instances')
          transforms = section_values(binary.dig('transforms', 'section')).each_slice(12).map(&:dup)
          definitions = section_values(binary.dig('definition_indices', 'section'))
          materials = section_values(binary.dig('material_indices', 'section'))
          parents = section_values(binary.dig('parent_indices', 'section'))
          ids = @manifest.fetch('instances').map { |item| item.fetch('id') }
          @manifest.fetch('instances').each_with_index.map do |instance, index|
            item = deep_copy(instance)
            item['definition_id'] = @definition_ids.fetch(definitions.fetch(index))
            item['transform'] = expand_affine(transforms.fetch(index))
            item['material_id'] = @material_ids.fetch(materials.fetch(index)) unless materials.fetch(index) == UINT16_NONE
            item['parent_instance_id'] = ids.fetch(parents.fetch(index)) unless parents.fetch(index) == UINT32_NONE
            item
          end
        end

        def expand_affine(values)
          matrix = Array.new(16, 0.0)
          AFFINE_INDICES.each_with_index { |matrix_index, value_index| matrix[matrix_index] = values.fetch(value_index) }
          matrix[15] = 1.0
          matrix
        end

        def decode_visual_edges
          binary = @manifest.dig('binary_tables', 'visual_edges')
          positions = decode_positions(binary.fetch('positions'))
          @manifest.fetch('visual_edges').each_with_index.map do |edge, index|
            item = deep_copy(edge)
            item['vertices'] = positions.slice(index * 2, 2)
            item
          end
        end

        def restore_fallback_definition_ids!(surfaces)
          binary = @manifest.dig('binary_tables', 'fallback_geometry')
          indices = section_values(binary.dig('definition_indices', 'section'))
          surfaces.each_with_index do |surface, index|
            value = indices.fetch(index)
            surface['definition_id'] = @definition_ids.fetch(value) unless value == UINT16_NONE
          end
        end

        def decode_positions(info)
          PositionCodec.decode(
            component_type: info.fetch('component_type'),
            values: section_values(info.fetch('section')),
            origin: info['origin'], scale: info['scale']
          )
        end

        def decode_uv_pool(info)
          section_values(info.fetch('section')).each_slice(2).map(&:dup)
        end

        def section_values(section_index)
          descriptor = @sections.fetch(section_index)
          payload = @buffers.byteslice(descriptor.fetch('byte_offset'), descriptor.fetch('byte_length'))
          payload.unpack(UNPACK_DIRECTIVES.fetch(descriptor.fetch('component_type')))
        end

        def present?(flags, bit)
          (flags & (1 << bit)) != 0
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
