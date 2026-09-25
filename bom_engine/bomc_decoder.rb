# Standalone pure-Ruby BOMC 1.0/1.1/1.2 reference decoder.

require 'digest'
require_relative 'bomc_format'
require_relative 'bomc_jpeg_color_map'
require_relative 'decode_budget'
require_relative 'bomc_codecs'
require_relative 'bomc_encoding_contract'
require_relative 'scene_visibility_resolver'
require_relative 'scene_clip_program'

module BOMEngine
  module BOMCDecoder
    REQUIRED_SECTIONS = [
      BOMC::SECTION_MODEL, BOMC::SECTION_STRINGS, BOMC::SECTION_DEFINITIONS,
      BOMC::SECTION_INSTANCES, BOMC::SECTION_TRANSFORMS, BOMC::SECTION_COVERAGE
    ].freeze

    def self.read(path)
      decode(File.binread(path))
    end

    def self.decode(bytes, allow_jpeg_color_map: false)
      Decoder.new(bytes, allow_jpeg_color_map: allow_jpeg_color_map).decode
    end

    def self.profile(bytes)
      timings = {}
      total_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      container_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      decoder = Decoder.new(bytes)
      timings[:container_ms] = elapsed_ms(container_started)
      logical_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      model = decoder.decode(timings)
      timings[:logical_decode_ms] = elapsed_ms(logical_started)
      timings[:total_ms] = elapsed_ms(total_started)
      { model: model, timings: timings }
    end

    def self.elapsed_ms(started)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
    end

    class Decoder
      def initialize(bytes, allow_jpeg_color_map: false)
        @allow_jpeg_color_map = allow_jpeg_color_map == true
        @container = BOMC::Container.parse(bytes)
        @sections = {}
        @container[:sections].each do |section|
          raise "BOMC invalid: duplicate section type #{section[:type]}." if @sections.key?(section[:type])
          @sections[section[:type]] = section
        end
        missing = REQUIRED_SECTIONS.reject { |type| @sections.key?(type) }
        raise "BOMC invalid: missing sections #{missing.join(', ')}." unless missing.empty?
      end

      def decode(timings = nil)
        strings = model = materials = tags = definitions = instances = transforms = debug = nil
        measure(timings, :metadata_ms) do
          strings = decode_strings(section_bytes(BOMC::SECTION_STRINGS))
          model = decode_model(section_bytes(BOMC::SECTION_MODEL), strings)
          validate_counted_sections!(model[:counts])
          materials = optional_decode(BOMC::SECTION_MATERIALS, []) { |bytes| decode_materials(bytes, strings) }
          tags = optional_decode(BOMC::SECTION_TAGS, []) { |bytes| decode_tags(bytes, strings) }
          definitions = decode_definitions(section_bytes(BOMC::SECTION_DEFINITIONS), strings)
          instances = decode_instances(section_bytes(BOMC::SECTION_INSTANCES), strings)
          transforms = decode_codec_section(section_bytes(BOMC::SECTION_TRANSFORMS), BOMC::TransformCodec)
          definitions.each_with_index do |definition, definition_index|
            definition[:nodes] = []
            instances.each_with_index do |instance, instance_index|
              definition[:nodes] << instance_index if instance[:owner_definition] == definition_index
            end
          end
          debug = @sections[BOMC::SECTION_DEBUG] ? decode_debug(section_bytes(BOMC::SECTION_DEBUG), strings) : {}
        end

        mesh_rows = face_rows = normals = coverage = nil
        measure(timings, :analytical_ms) do
          mesh_rows = optional_decode(BOMC::SECTION_MESHES, []) { |bytes| decode_meshes(bytes) }
          face_rows = optional_decode(BOMC::SECTION_FACES, []) { |bytes| decode_faces(bytes, strings) }
          normals = optional_decode(BOMC::SECTION_NORMALS, []) { |bytes| decode_codec_section(bytes, BOMC::NormalCodec) }
          coverage = decode_coverage(section_bytes(BOMC::SECTION_COVERAGE))
        end

        textures = nil
        measure(timings, :texture_ms) do
          textures = if @sections[BOMC::SECTION_TEXTURE_TABLE]
                       decode_textures(
                         section_bytes(BOMC::SECTION_TEXTURE_TABLE),
                         section_bytes(BOMC::SECTION_TEXTURE_BLOBS)
                       )
                     else
                       []
                     end
        end

        meshes = fallback = nil
        measure(timings, :visual_ms) do
          meshes = decode_geometry(
            mesh_rows, face_rows, normals,
            optional_section_bytes(BOMC::SECTION_POSITIONS),
            optional_section_bytes(BOMC::SECTION_TOPOLOGY),
            optional_section_bytes(BOMC::SECTION_UVS)
          )
          if @sections[BOMC::SECTION_VISUAL_EDGES]
            decode_edges(section_bytes(BOMC::SECTION_VISUAL_EDGES), mesh_rows, meshes)
          end
          fallback = optional_decode(BOMC::SECTION_FALLBACK, []) { |bytes| decode_fallback(bytes, strings) }
        end

        scenes = nil
        measure(timings, :scenes_ms) do
          scenes = if @sections[BOMC::SECTION_SCENES]
                     decode_scenes(section_bytes(BOMC::SECTION_SCENES), strings, tags, instances,
                                   meshes.sum { |mesh| Array(mesh[:faces]).length },
                                   meshes.sum { |mesh| Array(mesh[:edges]).length })
                   else
                     synthetic_default_scenes(tags, instances)
                   end
        end

        measure(timings, :validation_ms) do
          validate_references!(model, materials, tags, meshes, definitions, instances, transforms, textures, coverage, fallback)
        end

        encoding_contract = if @sections[BOMC::SECTION_ENCODING_CONTRACT]
                              BOMCEncodingContract.decode(section_bytes(BOMC::SECTION_ENCODING_CONTRACT))
                            end

        clip_planes = if @sections[BOMC::SECTION_CLIP_PLANES]
                        SceneClipProgram.decode_section(section_bytes(BOMC::SECTION_CLIP_PLANES), strings)
                      else
                        []
                      end

        {
          format: { name: 'BOMC', version: "#{@container[:header][:major]}.#{@container[:header][:minor]}", profile: model[:profile] },
          source: model[:source],
          coordinate_system: model[:coordinate_system],
          bounds: model[:bounds],
          strings: strings,
          materials: materials,
          tags: tags,
          transforms: transforms,
          meshes: meshes,
          definitions: definitions,
          instances: instances,
          root_node: model[:root_node],
          scenes: scenes,
          active_scene_id: (scenes.find { |s| s[:is_active_at_export] } || scenes.first)&.dig(:id),
          textures: textures,
          coverage: coverage,
          fallback: fallback,
          clip_planes: clip_planes,
          debug: debug,
          encoding_contract: encoding_contract,
          container: {
            flags: @container.dig(:header, :flags) || @container[:flags] || 0,
            version_major: @container.dig(:header, :major) || @container[:version_major],
            version_minor: @container.dig(:header, :minor) || @container[:version_minor]
          },
          directory: @container[:sections].map { |section| section.reject { |key, _value| [:bytes, :stored_bytes].include?(key) } }
        }
      end

      private

      def measure(timings, key)
        return yield if timings.nil?
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        timings[key] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        result
      end

      def section_bytes(type)
        @sections.fetch(type)[:bytes]
      end

      def optional_section_bytes(type)
        section = @sections[type]
        section ? section[:bytes] : ''.b
      end

      def optional_decode(type, default)
        section = @sections[type]
        section ? yield(section[:bytes]) : default
      end

      def validate_counted_sections!(counts)
        mapping = {
          materials: [BOMC::SECTION_MATERIALS],
          tags: [BOMC::SECTION_TAGS],
          meshes: [BOMC::SECTION_MESHES, BOMC::SECTION_POSITIONS, BOMC::SECTION_TOPOLOGY],
          faces: [BOMC::SECTION_FACES, BOMC::SECTION_NORMALS],
          textures: [BOMC::SECTION_TEXTURE_TABLE, BOMC::SECTION_TEXTURE_BLOBS],
          edges: [BOMC::SECTION_VISUAL_EDGES]
        }
        mapping.each do |count_name, section_types|
          next if counts[count_name].zero?
          missing = section_types.reject { |type| @sections.key?(type) }
          unless missing.empty?
            raise "BOMC invalid: missing sections #{missing.join(', ')} for #{count_name}."
          end
        end
        texture_pair = [BOMC::SECTION_TEXTURE_TABLE, BOMC::SECTION_TEXTURE_BLOBS]
        if texture_pair.count { |type| @sections.key?(type) } == 1
          raise 'BOMC invalid: texture table/blob sections must appear together.'
        end
      end

      def decode_strings(bytes)
        raise 'BOMC invalid: truncated string section.' if bytes.bytesize < 12
        version, reserved_a, reserved_b, reserved_c, count, data_size = bytes.byteslice(0, 12).unpack('CCCCVV')
        raise 'BOMC invalid: string section version.' unless version == 1
        raise 'BOMC invalid: string section reserved fields.' unless [reserved_a, reserved_b, reserved_c].all?(&:zero?)
        offsets_size = (count + 1) * 4
        expected = 12 + offsets_size + data_size
        raise 'BOMC invalid: string section byte count.' unless bytes.bytesize == expected
        offsets = bytes.byteslice(12, offsets_size).unpack('V*')
        raise 'BOMC invalid: string offsets must start at zero.' unless offsets[0].zero?
        raise 'BOMC invalid: string offsets must end at data size.' unless offsets[-1] == data_size
        offsets.each_cons(2) { |left, right| raise 'BOMC invalid: string offsets are not monotonic.' if right < left }
        data = bytes.byteslice(12 + offsets_size, data_size)
        count.times.map do |index|
          string = data.byteslice(offsets[index], offsets[index + 1] - offsets[index]).dup
          string.force_encoding(Encoding::UTF_8)
          raise 'BOMC invalid: string dictionary contains invalid UTF-8.' unless string.valid_encoding?
          string
        end
      end

      def decode_model(bytes, strings)
        raise 'BOMC invalid: truncated model section.' if bytes.bytesize < 92
        version, profile, string_width, axis_flags, root_node = bytes.byteslice(0, 8).unpack('CCCCV')
        raise 'BOMC invalid: model section version.' unless version == 1
        bounds = bytes.byteslice(8, 48).unpack('E*')
        counts = bytes.byteslice(56, 36).unpack('V*')
        index_bytes = bytes.byteslice(92, bytes.bytesize - 92)
        source_indices = decode_indices_exact(index_bytes, string_width, 2)
        {
          profile: profile == 2 ? :debug : :production,
          root_node: root_node,
          bounds: { min: bounds[0, 3], max: bounds[3, 3] },
          counts: {
            materials: counts[0], tags: counts[1], meshes: counts[2], faces: counts[3],
            definitions: counts[4], instances: counts[5], transforms: counts[6],
            textures: counts[7], edges: counts[8]
          },
          source: { file_name: string_value(strings, source_indices[0]), model_name: string_value(strings, source_indices[1]) },
          coordinate_system: decode_coordinate_flags(axis_flags)
        }
      end

      def decode_materials(bytes, strings)
        cursor = Cursor.new(bytes)
        version, string_width, texture_width, reserved = cursor.read(4).unpack('CCCC')
        raise 'BOMC invalid: material section header.' unless version == 1 && reserved.zero?
        count = cursor.read_u32
        names = cursor.read_indices(string_width, count)
        display_names = cursor.read_indices(string_width, count)
        colors = cursor.read(count * 4).unpack('C*')
        opacity = cursor.read(count * 2).unpack('S<*')
        textures = cursor.read_indices(texture_width, count)
        widths = cursor.read(count * 4).unpack('e*')
        heights = cursor.read(count * 4).unpack('e*')
        cursor.finish!
        count.times.map do |index|
          {
            name: string_value(strings, names[index]),
            display_name: string_value(strings, display_names[index]),
            color: { r: colors[index * 4], g: colors[index * 4 + 1], b: colors[index * 4 + 2], a: colors[index * 4 + 3] },
            opacity: opacity[index] / 65_535.0,
            texture: textures[index],
            texture_width_m: widths[index],
            texture_height_m: heights[index]
          }
        end
      end

      def decode_tags(bytes, strings)
        cursor = Cursor.new(bytes)
        version, string_width, reserved_a, reserved_b = cursor.read(4).unpack('CCCC')
        raise 'BOMC invalid: tag section header.' unless version == 1 && reserved_a.zero? && reserved_b.zero?
        count = cursor.read_u32
        names = cursor.read_indices(string_width, count)
        visibility = cursor.read((count + 7) / 8).unpack('C*')
        cursor.finish!
        count.times.map do |index|
          name = string_value(strings, names[index])
          { id: "tag:#{index}", stable_id: "tag:#{index}", name: name, visible: (visibility[index / 8] & (1 << (index % 8))) != 0 }
        end
      end

      def decode_meshes(bytes)
        cursor = Cursor.new(bytes)
        version, definition_width, reserved_a, reserved_b = cursor.read(4).unpack('CCCC')
        raise 'BOMC invalid: mesh section header.' unless version == 1 && reserved_a.zero? && reserved_b.zero?
        count = cursor.read_u32
        definitions = cursor.read_indices(definition_width, count)
        columns = 11.times.map { cursor.read(count * 4).unpack('V*') }
        cursor.finish!
        count.times.map do |index|
          {
            definition: definitions[index], vertex_count: columns[0][index],
            face_start: columns[1][index], face_count: columns[2][index],
            edge_start: columns[3][index], edge_count: columns[4][index],
            position_offset: columns[5][index], position_length: columns[6][index],
            topology_offset: columns[7][index], topology_length: columns[8][index],
            uv_offset: columns[9][index], uv_length: columns[10][index]
          }
        end
      end

      def decode_faces(bytes, strings)
        cursor = Cursor.new(bytes)
        header = cursor.read(24).unpack('CCCCVVVVV')
        version, material_width, tag_width, string_width, count, total_loops, loop_count_bytes, triangle_count_bytes, loop_length_bytes = header
        raise 'BOMC invalid: face section version.' unless version == 1
        surfaces = cursor.read(count).unpack('C*')
        flags = cursor.read(count).unpack('C*')
        roles = cursor.read(count).unpack('C*')
        front_materials = cursor.read_indices(material_width, count)
        back_materials = cursor.read_indices(material_width, count)
        tags = cursor.read_indices(tag_width, count)
        labels = cursor.read_indices(string_width, count)
        loop_counts = decode_varuint_column(cursor.read(loop_count_bytes), count, 'face loop counts')
        triangle_counts = decode_varuint_column(cursor.read(triangle_count_bytes), count, 'face triangle counts')
        loop_lengths = decode_varuint_column(cursor.read(loop_length_bytes), total_loops, 'face loop lengths')
        cursor.finish!
        loop_cursor = 0
        count.times.map do |index|
          lengths = loop_lengths[loop_cursor, loop_counts[index]] || []
          loop_cursor += loop_counts[index]
          {
            surface_type: BOMC::SURFACE_NAMES.fetch(surfaces[index], 'unknown'),
            hidden: (flags[index] & 1) != 0,
            has_holes: (flags[index] & 2) != 0,
            has_front_uv: (flags[index] & 4) != 0,
            has_back_uv: (flags[index] & 8) != 0,
            front_appearance_required: true,
            back_appearance_required: !back_materials[index].nil?,
            fallback: (flags[index] & 16) != 0,
            semantic_role: BOMC::SEMANTIC_ROLE_NAMES.fetch(roles[index], 'unknown'),
            semantic_label: string_value(strings, labels[index]),
            front_material: front_materials[index],
            back_material: back_materials[index],
            tag: tags[index],
            loop_lengths: lengths,
            triangle_count: triangle_counts[index]
          }
        end.tap do
          raise 'BOMC invalid: face loop length consumption mismatch.' unless loop_cursor == total_loops
        end
      end

      def decode_definitions(bytes, strings)
        cursor = Cursor.new(bytes)
        version, string_width, mesh_width, reserved = cursor.read(4).unpack('CCCC')
        raise 'BOMC invalid: definition section header.' unless version == 1 && reserved.zero?
        count = cursor.read_u32
        names = cursor.read_indices(string_width, count)
        kinds = cursor.read(count).unpack('C*')
        meshes = cursor.read_indices(mesh_width, count)
        cursor.finish!
        count.times.map do |index|
          { name: string_value(strings, names[index]), kind: BOMC::DEFINITION_NAMES.fetch(kinds[index], 'unknown'), mesh: meshes[index], nodes: [] }
        end
      end

      def decode_instances(bytes, strings)
        cursor = Cursor.new(bytes)
        header = cursor.read(12).unpack('CCCCCCCCV')
        version, string_width, definition_width, transform_width, material_width, tag_width, reserved_a, reserved_b, count = header
        raise 'BOMC invalid: instance section header.' unless version == 1 && reserved_a.zero? && reserved_b.zero?
        names = cursor.read_indices(string_width, count)
        kinds = cursor.read(count).unpack('C*')
        owners = cursor.read_indices(definition_width, count)
        definitions = cursor.read_indices(definition_width, count)
        transforms = cursor.read_indices(transform_width, count)
        materials = cursor.read_indices(material_width, count)
        tags = cursor.read_indices(tag_width, count)
        flags = cursor.read(count).unpack('C*')
        roles = cursor.read(count).unpack('C*')
        labels = cursor.read_indices(string_width, count)
        cursor.finish!
        count.times.map do |index|
          {
            id: "node:#{index}",
            stable_id: "node:#{index}",
            name: string_value(strings, names[index]), kind: BOMC::NODE_NAMES.fetch(kinds[index], 'unknown'),
            owner_definition: owners[index], definition: definitions[index], transform: transforms[index],
            material: materials[index], tag: tags[index], visible: (flags[index] & 1) != 0,
            fallback: (flags[index] & 2) != 0,
            semantic_role: BOMC::SEMANTIC_ROLE_NAMES.fetch(roles[index], 'unknown'),
            semantic_label: string_value(strings, labels[index])
          }
        end
      end

      def decode_codec_section(bytes, codec_module)
        raise 'BOMC invalid: truncated codec section.' if bytes.bytesize < 12
        version, codec, reserved_a, reserved_b, count, payload_length = bytes.byteslice(0, 12).unpack('CCCCVV')
        raise 'BOMC invalid: codec section header.' unless version == 1 && reserved_a.zero? && reserved_b.zero?
        raise 'BOMC invalid: codec section byte count.' unless bytes.bytesize == 12 + payload_length
        if codec_module == BOMC::NormalCodec
          min_bytes_per_normal = codec == 1 ? 12 : (codec == 2 ? 4 : 24)
          DecodeBudget.checked_table_bytes(count, 3, 8, payload_length, min_wire: min_bytes_per_normal / 3.0)
        elsif codec_module == BOMC::TransformCodec
          min_bytes_per_matrix = codec == 0 ? 0 : (codec == 5 ? 1 : (codec == 6 ? 128 : (codec == 4 ? 24 : (codec == 3 ? 40 : (codec == 2 ? 48 : 96)))))
          DecodeBudget.checked_table_bytes(count, 16, 8, payload_length, min_wire: min_bytes_per_matrix / 16.0)
        end
        codec_module.decode(codec: codec, count: count, bytes: bytes.byteslice(12, payload_length))
      end

      def decode_geometry(mesh_rows, face_rows, normals, position_bytes, topology_bytes, uv_bytes)
        raise 'BOMC invalid: normal count does not match faces.' unless normals.length == face_rows.length * 3
        mesh_rows.each_with_index.map do |mesh, mesh_index|
          positions = decode_position_block(slice_block(position_bytes, mesh[:position_offset], mesh[:position_length], 'position'))
          raise "BOMC invalid: mesh #{mesh_index} vertex count." unless positions.length == mesh[:vertex_count] * 3
          topology = decode_topology_block(slice_block(topology_bytes, mesh[:topology_offset], mesh[:topology_length], 'topology'))
          local_faces = face_rows[mesh[:face_start], mesh[:face_count]]
          raise "BOMC invalid: mesh #{mesh_index} face range." unless local_faces && local_faces.length == mesh[:face_count]
          loop_cursor = 0
          triangle_cursor = 0
          local_faces.each_with_index do |face, local_index|
            loops = face[:loop_lengths].map do |length|
              loop_values = topology[:loops][loop_cursor, length]
              raise "BOMC invalid: mesh #{mesh_index} loop range." unless loop_values && loop_values.length == length
              loop_cursor += length
              loop_values
            end
            triangle_values = topology[:triangles][triangle_cursor, face[:triangle_count]]
            raise "BOMC invalid: mesh #{mesh_index} triangle range." unless triangle_values && triangle_values.length == face[:triangle_count]
            triangle_cursor += face[:triangle_count]
            face[:outer] = loops.shift || []
            face[:holes] = loops
            face[:triangles] = triangle_values
            face[:normal] = normals[(mesh[:face_start] + local_index) * 3, 3]
            face[:area_m2] = face_area(positions, face[:outer], face[:holes], face[:triangles])
            face[:orientation], face[:azimuth_deg] = orientation(face[:normal])
          end
          unless loop_cursor == topology[:loops].length && triangle_cursor == topology[:triangles].length
            raise "BOMC invalid: mesh #{mesh_index} topology consumption mismatch."
          end
          if mesh[:uv_length] > 0
            uv_values = decode_uv_block(slice_block(uv_bytes, mesh[:uv_offset], mesh[:uv_length], 'UV'))
            assign_uv(local_faces, uv_values, mesh_index)
          else
            if local_faces.any? { |face| face[:has_front_uv] || face[:has_back_uv] }
              raise "BOMC invalid: mesh #{mesh_index} declares missing UV data."
            end
          end
          {
            definition: mesh[:definition], positions: positions,
            faces: local_faces, edges: []
          }
        end
      end

      def decode_position_block(bytes)
        raise 'BOMC invalid: truncated position block.' if bytes.bytesize < 60
        version, codec, reserved_a, reserved_b, count, payload_length = bytes.byteslice(0, 12).unpack('CCCCVV')
        raise 'BOMC invalid: position block header.' unless version == 1 && reserved_a.zero? && reserved_b.zero?
        raise 'BOMC invalid: position block byte count.' unless bytes.bytesize == 60 + payload_length
        min_bytes_per_vertex = codec == 1 ? 24 : (codec == 2 || codec == 3 ? 12 : (codec == 4 ? 6 : 3))
        DecodeBudget.checked_table_bytes(count, 3, 8, payload_length, min_wire: min_bytes_per_vertex / 3.0)
        origin = bytes.byteslice(12, 24).unpack('E*')
        scale = bytes.byteslice(36, 24).unpack('E*')
        BOMC::PositionCodec.decode(codec: codec, count: count, origin: origin, scale: scale, bytes: bytes.byteslice(60, payload_length))
      end

      def decode_uv_block(bytes)
        raise 'BOMC invalid: truncated UV block.' if bytes.bytesize < 44
        version, codec, reserved_a, reserved_b, count, payload_length = bytes.byteslice(0, 12).unpack('CCCCVV')
        raise 'BOMC invalid: UV block header.' unless version == 1 && reserved_a.zero? && reserved_b.zero?
        raise 'BOMC invalid: UV block byte count.' unless bytes.bytesize == 44 + payload_length
        min_bytes_per_uv = codec == 1 ? 8 : (codec == 2 || codec == 3 ? 4 : (codec == 4 ? 2 : 16))
        DecodeBudget.checked_table_bytes(count, 2, 8, payload_length, min_wire: min_bytes_per_uv / 2.0)
        origin = bytes.byteslice(12, 16).unpack('E*')
        scale = bytes.byteslice(28, 16).unpack('E*')
        BOMC::UVCodec.decode(codec: codec, count: count, origin: origin, scale: scale, bytes: bytes.byteslice(44, payload_length))
      end

      def decode_topology_block(bytes)
        raise 'BOMC invalid: truncated topology block.' if bytes.bytesize < 20
        version, reserved_a, reserved_b, reserved_c, loop_count, triangle_count, loop_length, triangle_length = bytes.byteslice(0, 20).unpack('CCCCVVVV')
        raise 'BOMC invalid: topology block header.' unless version == 1 && [reserved_a, reserved_b, reserved_c].all?(&:zero?)
        raise 'BOMC invalid: topology block byte count.' unless bytes.bytesize == 20 + loop_length + triangle_length
        DecodeBudget.checked_table_bytes(loop_count, 1, 4, loop_length, min_wire: 1)
        DecodeBudget.checked_table_bytes(triangle_count, 1, 4, triangle_length, min_wire: 1)
        loop_bytes = bytes.byteslice(20, loop_length)
        triangle_bytes = bytes.byteslice(20 + loop_length, triangle_length)
        {
          loops: decode_delta_indices(loop_bytes, loop_count),
          triangles: decode_delta_indices(triangle_bytes, triangle_count)
        }
      end

      def decode_delta_indices(bytes, count)
        DecodeBudget.checked_table_bytes(count, 1, 4, bytes.bytesize, min_wire: 1)
        cursor = 0
        previous = 0
        values = count.times.map do
          delta, cursor = BOMC::Binary.read_zigzag(bytes, cursor)
          previous += delta
          raise 'BOMC invalid: topology index is negative.' if previous < 0
          previous
        end
        raise 'BOMC invalid: trailing topology bytes.' unless cursor == bytes.bytesize
        values
      end

      def assign_uv(faces, values, mesh_index)
        cursor = 0
        faces.each do |face|
          uv = {}
          [:front, :back].each do |side|
            present = side == :front ? face[:has_front_uv] : face[:has_back_uv]
            next unless present
            loops = face[:loop_lengths].map do |length|
              scalar_count = length * 2
              loop_values = values[cursor, scalar_count]
              raise "BOMC invalid: mesh #{mesh_index} UV range." unless loop_values && loop_values.length == scalar_count
              cursor += scalar_count
              loop_values.each_slice(2).map { |pair| pair }
            end
            uv[(side.to_s + '_outer').to_sym] = loops.shift || []
            uv[(side.to_s + '_holes').to_sym] = loops
          end
          face[:uv] = uv unless uv.empty?
        end
        raise "BOMC invalid: mesh #{mesh_index} UV consumption mismatch." unless cursor == values.length
      end

      def decode_edges(bytes, mesh_rows, meshes)
        cursor = Cursor.new(bytes)
        version, tag_width, reserved_a, reserved_b = cursor.read(4).unpack('CCCC')
        raise 'BOMC invalid: edge section header.' unless version == 1 && reserved_a.zero? && reserved_b.zero?
        count = cursor.read_u32
        endpoint_length = cursor.read_u32
        tags = cursor.read_indices(tag_width, count)
        flags = cursor.read(count).unpack('C*')
        endpoint_bytes = cursor.read(endpoint_length)
        cursor.finish!
        endpoint_cursor = 0
        edges = count.times.map do |index|
          first, endpoint_cursor = BOMC::Binary.read_varuint(endpoint_bytes, endpoint_cursor)
          second, endpoint_cursor = BOMC::Binary.read_varuint(endpoint_bytes, endpoint_cursor)
          {
            vertices: [first, second], tag: tags[index], hidden: (flags[index] & 1) != 0,
            soft: (flags[index] & 2) != 0, smooth: (flags[index] & 4) != 0
          }
        end
        raise 'BOMC invalid: trailing visual edge bytes.' unless endpoint_cursor == endpoint_bytes.bytesize
        mesh_rows.each_with_index do |mesh, index|
          local = edges[mesh[:edge_start], mesh[:edge_count]]
          raise "BOMC invalid: mesh #{index} edge range." unless local && local.length == mesh[:edge_count]
          meshes[index][:edges] = local
        end
      end

      def decode_textures(table_bytes, blob_bytes)
        cursor = Cursor.new(table_bytes)
        version, reserved_a, reserved_b, reserved_c = cursor.read(4).unpack('CCCC')
        raise 'BOMC requires experimental color-map loader.' if version == 2 && !@allow_jpeg_color_map
        raise 'BOMC invalid: texture table header.' unless [1,2].include?(version) && [reserved_a, reserved_b, reserved_c].all?(&:zero?)
        count = cursor.read_u32
        media = cursor.read(count).unpack('C*')
        widths = cursor.read(count * 4).unpack('V*')
        heights = cursor.read(count * 4).unpack('V*')
        hashes = count.times.map { cursor.read(32).unpack('H*')[0] }
        offsets = cursor.read(count * 8).unpack('Q<*')
        lengths = cursor.read(count * 8).unpack('Q<*')
        cursor.finish!
        count.times.map do |index|
          offset = offsets[index]
          length = lengths[index]
          raise "BOMC invalid: texture #{index} outside blob section." if offset + length > blob_bytes.bytesize
          content = blob_bytes.byteslice(offset, length).b
          raise "BOMC invalid: texture #{index} hash mismatch." unless Digest::SHA256.hexdigest(content) == hashes[index]
          raise 'BOMC invalid: texture media.' unless (0..(version == 2 ? 6 : 5)).cover?(media[index])
          if media[index] == 6
            map = BOMCJpegColorMap.parse(content)
            raise 'BOMC invalid: color-map dimensions.' unless map[:width] == widths[index] && map[:height] == heights[index]
          end
          {
            media_type: BOMC::TEXTURE_MEDIA_NAMES.fetch(media[index], :binary),
            image_width_px: widths[index], image_height_px: heights[index],
            sha256: hashes[index], bytes: content
          }
        end
      end

      def decode_coverage(bytes)
        raise 'BOMC invalid: coverage section byte count.' unless bytes.bytesize == 24
        values = bytes.unpack('V6')
        {
          eligible: values[0], analytical: values[1], visual_retained: values[2],
          fallback: values[3], excluded: values[4], unaccounted: values[5]
        }
      end

      def decode_fallback(bytes, strings)
        cursor = Cursor.new(bytes)
        version, instance_width, texture_width, string_width = cursor.read(4).unpack('CCCC')
        raise 'BOMC invalid: fallback section version.' unless version == 1
        count = cursor.read_u32
        instances = cursor.read_indices(instance_width, count)
        kinds = cursor.read(count).unpack('C*')
        x = cursor.read(count * 4).unpack('e*')
        y = cursor.read(count * 4).unpack('e*')
        z = cursor.read(count * 4).unpack('e*')
        widths = cursor.read(count * 4).unpack('e*')
        heights = cursor.read(count * 4).unpack('e*')
        textures = cursor.read_indices(texture_width, count)
        text = cursor.read_indices(string_width, count)
        cursor.finish!
        count.times.map do |index|
          {
            instance: instances[index], kind: BOMC::NODE_NAMES.fetch(kinds[index], 'unknown'),
            position: [x[index], y[index], z[index]], width_m: widths[index], height_m: heights[index],
            texture: textures[index], text: string_value(strings, text[index])
          }
        end
      end

      def decode_debug(bytes, strings)
        cursor = Cursor.new(bytes)
        version, reserved_a, reserved_b, reserved_c = cursor.read(4).unpack('CCCC')
        raise 'BOMC invalid: debug section header.' unless version == 1 && [reserved_a, reserved_b, reserved_c].all?(&:zero?)
        count = cursor.read_u32
        categories = { 1 => :materials, 2 => :tags, 3 => :meshes, 4 => :faces, 5 => :definitions, 6 => :instances, 7 => :edges }
        result = {}
        count.times do
          category = cursor.read_u8
          field = cursor.read_u8
          row = cursor.read_varuint
          string_index = cursor.read_varuint
          name = categories.fetch(category, :unknown)
          result[name] ||= []
          result[name] << string_value(strings, string_index)
          result[:records] ||= []
          result[:records] << { category: name, field: field, row: row, value: string_value(strings, string_index) }
        end
        cursor.finish!
        result
      end

      def validate_references!(model, materials, tags, meshes, definitions, instances, transforms, textures, coverage, fallback)
        expected = model[:counts]
        actual = {
          materials: materials.length, tags: tags.length, meshes: meshes.length,
          faces: meshes.map { |mesh| mesh[:faces].length }.inject(0, :+),
          definitions: definitions.length, instances: instances.length, transforms: transforms.length,
          textures: textures.length, edges: meshes.map { |mesh| mesh[:edges].length }.inject(0, :+)
        }
        expected.each { |key, value| raise "BOMC invalid: #{key} count mismatch." unless actual[key] == value }
        raise 'BOMC invalid: root node reference.' unless model[:root_node] < instances.length && instances[model[:root_node]][:kind] == 'root'
        meshes.each_with_index do |mesh, mesh_index|
          validate_index!(mesh[:definition], definitions.length, "mesh #{mesh_index} definition")
          mesh[:faces].each_with_index do |face, face_index|
            [face[:front_material], face[:back_material]].compact.each { |index| validate_index!(index, materials.length, "face #{face_index} material") }
            validate_index!(face[:tag], tags.length, "face #{face_index} tag") unless face[:tag].nil?
            (face[:outer] + face[:holes].flatten + face[:triangles]).each do |index|
              validate_index!(index, mesh[:positions].length / 3, "mesh #{mesh_index} topology")
            end
          end
          mesh[:edges].each do |edge|
            edge[:vertices].each { |index| validate_index!(index, mesh[:positions].length / 3, "mesh #{mesh_index} edge") }
          end
        end
        definitions.each_with_index do |definition, index|
          validate_index!(definition[:mesh], meshes.length, "definition #{index} mesh") unless definition[:mesh].nil?
        end
        instances.each_with_index do |instance, index|
          if ['root', 'component_instance', 'group_instance'].include?(instance[:kind])
            validate_index!(instance[:definition], definitions.length, "instance #{index} definition")
          elsif !instance[:definition].nil?
            validate_index!(instance[:definition], definitions.length, "instance #{index} definition")
          end
          validate_index!(instance[:owner_definition], definitions.length, "instance #{index} owner") unless instance[:owner_definition].nil?
          validate_index!(instance[:transform], transforms.length, "instance #{index} transform")
          validate_index!(instance[:material], materials.length, "instance #{index} material") unless instance[:material].nil?
          validate_index!(instance[:tag], tags.length, "instance #{index} tag") unless instance[:tag].nil?
        end
        materials.each_with_index do |material, index|
          validate_index!(material[:texture], textures.length, "material #{index} texture") unless material[:texture].nil?
        end
        fallback.each_with_index do |record, index|
          validate_index!(record[:instance], instances.length, "fallback #{index} instance")
          validate_index!(record[:texture], textures.length, "fallback #{index} texture") unless record[:texture].nil?
          unless instances[record[:instance]][:kind] == record[:kind]
            raise "BOMC invalid: fallback #{index} kind does not match instance."
          end
        end
        if coverage[:eligible] != coverage[:analytical] + coverage[:fallback] + coverage[:excluded] + coverage[:unaccounted]
          raise 'BOMC invalid: coverage disposition does not sum to eligible geometry.'
        end
        raise 'BOMC invalid: unaccounted geometry is nonzero.' unless coverage[:unaccounted].zero?
      end

      def validate_index!(index, count, label)
        raise "BOMC invalid: #{label} reference." unless index.is_a?(Integer) && index >= 0 && index < count
      end

      def triangles_area(positions, triangles)
        return 0.0 if triangles.nil? || triangles.length < 3

        total = 0.0
        triangles.each_slice(3) do |t|
          next unless t.length == 3
          p0 = positions[t[0] * 3, 3]
          p1 = positions[t[1] * 3, 3]
          p2 = positions[t[2] * 3, 3]
          next unless p0 && p1 && p2
          v1 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]]
          v2 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]]
          cross = [
            v1[1] * v2[2] - v1[2] * v2[1],
            v1[2] * v2[0] - v1[0] * v2[2],
            v1[0] * v2[1] - v1[1] * v2[0]
          ]
          total += 0.5 * Math.sqrt(cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2])
        end
        total
      end

      def face_area(positions, outer, holes, triangles = nil)
        if triangles && triangles.length >= 3
          triangles_area(positions, triangles)
        else
          outer_area = polygon_area(positions, outer)
          holes_area = holes.map { |indices| polygon_area(positions, indices) }.inject(0.0, :+)
          [outer_area - holes_area, 0.0].max
        end
      end

      def polygon_area(positions, indices)
        return 0.0 if indices.length < 3
        vector = [0.0, 0.0, 0.0]
        indices.each_with_index do |index, cursor|
          following = indices[(cursor + 1) % indices.length]
          current = positions[index * 3, 3]
          after = positions[following * 3, 3]
          vector[0] += (current[1] - after[1]) * (current[2] + after[2])
          vector[1] += (current[2] - after[2]) * (current[0] + after[0])
          vector[2] += (current[0] - after[0]) * (current[1] + after[1])
        end
        Math.sqrt(vector.map { |value| value * value }.inject(0.0, :+)) * 0.5
      end

      def orientation(normal)
        x, y, z = normal.map(&:to_f)
        label = if z > 0.999
                  :up
                elsif z < -0.999
                  :down
                elsif z.abs < 0.01
                  :vertical
                else
                  :sloped
                end
        azimuth = (Math.atan2(x, y) * 180.0 / Math::PI) % 360.0
        [label, azimuth]
      end

      def slice_block(stream, offset, length, label)
        block = stream.byteslice(offset, length)
        raise "BOMC invalid: #{label} block outside section." unless block && block.bytesize == length
        block
      end

      def decode_indices_exact(bytes, width, count)
        expected = width * count
        raise 'BOMC invalid: adaptive index byte count.' unless bytes.bytesize == expected
        BOMC::Binary.unpack_indices(bytes, width, count)
      end

      def decode_varuint_column(bytes, count, label)
        cursor = 0
        values = count.times.map do
          value, cursor = BOMC::Binary.read_varuint(bytes, cursor)
          value
        end
        raise "BOMC invalid: trailing #{label} bytes." unless cursor == bytes.bytesize
        values
      end

      def string_value(strings, index)
        return nil if index.nil?
        raise 'BOMC invalid: string reference.' unless index >= 0 && index < strings.length
        strings[index]
      end

      def decode_coordinate_flags(flags)
        axis = { 0 => '+X', 1 => '+Y', 2 => '+Z' }.fetch((flags >> 1) & 0x03, '+Z')
        { units: 'm', handedness: (flags & 1).zero? ? 'left' : 'right', up_axis: axis }
      end

      def decode_scenes(bytes, strings, tags, instances, face_count = nil, edge_count = nil)
        return [] if bytes.nil? || bytes.empty?

        version, tag_count, scenes_count = bytes.byteslice(0, 6).unpack('CCV')
        raise 'BOMC invalid: scenes section version.' unless [1, 2, 3, 4, 5].include?(version)
        tag_bitset_bytes = (tag_count + 7) / 8
        cursor = 6

        tag_stable_ids = []
        if version >= 3
          tag_count.times do
            str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
            tag_stable_ids << string_value(strings, str_idx)
          end
        end

        scenes_count.times.map do
          scene_header = bytes.byteslice(cursor, 68)
          cursor += 68
          id_idx, name_idx, desc_idx, sig_idx, flags,
          eye_x, eye_y, eye_z,
          tgt_x, tgt_y, tgt_z,
          up_x, up_y, up_z,
          fov_or_height, aspect_ratio, trans_time = scene_header.unpack('VVVVVe3e3e3e3')

          is_active = (flags & 0x01) != 0
          use_camera = (flags & 0x02) != 0
          stores_tags = (flags & 0x04) != 0
          stores_objects = (flags & 0x08) != 0
          stores_geometry = (flags & 0x10) != 0
          stores_sections = (flags & 0x20) != 0
          is_persp = (flags & 0x40) != 0
          fov_is_height = (flags & 0x80) != 0
          is_2d = (flags & 0x100) != 0
          section_cuts_displayed = (flags & 0x200) != 0
          section_planes_displayed = (flags & 0x400) != 0

          bitset_bytes = bytes.byteslice(cursor, tag_bitset_bytes).unpack('C*')
          cursor += tag_bitset_bytes

          visible_tag_indices = []
          hidden_tag_indices = []
          tag_count.times do |idx|
            byte_idx = idx / 8
            bit_idx = idx % 8
            if (bitset_bytes[byte_idx] & (1 << bit_idx)) != 0
              visible_tag_indices << idx
            else
              hidden_tag_indices << idx
            end
          end

          hidden_nodes_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
          hidden_nodes = []
          resolved_hidden_node_ids = []
          hidden_nodes_count.times do
            node_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
            hidden_nodes << node_idx
            if version >= 3
              str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              resolved_hidden_node_ids << string_value(strings, str_idx)
            end
          end

          visible_nodes_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
          visible_nodes = []
          resolved_visible_node_ids = []
          visible_nodes_count.times do
            node_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
            visible_nodes << node_idx
            if version >= 3
              str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              resolved_visible_node_ids << string_value(strings, str_idx)
            end
          end

          unresolved_hidden_overrides = []
          unresolved_visible_overrides = []

          if version >= 2
            unresolved_hidden_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
            unresolved_hidden_count.times do
              str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              unresolved_hidden_overrides << string_value(strings, str_idx)
            end

            unresolved_visible_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
            unresolved_visible_count.times do
              str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              unresolved_visible_overrides << string_value(strings, str_idx)
            end
          end

          primitive = {
            hidden_face_indices: [], visible_face_indices: [], hidden_edge_indices: [], visible_edge_indices: [],
            hidden_face_overrides: [], visible_face_overrides: [], hidden_edge_overrides: [], visible_edge_overrides: [],
            unresolved_hidden_face_overrides: [], unresolved_visible_face_overrides: [],
            unresolved_hidden_edge_overrides: [], unresolved_visible_edge_overrides: [],
            unresolved_primitive_overrides: [], active_section_plane_ids: []
          }
          if version >= 4
            read_primitive_rows = lambda do |index_key, id_key, unresolved_key, limit|
              count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              count.times do
                idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
                raise 'BOMC invalid: scene primitive index.' if !limit.nil? && idx >= limit
                str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
                primitive[index_key] << idx
                primitive[id_key] << string_value(strings, str_idx)
              end
              unresolved_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              unresolved_count.times do
                str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
                id = string_value(strings, str_idx)
                primitive[id_key] << id
                primitive[unresolved_key] << id
              end
            end
            read_primitive_rows.call(:hidden_face_indices, :hidden_face_overrides, :unresolved_hidden_face_overrides, face_count)
            read_primitive_rows.call(:visible_face_indices, :visible_face_overrides, :unresolved_visible_face_overrides, face_count)
            read_primitive_rows.call(:hidden_edge_indices, :hidden_edge_overrides, :unresolved_hidden_edge_overrides, edge_count)
            read_primitive_rows.call(:visible_edge_indices, :visible_edge_overrides, :unresolved_visible_edge_overrides, edge_count)
            unresolved_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
            unresolved_count.times do
              str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              primitive[:unresolved_primitive_overrides] << string_value(strings, str_idx)
            end
            section_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
            section_count.times do
              str_idx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              primitive[:active_section_plane_ids] << string_value(strings, str_idx)
            end
            if version >= 5
              clip_count, cursor = BOMC::Binary.read_varuint(bytes, cursor)
              primitive[:active_clip_plane_indices] = []
              clip_count.times do
                cidx, cursor = BOMC::Binary.read_varuint(bytes, cursor)
                primitive[:active_clip_plane_indices] << cidx
              end
            end
          end

          visible_tag_ids = visible_tag_indices.map do |i|
            (version >= 3 && tag_stable_ids[i]) ? tag_stable_ids[i] : (tags[i] ? tags[i][:stable_id] : "tag:#{i}")
          end
          hidden_tag_ids = hidden_tag_indices.map do |i|
            (version >= 3 && tag_stable_ids[i]) ? tag_stable_ids[i] : (tags[i] ? tags[i][:stable_id] : "tag:#{i}")
          end

          if version >= 3
            visible_node_overrides = resolved_visible_node_ids + unresolved_visible_overrides
            hidden_node_overrides = resolved_hidden_node_ids + unresolved_hidden_overrides
          else
            visible_node_overrides = visible_nodes.map { |i| instances[i] ? instances[i][:stable_id] : "node:#{i}" } + unresolved_visible_overrides
            hidden_node_overrides = hidden_nodes.map { |i| instances[i] ? instances[i][:stable_id] : "node:#{i}" } + unresolved_hidden_overrides
          end

          stable_id = strings[id_idx].to_s
          stable_id = "scene:doc:#{name_idx}" if stable_id.empty?

          has_section_cuts = primitive[:active_clip_plane_indices]&.any? || !primitive[:active_section_plane_ids].empty?
          rendering_support = (version >= 5 && section_cuts_displayed && has_section_cuts) ? 'full' : 'metadata-only'

          {
            id: stable_id,
            name: strings[name_idx].to_s,
            description: strings[desc_idx].to_s,
            is_active_at_export: is_active,
            source: 'sketchup-page',
            source_binding: { provider: 'sketchup', persistent_id: stable_id.sub(/\Ascene:doc:/, '') },
            section_version: version,
            camera: {
              projection: is_persp ? 'perspective' : 'orthographic',
              eye_m: [eye_x.round(6), eye_y.round(6), eye_z.round(6)],
              target_m: [tgt_x.round(6), tgt_y.round(6), tgt_z.round(6)],
              up: [up_x.round(6), up_y.round(6), up_z.round(6)],
              field_of_view_degrees: is_persp ? fov_or_height.round(4) : nil,
              fov_is_height: fov_is_height,
              orthographic_height_m: !is_persp ? fov_or_height.round(6) : nil,
              aspect_ratio: aspect_ratio.round(6),
              is_2d: is_2d
            },
            use_camera: use_camera,
            transition_time_seconds: trans_time.round(4),
            visibility: {
              visible_tag_ids: visible_tag_ids,
              hidden_tag_ids: hidden_tag_ids,
              visible_node_overrides: visible_node_overrides,
              hidden_node_overrides: hidden_node_overrides,
              visible_tag_indices: visible_tag_indices,
              hidden_tag_indices: hidden_tag_indices,
              visible_node_indices: visible_nodes,
              hidden_node_indices: hidden_nodes,
              source_visible_node_override_count: visible_nodes.length + unresolved_visible_overrides.length,
              source_hidden_node_override_count: hidden_nodes.length + unresolved_hidden_overrides.length,
              resolved_visible_node_override_count: visible_nodes.length,
              resolved_hidden_node_override_count: hidden_nodes.length,
              unresolved_visible_node_overrides: unresolved_visible_overrides,
              unresolved_hidden_node_overrides: unresolved_hidden_overrides,
              unresolved_visible_node_override_count: unresolved_visible_overrides.length,
              unresolved_hidden_node_override_count: unresolved_hidden_overrides.length,
              **primitive.reject { |key, _| key == :active_section_plane_ids || key == :active_clip_plane_indices },
              resolved_visible_primitive_override_count: primitive[:visible_face_indices].length + primitive[:visible_edge_indices].length,
              resolved_hidden_primitive_override_count: primitive[:hidden_face_indices].length + primitive[:hidden_edge_indices].length,
              unresolved_visible_primitive_override_count: primitive[:unresolved_visible_face_overrides].length + primitive[:unresolved_visible_edge_overrides].length,
              unresolved_hidden_primitive_override_count: primitive[:unresolved_hidden_face_overrides].length + primitive[:unresolved_hidden_edge_overrides].length + primitive[:unresolved_primitive_overrides].length,
              unresolved_primitive_override_count: primitive[:unresolved_hidden_face_overrides].length + primitive[:unresolved_visible_face_overrides].length + primitive[:unresolved_hidden_edge_overrides].length + primitive[:unresolved_visible_edge_overrides].length + primitive[:unresolved_primitive_overrides].length
            },
            stores_tag_visibility: stores_tags,
            stores_hidden_objects: stores_objects,
            stores_hidden_geometry: stores_geometry,
            stores_section_planes: stores_sections,
            section_state: {
              active_section_plane_ids: primitive[:active_section_plane_ids],
              active_clip_plane_indices: primitive[:active_clip_plane_indices] || [],
              section_cuts_displayed: section_cuts_displayed,
              section_planes_displayed: section_planes_displayed,
              rendering_support: rendering_support
            },
            visibility_signature: strings[sig_idx].to_s
          }
        end
      end

      def synthetic_default_scenes(tags, instances)
        visible_tag_ids = tags.select { |t| t[:visible] != false }.map { |t| t[:stable_id] }
        hidden_tag_ids = tags.select { |t| t[:visible] == false }.map { |t| t[:stable_id] }
        visible_tag_indices = tags.each_with_index.select { |t, _i| t[:visible] != false }.map { |_t, i| i }
        hidden_tag_indices = tags.each_with_index.select { |t, _i| t[:visible] == false }.map { |_t, i| i }

        signature = SceneVisibilityResolver.compute_visibility_signature(
          visible_tag_ids: visible_tag_ids,
          hidden_tag_ids: hidden_tag_ids,
          visible_node_overrides: [],
          hidden_node_overrides: [],
          active_section_plane_ids: []
        )

        [{
          id: 'scene:doc:default',
          name: 'Default Scene',
          description: '',
          is_active_at_export: true,
          source: 'legacy-synthetic',
          source_binding: { provider: 'bomc', persistent_id: 'legacy_synthetic' },
          camera: {
            projection: 'perspective',
            eye_m: [10.0, -10.0, 10.0],
            target_m: [0.0, 0.0, 0.0],
            up: [0.0, 0.0, 1.0],
            field_of_view_degrees: 35.0,
            orthographic_height_m: nil,
            aspect_ratio: 0.0
          },
          use_camera: false,
          transition_time_seconds: 0.0,
          visibility: {
            visible_tag_ids: visible_tag_ids,
            hidden_tag_ids: hidden_tag_ids,
            visible_node_overrides: [],
            hidden_node_overrides: [],
            visible_tag_indices: visible_tag_indices,
            hidden_tag_indices: hidden_tag_indices,
            visible_node_indices: [],
            hidden_node_indices: []
          },
          stores_tag_visibility: true,
          stores_hidden_objects: true,
          stores_hidden_geometry: false,
          stores_section_planes: false,
          section_state: { active_section_plane_ids: [], section_cuts_displayed: false, section_planes_displayed: false, rendering_support: 'none' },
          visibility_signature: signature
        }]
      end
    end

    class Cursor
      def initialize(bytes)
        @bytes = bytes
        @offset = 0
      end

      def remaining
        @bytes.bytesize - @offset
      end

      def read(length)
        count = Integer(length)
        if count > DecodeBudget::MAX_ALLOCATION_BYTES
          raise "BOMC invalid: read size #{count} exceeds allocation budget."
        end
        value = @bytes.byteslice(@offset, count)
        raise 'BOMC invalid: truncated table section.' unless value && value.bytesize == count
        @offset += count
        value
      end

      def read_u8
        read(1).getbyte(0)
      end

      def read_u32
        read(4).unpack('V')[0]
      end

      def read_indices(width, count)
        DecodeBudget.checked_table_bytes(count, 1, 4, remaining, min_wire: width)
        BOMC::Binary.unpack_indices(read(width * count), width, count)
      end

      def read_varuint
        value, cursor = BOMC::Binary.read_varuint(@bytes, @offset)
        @offset = cursor
        value
      end

      def finish!
        raise 'BOMC invalid: trailing table bytes.' unless @offset == @bytes.bytesize
      end
    end
  end
end
