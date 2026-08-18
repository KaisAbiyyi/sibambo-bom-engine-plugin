# BOMC 1.1 compiled building writer.

require 'digest'
require 'fileutils'
require_relative 'bomc_format'
require_relative 'bomc_codecs'
require_relative 'bomc_model_adapter'

module BOMEngine
  module BOMCWriter
    FORMAT_NAME = 'BOMC'.freeze
    FORMAT_VERSION = '1.1'.freeze

    SECTION_NAMES = {
      BOMC::SECTION_MODEL => :model,
      BOMC::SECTION_STRINGS => :strings,
      BOMC::SECTION_MATERIALS => :materials,
      BOMC::SECTION_TAGS => :tags,
      BOMC::SECTION_MESHES => :meshes,
      BOMC::SECTION_FACES => :faces,
      BOMC::SECTION_POSITIONS => :positions,
      BOMC::SECTION_TOPOLOGY => :topology,
      BOMC::SECTION_NORMALS => :normals,
      BOMC::SECTION_UVS => :uv,
      BOMC::SECTION_DEFINITIONS => :definitions,
      BOMC::SECTION_INSTANCES => :instances,
      BOMC::SECTION_TRANSFORMS => :transforms,
      BOMC::SECTION_VISUAL_EDGES => :visual_edges,
      BOMC::SECTION_TEXTURE_TABLE => :texture_table,
      BOMC::SECTION_TEXTURE_BLOBS => :textures,
      BOMC::SECTION_COVERAGE => :coverage,
      BOMC::SECTION_FALLBACK => :fallback,
      BOMC::SECTION_SCENES => :scenes,
      BOMC::SECTION_DEBUG => :debug
    }.freeze

    def self.pack(graph, profile: :production, base_path: nil, sparse: true, compact_directory: true, compression_level: Zlib::BEST_COMPRESSION, minimal_metadata: false, checkpoint: nil)
      Builder.new(
        graph,
        profile: profile,
        base_path: base_path,
        sparse: sparse,
        compact_directory: compact_directory,
        compression_level: compression_level,
        minimal_metadata: minimal_metadata,
        checkpoint: checkpoint
      ).build
    end

    def self.write(path, graph, profile: :production, base_path: nil, sparse: true, compact_directory: true, compression_level: Zlib::BEST_COMPRESSION, minimal_metadata: false, checkpoint: nil)
      result = pack(
        graph,
        profile: profile,
        base_path: base_path,
        sparse: sparse,
        compact_directory: compact_directory,
        compression_level: compression_level,
        minimal_metadata: minimal_metadata,
        checkpoint: checkpoint
      )
      temporary_path = "#{path}.#{Process.pid}.part"
      begin
        File.open(temporary_path, 'wb') { |file| file.write(result[:bytes]) }
        FileUtils.mv(temporary_path, path, force: true)
      ensure
        File.delete(temporary_path) if File.file?(temporary_path)
      end
      result.merge(
        path: path,
        bytes: File.size(path),
        sha256: Digest::SHA256.file(path).hexdigest
      )
    end

    class Builder
      def initialize(graph, profile:, base_path:, sparse:, compact_directory:, compression_level:, minimal_metadata:, checkpoint:)
        @profile = profile.to_sym
        raise ArgumentError, "Unknown BOMC profile #{@profile}." unless [:production, :debug].include?(@profile)
        @sparse = !!sparse
        @compact_directory = !!compact_directory
        @compression_level = Integer(compression_level)
        @minimal_metadata = !!minimal_metadata
        @checkpoint = checkpoint
        @model = BOMC::ModelAdapter.normalize(graph, base_path: base_path, checkpoint: @checkpoint)
        @adaptive_actual = 0
        @adaptive_u32 = 0
        @position_metrics = []
        @uv_metrics = []
        @topology_absolute_bytes = 0
        @topology_encoded_bytes = 0
        build_texture_registry
        build_string_dictionary
      end

      def build
        notify(:compile_metadata, 0, 1)
        geometry = build_geometry
        normal_block = BOMC::NormalCodec.encode(geometry[:normals])
        notify(:encode_normals, geometry[:normals].length / 3, geometry[:normals].length / 3)
        transform_block = BOMC::TransformCodec.encode(@model[:transforms], checkpoint: @checkpoint)
        notify(:encode_transforms, @model[:transforms].length, @model[:transforms].length)
        all_sections = [
          section(BOMC::SECTION_MODEL, 1, build_model_section(geometry), true),
          section(BOMC::SECTION_STRINGS, @strings.length, build_strings_section, true),
          section(BOMC::SECTION_MATERIALS, @model[:materials].length, build_materials_section, true),
          section(BOMC::SECTION_TAGS, @model[:tags].length, build_tags_section, true),
          section(BOMC::SECTION_MESHES, @model[:meshes].length, build_meshes_section(geometry[:meshes]), true),
          section(BOMC::SECTION_FACES, geometry[:faces].length, build_faces_section(geometry[:faces]), true),
          section(BOMC::SECTION_POSITIONS, @model[:meshes].length, geometry[:position_bytes], true),
          section(BOMC::SECTION_TOPOLOGY, @model[:meshes].length, geometry[:topology_bytes], true),
          section(BOMC::SECTION_NORMALS, geometry[:normals].length / 3, pack_codec_section(normal_block), true),
          section(BOMC::SECTION_UVS, geometry[:uv_block_count], geometry[:uv_bytes], true),
          section(BOMC::SECTION_DEFINITIONS, @model[:definitions].length, build_definitions_section, true),
          section(BOMC::SECTION_INSTANCES, @model[:instances].length, build_instances_section, true),
          section(BOMC::SECTION_TRANSFORMS, @model[:transforms].length, pack_codec_section(transform_block), true),
          section(BOMC::SECTION_VISUAL_EDGES, geometry[:edges].length, build_edges_section(geometry[:edges]), true),
          section(BOMC::SECTION_TEXTURE_TABLE, @textures.length, build_texture_table_section, true),
          section(BOMC::SECTION_TEXTURE_BLOBS, @textures.length, @texture_blob_bytes, false),
          section(BOMC::SECTION_COVERAGE, 1, build_coverage_section, true),
          section(BOMC::SECTION_FALLBACK, fallback_records.length, build_fallback_section, true)
        ]
        scenes = Array(@model[:scenes])
        if !scenes.empty?
          all_sections << section(BOMC::SECTION_SCENES, scenes.length, build_scenes_section, true)
        end
        all_sections << section(BOMC::SECTION_DEBUG, debug_records.length, build_debug_section, true) if @profile == :debug
        required = [
          BOMC::SECTION_MODEL, BOMC::SECTION_STRINGS, BOMC::SECTION_DEFINITIONS,
          BOMC::SECTION_INSTANCES, BOMC::SECTION_TRANSFORMS, BOMC::SECTION_COVERAGE
        ]
        sections = if @sparse
                     all_sections.select { |entry| required.include?(entry[:type]) || entry[:count] > 0 }
                   else
                     all_sections
                   end
        flags = @profile == :debug ? BOMC::PROFILE_DEBUG : BOMC::PROFILE_PRODUCTION
        flags |= BOMC::FLAG_HAS_SCENES unless scenes.empty?
        scope = (@model.dig(:source, :scope) || '').to_s
        if scope == 'active'
          flags |= BOMC::FLAG_SCOPE_ACTIVE
        elsif scope == 'all' || !scenes.empty?
          flags |= BOMC::FLAG_SCOPE_ALL
        end
        bytes = BOMC::Container.pack(
          sections,
          flags: flags,
          compact_directory: @compact_directory,
          version_minor: @compact_directory ? 1 : 0,
          compression_level: @compression_level,
          checkpoint: @checkpoint
        )
        parsed = BOMC::Container.parse(bytes)
        section_sizes = {}
        parsed[:sections].each do |descriptor|
          name = SECTION_NAMES.fetch(descriptor[:type], :unknown)
          section_sizes[name] = {
            raw_bytes: descriptor[:raw_size],
            stored_bytes: descriptor[:stored_size],
            codec: descriptor[:codec],
            count: descriptor[:count]
          }
        end
        {
          bytes: bytes,
          sha256: Digest::SHA256.hexdigest(bytes),
          format: FORMAT_VERSION,
          profile: @profile,
          metrics: {
            header_directory_bytes: BOMC::HEADER_BYTES + parsed[:sections].length * parsed[:header][:directory_entry_bytes],
            directory_entry_bytes: parsed[:header][:directory_entry_bytes],
            omitted_empty_sections: all_sections.length - sections.length,
            sections: section_sizes,
            positions: @position_metrics,
            normals: normal_block.reject { |key, _value| key == :bytes },
            uv: @uv_metrics,
            transforms: transform_block.reject { |key, _value| key == :bytes },
            topology: {
              absolute_bytes: @topology_absolute_bytes,
              encoded_bytes: @topology_encoded_bytes,
              saved_bytes: @topology_absolute_bytes - @topology_encoded_bytes
            },
            adaptive_indices: {
              uint32_bytes: @adaptive_u32,
              actual_bytes: @adaptive_actual,
              saved_bytes: @adaptive_u32 - @adaptive_actual
            },
            textures: {
              source_references: @texture_reference_count,
              unique: @textures.length,
              deduplicated: @texture_reference_count - @textures.length,
              bytes: @texture_blob_bytes.bytesize,
              encodings: texture_encoding_metrics,
              evidence: @textures.map { |texture| texture[:encoding_evidence] }.compact
            },
            appearance: appearance_metrics,
            coverage: @model[:coverage]
          }
        }
      end

      private

      def appearance_metrics
        faces = @model[:meshes].map { |mesh| mesh[:faces] }.flatten
        triangle_count = lambda { |face| Array(face[:triangles]).length / 3 }
        front = faces.select { |face| face[:front_appearance_required] }
        back = faces.select { |face| face[:back_appearance_required] }
        front_uv = faces.select { |face| uv_side_present?(face, :front) }
        back_uv = faces.select { |face| uv_side_present?(face, :back) }
        back_material = faces.select { |face| !face[:back_material].nil? }
        back_uv_only = back_uv.reject { |face| face[:back_appearance_required] }
        front_triangles = front.inject(0) { |sum, face| sum + triangle_count.call(face) }
        back_triangles = back.inject(0) { |sum, face| sum + triangle_count.call(face) }
        uv_scalars = faces.inject(0) do |sum, face|
          sum + [:front_outer, :front_holes, :back_outer, :back_holes].inject(0) do |face_sum, key|
            face_sum + Array(face.dig(:uv, key)).flatten.length
          end
        end
        {
          faces_total: faces.length,
          front_appearance_faces: front.length,
          back_appearance_faces: back.length,
          front_uv_faces: front_uv.length,
          back_uv_faces: back_uv.length,
          back_material_faces: back_material.length,
          back_uv_only_faces: back_uv_only.length,
          redundant_back_pass_candidates: back_uv_only.length,
          front_triangle_count: front_triangles,
          required_back_triangle_count: back_triangles,
          estimated_two_side_triangle_occurrences: front_triangles + back_triangles,
          uv_scalar_count: uv_scalars,
          uncompressed_uv_bytes: uv_scalars * 4
        }
      end

      def uv_side_present?(face, side)
        uv = face[:uv]
        return false unless uv
        !Array(uv[(side.to_s + '_outer').to_sym]).empty? || !Array(uv[(side.to_s + '_holes').to_sym]).empty?
      end

      def section(type, count, bytes, compress)
        { type: type, count: count, bytes: bytes.b, compress: compress }
      end

      def notify(stage, processed, total, candidate_bytes = nil)
        return unless @checkpoint
        @checkpoint.call(
          stage: stage,
          processed: processed,
          total: total,
          candidate_bytes: candidate_bytes
        )
      end

      def texture_encoding_metrics
        @textures.each_with_object(Hash.new { |hash, key| hash[key] = { count: 0, bytes: 0 } }) do |texture, result|
          media = texture[:media_type] || :binary
          result[media][:count] += 1
          result[media][:bytes] += texture[:bytes].bytesize
        end
      end

      def build_texture_registry
        by_hash = {}
        @texture_reference_count = 0
        @model[:materials].each do |material|
          texture = material[:texture]
          next if texture.nil?
          @texture_reference_count += 1
          hash = texture[:sha256]
          existing = by_hash[hash]
          if existing && existing[:bytes] != texture[:bytes]
            raise 'BOMC source invalid: texture hash collision.'
          end
          by_hash[hash] ||= texture
        end
        @model[:instances].each do |instance|
          texture = instance.dig(:fallback, :texture)
          next if texture.nil?
          @texture_reference_count += 1
          hash = texture[:sha256]
          existing = by_hash[hash]
          raise 'BOMC source invalid: texture hash collision.' if existing && existing[:bytes] != texture[:bytes]
          by_hash[hash] ||= texture
        end
        @textures = by_hash.keys.sort.map { |hash| by_hash[hash] }
        texture_index = {}
        @textures.each_with_index { |texture, index| texture_index[texture[:sha256]] = index }
        @model[:materials].each do |material|
          material[:texture_index] = material[:texture] ? texture_index[material[:texture][:sha256]] : nil
        end
        @model[:instances].each do |instance|
          fallback = instance[:fallback]
          fallback[:texture_index] = fallback[:texture] ? texture_index[fallback[:texture][:sha256]] : nil if fallback
        end
        @texture_blob_bytes = +''.b
        @textures.each_with_index do |texture, index|
          texture[:blob_offset] = @texture_blob_bytes.bytesize
          @texture_blob_bytes << texture[:bytes]
          texture[:blob_length] = texture[:bytes].bytesize
          notify(:encode_textures, index + 1, @textures.length, @texture_blob_bytes.bytesize)
        end
      end

      def build_string_dictionary
        candidates = []
        source = @model[:source] || {}
        unless @minimal_metadata
          candidates << source[:file_name]
          candidates << source[:model_name]
        end
        @model[:materials].each do |material|
          candidates << material[:name]
          candidates << material[:display_name]
        end
        @model[:tags].each { |tag| candidates << tag[:name] }
        @model[:definitions].each { |definition| candidates << definition[:name] }
        @model[:instances].each_with_index do |instance, index|
          notify(:compile_metadata, index + 1, @model[:instances].length)
          candidates << instance[:name]
          candidates << instance[:semantic_label]
        end
        @model[:meshes].each do |mesh|
          mesh[:faces].each { |face| candidates << face[:semantic_label] }
        end
        Array(@model[:scenes]).each do |scene|
          candidates << scene[:name]
          candidates << scene[:description]
          candidates << scene[:stable_id]
          candidates << scene[:visibility_signature]
        end
        if @profile == :debug
          each_debug_string { |value| candidates << value }
        end
        @strings = candidates.compact.map(&:to_s).uniq.sort
        @string_index = {}
        @strings.each_with_index { |value, index| @string_index[value] = index }
      end

      def build_strings_section
        data = +''.b
        offsets = [0]
        @strings.each do |string|
          encoded = string.encode(Encoding::UTF_8).b
          data << encoded
          offsets << data.bytesize
        end
        [1, 0, 0, 0, @strings.length, data.bytesize].pack('CCCCVV') + offsets.pack('V*') + data
      end

      def build_model_section(geometry)
        source = @model[:source] || {}
        string_width = BOMC::Binary.index_width(@strings.length)
        axis_flags = coordinate_flags(@model[:coordinate_system] || {})
        counts = [
          @model[:materials].length,
          @model[:tags].length,
          @model[:meshes].length,
          geometry[:faces].length,
          @model[:definitions].length,
          @model[:instances].length,
          @model[:transforms].length,
          @textures.length,
          geometry[:edges].length
        ]
        bounds = Array(@model.dig(:bounds, :min)) + Array(@model.dig(:bounds, :max))
        header = [1, @profile == :debug ? 2 : 1, string_width, axis_flags, @model[:root_node]].pack('CCCCV')
        source_references = if @minimal_metadata
                              [nil, nil]
                            else
                              [string_reference(source[:file_name]), string_reference(source[:model_name])]
                            end
        header + bounds.map(&:to_f).pack('E*') + counts.pack('V*') + pack_indices(source_references, string_width)
      end

      def build_materials_section
        string_width = BOMC::Binary.index_width(@strings.length)
        texture_width = BOMC::Binary.index_width(@textures.length)
        materials = @model[:materials]
        bytes = [1, string_width, texture_width, 0, materials.length].pack('CCCCV')
        bytes << pack_indices(materials.map { |material| string_reference(material[:name]) }, string_width)
        bytes << pack_indices(materials.map { |material| string_reference(material[:display_name]) }, string_width)
        bytes << materials.map do |material|
          color = material[:color]
          [clamp_byte(color[:r]), clamp_byte(color[:g]), clamp_byte(color[:b]), clamp_byte(color[:a])]
        end.flatten.pack('C*')
        bytes << materials.map { |material| [[(material[:opacity].to_f * 65_535.0).round, 0].max, 65_535].min }.pack('S<*')
        bytes << pack_indices(materials.map { |material| material[:texture_index] }, texture_width)
        bytes << materials.map { |material| material[:texture] ? material[:texture][:width_m].to_f : 0.0 }.pack('e*')
        bytes << materials.map { |material| material[:texture] ? material[:texture][:height_m].to_f : 0.0 }.pack('e*')
        bytes
      end

      def build_tags_section
        string_width = BOMC::Binary.index_width(@strings.length)
        tags = @model[:tags]
        bytes = [1, string_width, 0, 0, tags.length].pack('CCCCV')
        bytes << pack_indices(tags.map { |tag| string_reference(tag[:name]) }, string_width)
        bytes << pack_bits(tags.map { |tag| tag[:visible] })
        bytes
      end

      def build_geometry
        position_stream = +''.b
        topology_stream = +''.b
        uv_stream = +''.b
        meshes = []
        faces = []
        normals = []
        edges = []
        uv_block_count = 0

        @model[:meshes].each_with_index do |mesh, mesh_index|
          mesh_face_start = faces.length
          mesh_edge_start = edges.length
          loops_for_gate = mesh[:faces].map { |face| [face[:outer]] + face[:holes] }.flatten(1)
          position = BOMC::PositionCodec.encode(mesh[:positions], loops: loops_for_gate)
          position_offset, position_length = append_aligned(position_stream, pack_position_block(position))
          @position_metrics << position.reject { |key, _value| key == :bytes }
          notify(:encode_positions, mesh_index + 1, @model[:meshes].length)

          loop_indices = []
          triangle_indices = []
          mesh_uv_values = []
          mesh[:faces].each do |face|
            loop_lengths = []
            loops = [face[:outer]] + face[:holes]
            loops.each do |loop_indices_for_face|
              loop_lengths << loop_indices_for_face.length
              loop_indices.concat(loop_indices_for_face)
            end
            triangle_indices.concat(face[:triangles])
            front_uv = uv_side_values(face, :front, loop_lengths)
            back_uv = uv_side_values(face, :back, loop_lengths)
            mesh_uv_values.concat(front_uv) if front_uv
            mesh_uv_values.concat(back_uv) if back_uv
            fallback = !classified_surface?(face[:surface_type])
            faces << {
              surface: surface_enum(face[:surface_type]),
              hidden: face[:hidden],
              holes: face[:holes].any?,
              front_uv: !front_uv.nil?,
              back_uv: !back_uv.nil?,
              fallback: fallback,
              role: role_enum(face[:semantic_role]),
              label: string_reference(face[:semantic_label]),
              front_material: face[:front_material],
              back_material: face[:back_material],
              tag: face[:tag],
              loop_count: loops.length,
              loop_lengths: loop_lengths,
              triangle_count: face[:triangles].length,
              stable_id: face[:stable_id],
              persistent_id: face[:persistent_id],
              semantic_source: face[:semantic_source],
              classification_policy: face[:classification_policy]
            }
            normals.concat(face[:normal])
          end
          topology_block = pack_topology_block(loop_indices, triangle_indices)
          topology_offset, topology_length = append_aligned(topology_stream, topology_block)
          @topology_absolute_bytes += (loop_indices.length + triangle_indices.length) * 4
          @topology_encoded_bytes += topology_block.bytesize
          notify(:encode_topology, mesh_index + 1, @model[:meshes].length)

          uv_offset = 0
          uv_length = 0
          unless mesh_uv_values.empty?
            uv = BOMC::UVCodec.encode(mesh_uv_values)
            uv_offset, uv_length = append_aligned(uv_stream, pack_uv_block(uv))
            @uv_metrics << uv.reject { |key, _value| key == :bytes }
            uv_block_count += 1
          end
          notify(:encode_uv, mesh_index + 1, @model[:meshes].length)

          mesh[:edges].each do |edge|
            edges << edge.merge(mesh: mesh_index)
          end
          meshes << {
            definition: mesh[:definition],
            vertex_count: mesh[:positions].length / 3,
            face_start: mesh_face_start,
            face_count: faces.length - mesh_face_start,
            edge_start: mesh_edge_start,
            edge_count: edges.length - mesh_edge_start,
            position_offset: position_offset,
            position_length: position_length,
            topology_offset: topology_offset,
            topology_length: topology_length,
            uv_offset: uv_offset,
            uv_length: uv_length
          }
        end
        {
          meshes: meshes,
          faces: faces,
          normals: normals,
          edges: edges,
          position_bytes: position_stream,
          topology_bytes: topology_stream,
          uv_bytes: uv_stream,
          uv_block_count: uv_block_count
        }
      end

      def build_meshes_section(meshes)
        definition_width = BOMC::Binary.index_width(@model[:definitions].length)
        bytes = [1, definition_width, 0, 0, meshes.length].pack('CCCCV')
        bytes << pack_indices(meshes.map { |mesh| mesh[:definition] }, definition_width)
        keys = [
          :vertex_count, :face_start, :face_count, :edge_start, :edge_count,
          :position_offset, :position_length, :topology_offset, :topology_length,
          :uv_offset, :uv_length
        ]
        keys.each { |key| bytes << meshes.map { |mesh| mesh[key] }.pack('V*') }
        bytes
      end

      def build_faces_section(faces)
        material_width = BOMC::Binary.index_width(@model[:materials].length)
        tag_width = BOMC::Binary.index_width(@model[:tags].length)
        string_width = BOMC::Binary.index_width(@strings.length)
        loop_counts = faces.map { |face| BOMC::Binary.write_varuint(face[:loop_count]) }.join.b
        triangle_counts = faces.map { |face| BOMC::Binary.write_varuint(face[:triangle_count]) }.join.b
        loop_lengths = faces.map { |face| face[:loop_lengths] }.flatten.map { |length| BOMC::Binary.write_varuint(length) }.join.b
        bytes = [
          1, material_width, tag_width, string_width, faces.length,
          faces.map { |face| face[:loop_count] }.inject(0, :+),
          loop_counts.bytesize, triangle_counts.bytesize, loop_lengths.bytesize
        ].pack('CCCCVVVVV')
        bytes << faces.map { |face| face[:surface] }.pack('C*')
        bytes << faces.map { |face| face_flags(face) }.pack('C*')
        bytes << faces.map { |face| face[:role] }.pack('C*')
        bytes << pack_indices(faces.map { |face| face[:front_material] }, material_width)
        bytes << pack_indices(faces.map { |face| face[:back_material] }, material_width)
        bytes << pack_indices(faces.map { |face| face[:tag] }, tag_width)
        bytes << pack_indices(faces.map { |face| face[:label] }, string_width)
        bytes << loop_counts << triangle_counts << loop_lengths
        bytes
      end

      def build_definitions_section
        string_width = BOMC::Binary.index_width(@strings.length)
        mesh_width = BOMC::Binary.index_width(@model[:meshes].length)
        definitions = @model[:definitions]
        bytes = [1, string_width, mesh_width, 0, definitions.length].pack('CCCCV')
        bytes << pack_indices(definitions.map { |definition| string_reference(definition[:name]) }, string_width)
        bytes << definitions.map { |definition| BOMC::DEFINITION_TYPES.fetch(definition[:kind], 0) }.pack('C*')
        bytes << pack_indices(definitions.map { |definition| definition[:mesh] }, mesh_width)
        bytes
      end

      def build_instances_section
        string_width = BOMC::Binary.index_width(@strings.length)
        definition_width = BOMC::Binary.index_width(@model[:definitions].length)
        transform_width = BOMC::Binary.index_width(@model[:transforms].length)
        material_width = BOMC::Binary.index_width(@model[:materials].length)
        tag_width = BOMC::Binary.index_width(@model[:tags].length)
        instances = @model[:instances]
        bytes = [1, string_width, definition_width, transform_width, material_width, tag_width, 0, 0, instances.length].pack('CCCCCCCCV')
        bytes << pack_indices(checkpoint_map(instances, :compile_metadata) { |instance| string_reference(instance[:name]) }, string_width)
        bytes << checkpoint_map(instances, :compile_metadata) { |instance| BOMC::NODE_TYPES.fetch(instance[:kind], 0) }.pack('C*')
        bytes << pack_indices(checkpoint_map(instances, :compile_metadata) { |instance| instance[:owner_definition] }, definition_width)
        bytes << pack_indices(checkpoint_map(instances, :compile_metadata) { |instance| instance[:definition] }, definition_width)
        bytes << pack_indices(checkpoint_map(instances, :compile_metadata) { |instance| instance[:transform] }, transform_width)
        bytes << pack_indices(checkpoint_map(instances, :compile_metadata) { |instance| instance[:material] }, material_width)
        bytes << pack_indices(checkpoint_map(instances, :compile_metadata) { |instance| instance[:tag] }, tag_width)
        bytes << checkpoint_map(instances, :compile_metadata) { |instance| instance_flags(instance) }.pack('C*')
        bytes << checkpoint_map(instances, :compile_metadata) { |instance| role_enum(instance[:semantic_role]) }.pack('C*')
        bytes << pack_indices(checkpoint_map(instances, :compile_metadata) { |instance| string_reference(instance[:semantic_label]) }, string_width)
        bytes
      end

      def checkpoint_map(values, stage)
        values.each_with_index.map do |value, index|
          notify(stage, index + 1, values.length)
          yield(value)
        end
      end

      def build_edges_section(edges)
        tag_width = BOMC::Binary.index_width(@model[:tags].length)
        endpoint_bytes = edges.map do |edge|
          vertices = edge[:vertices]
          raise 'BOMC source invalid: visual edge must have two endpoints.' unless vertices.length == 2
          BOMC::Binary.write_varuint(vertices[0]) + BOMC::Binary.write_varuint(vertices[1])
        end.join.b
        bytes = [1, tag_width, 0, 0, edges.length, endpoint_bytes.bytesize].pack('CCCCVV')
        bytes << pack_indices(edges.map { |edge| edge[:tag] }, tag_width)
        bytes << edges.map { |edge| edge_flags(edge) }.pack('C*')
        bytes << endpoint_bytes
        bytes
      end

      def build_texture_table_section
        bytes = [1, 0, 0, 0, @textures.length].pack('CCCCV')
        bytes << @textures.map { |texture| BOMC::TEXTURE_MEDIA.fetch(texture[:media_type], 0) }.pack('C*')
        bytes << @textures.map { |texture| texture[:image_width_px] }.pack('V*')
        bytes << @textures.map { |texture| texture[:image_height_px] }.pack('V*')
        bytes << @textures.map { |texture| [texture[:sha256]].pack('H*') }.join.b
        bytes << @textures.map { |texture| texture[:blob_offset] }.pack('Q<*')
        bytes << @textures.map { |texture| texture[:blob_length] }.pack('Q<*')
        bytes
      end

      def build_coverage_section
        coverage = @model[:coverage]
        [
          coverage[:eligible], coverage[:analytical], coverage[:visual_retained],
          coverage[:fallback], coverage[:excluded], coverage[:unaccounted]
        ].pack('V6')
      end

      def fallback_records
        @fallback_records ||= @model[:instances].each_with_index.each_with_object([]) do |(instance, index), records|
          records << instance[:fallback].merge(instance: index) if instance[:fallback]
        end
      end

      def build_fallback_section
        records = fallback_records
        instance_width = BOMC::Binary.index_width(@model[:instances].length)
        texture_width = BOMC::Binary.index_width(@textures.length)
        string_width = BOMC::Binary.index_width(@strings.length)
        bytes = [1, instance_width, texture_width, string_width, records.length].pack('CCCCV')
        bytes << pack_indices(records.map { |record| record[:instance] }, instance_width)
        bytes << records.map { |record| BOMC::NODE_TYPES.fetch(record[:kind], 0) }.pack('C*')
        bytes << records.map { |record| Array(record[:position])[0].to_f }.pack('e*')
        bytes << records.map { |record| Array(record[:position])[1].to_f }.pack('e*')
        bytes << records.map { |record| Array(record[:position])[2].to_f }.pack('e*')
        bytes << records.map { |record| record[:width_m].to_f }.pack('e*')
        bytes << records.map { |record| record[:height_m].to_f }.pack('e*')
        bytes << pack_indices(records.map { |record| record[:texture_index] }, texture_width)
        bytes << pack_indices(records.map { |record| string_reference(record[:text]) }, string_width)
        bytes
      end

      def build_scenes_section
        scenes = Array(@model[:scenes])
        tag_count = @model[:tags].length
        tag_bitset_bytes = (tag_count + 7) / 8

        data = [1, tag_count, scenes.length].pack('CCV')

        scenes.each do |scene|
          camera = scene[:camera] || {}
          visibility = scene[:visibility] || {}

          id_idx = @string_index[scene[:stable_id].to_s] || 0
          name_idx = @string_index[scene[:name].to_s] || 0
          desc_idx = @string_index[scene[:description].to_s] || 0
          sig_idx = @string_index[scene[:visibility_signature].to_s] || 0

          flags = 0
          flags |= 0x01 if scene[:is_active_at_export]
          flags |= 0x02 if scene[:use_camera] != false
          flags |= 0x04 if scene[:stores_tag_visibility] != false
          flags |= 0x08 if scene[:stores_hidden_objects] != false
          flags |= 0x10 if scene[:stores_hidden_geometry] == true
          flags |= 0x20 if scene[:stores_section_planes] == true
          flags |= 0x40 if camera[:projection] != 'orthographic'

          eye = Array(camera[:eye_m])
          target = Array(camera[:target_m])
          up = Array(camera[:up])
          fov_or_height = (camera[:projection] == 'orthographic' ? camera[:orthographic_height_m] : camera[:field_of_view_degrees]).to_f
          aspect_ratio = camera[:aspect_ratio].to_f
          trans_time = scene[:transition_time_seconds].to_f

          data << [
            id_idx, name_idx, desc_idx, sig_idx,
            flags,
            eye[0].to_f, eye[1].to_f, eye[2].to_f,
            target[0].to_f, target[1].to_f, target[2].to_f,
            up[0].to_f, up[1].to_f, up[2].to_f,
            fov_or_height, aspect_ratio, trans_time
          ].pack('VVVVVe3e3e3e3')

          visible_tag_indices = Array(visibility[:visible_tag_indices])
          if visible_tag_indices.empty? && Array(visibility[:visible_tag_ids]).empty?
            bitset = Array.new(tag_bitset_bytes, 0xff)
          else
            bitset = Array.new(tag_bitset_bytes, 0)
            visible_tag_indices.each do |idx|
              if idx >= 0 && idx < tag_count
                byte_idx = idx / 8
                bit_idx = idx % 8
                bitset[byte_idx] |= (1 << bit_idx)
              end
            end
          end
          data << bitset.pack('C*')

          hidden_nodes = Array(visibility[:hidden_node_indices])
          visible_nodes = Array(visibility[:visible_node_indices])

          data << BOMC::Binary.write_varuint(hidden_nodes.length)
          hidden_nodes.each { |idx| data << BOMC::Binary.write_varuint(idx) }

          data << BOMC::Binary.write_varuint(visible_nodes.length)
          visible_nodes.each { |idx| data << BOMC::Binary.write_varuint(idx) }
        end

        data
      end

      def debug_records
        return @debug_records if @debug_records
        records = []
        add_debug_records(records, 1, @model[:materials])
        add_debug_records(records, 2, @model[:tags])
        add_debug_records(records, 3, @model[:meshes])
        face_index = 0
        @model[:meshes].each do |mesh|
          mesh[:faces].each do |face|
            add_debug_record_fields(records, 4, face_index, face)
            face_index += 1
          end
        end
        add_debug_records(records, 5, @model[:definitions])
        add_debug_records(records, 6, @model[:instances])
        edge_index = 0
        @model[:meshes].each do |mesh|
          mesh[:edges].each do |edge|
            add_debug_record_fields(records, 7, edge_index, edge)
            edge_index += 1
          end
        end
        @debug_records = records
      end

      def build_debug_section
        records = debug_records
        bytes = [1, 0, 0, 0, records.length].pack('CCCCV')
        records.each do |record|
          bytes << record[0] << record[1]
          bytes << BOMC::Binary.write_varuint(record[2])
          bytes << BOMC::Binary.write_varuint(record[3])
        end
        bytes
      end

      def pack_position_block(block)
        header = [1, block[:codec], 0, 0, block[:count], block[:bytes].bytesize].pack('CCCCVV')
        header + Array(block[:origin]).pack('E*') + Array(block[:scale]).pack('E*') + block[:bytes]
      end

      def pack_uv_block(block)
        header = [1, block[:codec], 0, 0, block[:count], block[:bytes].bytesize].pack('CCCCVV')
        header + Array(block[:origin]).pack('E*') + Array(block[:scale]).pack('E*') + block[:bytes]
      end

      def pack_codec_section(block)
        [1, block[:codec], 0, 0, block[:count], block[:bytes].bytesize].pack('CCCCVV') + block[:bytes]
      end

      def pack_topology_block(loop_indices, triangle_indices)
        loop_bytes = delta_indices(loop_indices)
        triangle_bytes = delta_indices(triangle_indices)
        [1, 0, 0, 0, loop_indices.length, triangle_indices.length, loop_bytes.bytesize, triangle_bytes.bytesize].pack('CCCCVVVV') + loop_bytes + triangle_bytes
      end

      def delta_indices(values)
        previous = 0
        Array(values).map do |value|
          integer = Integer(value)
          delta = integer - previous
          previous = integer
          BOMC::Binary.write_zigzag(delta)
        end.join.b
      end

      def append_aligned(stream, block)
        aligned = BOMC::Binary.align(stream.bytesize)
        stream << ("\0" * (aligned - stream.bytesize)).b
        offset = stream.bytesize
        stream << block
        [offset, block.bytesize]
      end

      def uv_side_values(face, side, loop_lengths)
        uv = face[:uv]
        return nil if uv.nil?
        outer = Array(uv[(side.to_s + '_outer').to_sym])
        holes = Array(uv[(side.to_s + '_holes').to_sym])
        return nil if outer.empty? && holes.empty?
        loops = [outer] + holes
        unless loops.map(&:length) == loop_lengths
          raise "BOMC source invalid: #{side} UV loop lengths do not match topology."
        end
        loops.flatten(1).flatten.map(&:to_f)
      end

      def face_flags(face)
        flags = 0
        flags |= 1 if face[:hidden]
        flags |= 2 if face[:holes]
        flags |= 4 if face[:front_uv]
        flags |= 8 if face[:back_uv]
        flags |= 16 if face[:fallback]
        flags
      end

      def instance_flags(instance)
        flags = 0
        flags |= 1 if instance[:visible]
        flags |= 2 if instance[:classification_policy].to_s == 'geometry_fallback'
        flags
      end

      def edge_flags(edge)
        flags = 0
        flags |= 1 if edge[:hidden]
        flags |= 2 if edge[:soft]
        flags |= 4 if edge[:smooth]
        flags
      end

      def pack_bits(values)
        bytes = Array.new((values.length + 7) / 8, 0)
        values.each_with_index { |value, index| bytes[index / 8] |= 1 << (index % 8) if value }
        bytes.pack('C*')
      end

      def pack_indices(values, width)
        bytes = BOMC::Binary.pack_indices(values, width)
        @adaptive_actual += bytes.bytesize
        @adaptive_u32 += values.length * 4
        bytes
      end

      def string_reference(value)
        return nil if value.nil?
        @string_index.fetch(value.to_s)
      end

      def surface_enum(value)
        normalized = value.to_s.downcase.tr(' ', '_')
        BOMC::SURFACE_TYPES.fetch(normalized, 0)
      end

      def role_enum(value)
        normalized = value.to_s.downcase.tr(' ', '_')
        BOMC::SEMANTIC_ROLES.fetch(normalized, 0)
      end

      def classified_surface?(value)
        surface_enum(value) != 0
      end

      def coordinate_flags(coordinate_system)
        handedness = coordinate_system[:handedness].to_s.downcase == 'left' ? 0 : 1
        axis = coordinate_system[:up_axis].to_s.upcase.delete('+')
        axis_code = { 'X' => 0, 'Y' => 1, 'Z' => 2 }.fetch(axis, 2)
        handedness | (axis_code << 1)
      end

      def clamp_byte(value)
        [[Integer(value), 0].max, 255].min
      end

      def each_debug_string
        collections = [@model[:materials], @model[:tags], @model[:meshes], @model[:definitions], @model[:instances]]
        collections.each do |items|
          items.each do |item|
            yield item[:stable_id]
            yield item[:persistent_id]
            yield item[:semantic_source]
            yield item[:classification_policy]
          end
        end
        @model[:meshes].each do |mesh|
          (mesh[:faces] + mesh[:edges]).each do |item|
            yield item[:stable_id]
            yield item[:persistent_id]
            yield item[:semantic_source]
            yield item[:classification_policy]
          end
        end
      end

      def add_debug_records(records, category, items)
        items.each_with_index { |item, index| add_debug_record_fields(records, category, index, item) }
      end

      def add_debug_record_fields(records, category, row, item)
        fields = [
          [1, item[:stable_id]], [2, item[:persistent_id]],
          [3, item[:semantic_source]], [4, item[:classification_policy]]
        ]
        fields.each do |field, value|
          next if value.nil? || value.to_s.empty?
          records << [category, field, row, @string_index.fetch(value.to_s)]
        end
      end
    end
  end
end
