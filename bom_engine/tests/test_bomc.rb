# Run with standalone Ruby:
#   ruby bom_engine/tests/test_bomc.rb

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../bomc_format'
require_relative '../bomc_codecs'
require_relative '../bomc_model_adapter'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'

module BOMEngine
  module Tests
    module BOMCTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition

        puts "PASS: #{message}"
      end

      def assert_raises(message, expected_text = nil)
        error = nil
        begin
          yield
        rescue StandardError => caught
          error = caught
        end
        assert(!error.nil?, message)
        if expected_text
          assert(error.message.include?(expected_text), "#{message} reports #{expected_text}")
        end
      end

      def run
        test_varints
        test_adaptive_indices
        test_container
        test_position_codecs
        test_normal_codec
        test_uv_codecs
        test_transform_codecs
        test_compiled_round_trip
        test_model_eval_adapter
        test_differential_validation
        test_shared_definition_scaling
        puts 'BOMC Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def test_varints
        values = [0, 1, 127, 128, 255, 16_384, 4_294_967_295]
        bytes = values.map { |value| BOMC::Binary.write_varuint(value) }.join.b
        offset = 0
        decoded = values.map do
          value, offset = BOMC::Binary.read_varuint(bytes, offset)
          value
        end
        assert(decoded == values, 'unsigned varints round-trip boundary values')
        assert(offset == bytes.bytesize, 'varint reader consumes exactly the encoded bytes')

        signed = [-2_147_483_648, -2, -1, 0, 1, 2, 2_147_483_647]
        signed_bytes = signed.map { |value| BOMC::Binary.write_zigzag(value) }.join.b
        offset = 0
        signed_decoded = signed.map do
          value, offset = BOMC::Binary.read_zigzag(signed_bytes, offset)
          value
        end
        assert(signed_decoded == signed, 'zigzag varints preserve signed deltas')
        assert_raises('truncated varint is rejected', 'truncated varint') do
          BOMC::Binary.read_varuint("\x80".b, 0)
        end
      end

      def test_adaptive_indices
        assert(BOMC::Binary.index_width(255) == 1, 'uint8 index width includes a sentinel at count 255')
        assert(BOMC::Binary.index_width(256) == 2, 'uint16 index width starts at count 256')
        assert(BOMC::Binary.index_width(65_535) == 2, 'uint16 index width includes a sentinel at count 65535')
        assert(BOMC::Binary.index_width(65_536) == 4, 'uint32 index width starts at count 65536')

        values = [0, 7, nil, 254]
        bytes = BOMC::Binary.pack_indices(values, 1)
        assert(bytes.bytesize == 4, 'adaptive uint8 indices use one byte per row')
        assert(BOMC::Binary.unpack_indices(bytes, 1, values.length) == values, 'adaptive index sentinel decodes as nil')
        assert_raises('out-of-range adaptive index is rejected', 'does not fit') do
          BOMC::Binary.pack_indices([255], 1)
        end
      end

      def test_container
        sections = [
          { type: 65_000, count: 1, bytes: 'future section'.b, compress: false },
          { type: BOMC::SECTION_STRINGS, count: 3, bytes: ('abc' * 200).b, compress: true }
        ]
        bytes = BOMC::Container.pack(sections, flags: BOMC::PROFILE_PRODUCTION)
        second = BOMC::Container.pack(sections, flags: BOMC::PROFILE_PRODUCTION)
        parsed = BOMC::Container.parse(bytes)
        directory_only = BOMC::Container.read_directory(bytes)

        assert(bytes.byteslice(0, 8) == "BOMC\r\n\x1a\n".b, 'BOMC magic is explicit')
        assert(parsed[:header][:major] == 1 && parsed[:header][:minor] == 0, 'BOMC container version is 1.0')
        assert(parsed[:header][:header_bytes] == 32, 'fixed header is 32 bytes')
        assert(parsed[:header][:directory_entry_bytes] == 40, 'directory entry is 40 bytes')
        assert(parsed[:header][:endianness] == :little, 'endianness marker is little-endian')
        assert(parsed[:header][:flags] == BOMC::PROFILE_PRODUCTION, 'profile flags survive')
        assert(!directory_only[:sections][0].key?(:bytes), 'directory-only parse does not decompress section payloads')
        assert(directory_only[:sections].map { |section| section[:type] } == parsed[:sections].map { |section| section[:type] }, 'directory-only parse exposes random-access descriptors')
        assert(parsed[:sections].map { |section| section[:type] } == [BOMC::SECTION_STRINGS, 65_000], 'section order is numeric and unknown types are skippable')
        assert(parsed[:sections].all? { |section| (section[:offset] % 8).zero? }, 'section payloads use eight-byte alignment')
        assert(parsed[:sections][0][:bytes] == ('abc' * 200).b, 'DEFLATE section decodes independently')
        assert(parsed[:sections][1][:bytes] == 'future section'.b, 'STORE section decodes independently')
        assert(Digest::SHA256.hexdigest(bytes) == Digest::SHA256.hexdigest(second), 'container bytes are deterministic')

        corrupt = bytes.dup
        stored_section = parsed[:sections].last
        corrupt.setbyte(stored_section[:offset], corrupt.getbyte(stored_section[:offset]) ^ 0xff)
        assert_raises('corrupt section checksum is rejected', 'checksum') do
          BOMC::Container.parse(corrupt)
        end

        bad_bounds = bytes.dup
        first_directory = parsed[:header][:directory_offset]
        bad_bounds[first_directory + 4, 8] = [bytes.bytesize + 8].pack('Q<')
        assert_raises('out-of-file section bounds are rejected', 'outside file') do
          BOMC::Container.parse(bad_bounds, verify_checksums: false)
        end

        bad_overlap = bytes.dup
        second_directory = first_directory + BOMC::DIRECTORY_ENTRY_BYTES
        bad_overlap[second_directory + 4, 8] = [parsed[:sections][0][:offset]].pack('Q<')
        assert_raises('overlapping sections are rejected', 'overlap') do
          BOMC::Container.parse(bad_overlap, verify_checksums: false)
        end
      end

      def test_position_codecs
        positions = [
          10_000.0, -20_000.0, 100.0,
          10_012.345_678, -20_000.0, 100.0,
          10_012.345_678, -19_993.456_789, 100.125,
          10_000.0, -19_993.456_789, 100.125,
          10_002.0, -19_998.0, 100.02,
          10_002.0, -19_996.0, 100.02,
          10_004.0, -19_996.0, 100.02,
          10_004.0, -19_998.0, 100.02
        ]
        loops = [[0, 1, 2, 3], [4, 5, 6, 7]]
        encoded = BOMC::PositionCodec.encode(positions, loops: loops)
        decoded = BOMC::PositionCodec.decode(encoded)
        errors = point_errors(positions, decoded)
        names = encoded[:candidates].map { |candidate| candidate[:name] }

        assert(names == %w[float64_absolute float32_local int32_quantized int16_quantized delta_varint], 'all required position candidates are benchmarked')
        assert(errors.max <= 0.001, 'selected position codec stays within one millimetre')
        assert((encoded[:errors][:max] - errors.max).abs <= 1.0e-12, 'position maximum error is measured')
        assert(encoded[:errors][:p95] <= encoded[:errors][:max], 'position p95 error is bounded by maximum')
        assert(encoded[:errors][:rms] <= encoded[:errors][:max], 'position RMS error is bounded by maximum')
        assert(encoded[:area_max_error_m2] <= 0.001, 'position codec passes polygon area gate')
        assert(BOMC::PositionCodec.encode(positions, loops: loops)[:bytes] == encoded[:bytes], 'position codec selection is deterministic')
      end

      def test_normal_codec
        normals = [0.0, 0.0, 1.0, 0.577_350_269, -0.577_350_269, 0.577_350_269, -0.25, 0.5, -0.829_156_198, 0.0, 0.0, 0.0]
        encoded = BOMC::NormalCodec.encode(normals)
        decoded = BOMC::NormalCodec.decode(encoded)
        angles = angular_errors(normals, decoded)
        assert(encoded[:codec] == BOMC::NormalCodec::OCT16, 'octahedral 2xInt16 normals pass the gate')
        assert(encoded[:bytes].bytesize == 16, 'octahedral normals use four bytes per vector')
        assert(angles.max <= 0.1, 'normal angular error stays within 0.1 degree')
        assert((encoded[:errors][:max] - angles.max).abs <= 1.0e-9, 'normal maximum angular error is measured')
        assert(decoded[-3, 3] == [0.0, 0.0, 0.0], 'octahedral zero sentinel preserves degenerate normal')
      end

      def test_uv_codecs
        uv = [-2.5, 3.25, 4.75, -0.125, 1.0, 1.0, -8.125, 12.5]
        encoded = BOMC::UVCodec.encode(uv)
        decoded = BOMC::UVCodec.decode(encoded)
        errors = pair_errors(uv, decoded)
        names = encoded[:candidates].map { |candidate| candidate[:name] }
        assert(names == %w[float32 float16 int16_quantized delta_varint float64], 'all required UV candidates are benchmarked')
        assert(decoded[0] < 0.0 && decoded[6] < 0.0, 'negative UV values are preserved')
        assert(decoded[2] > 1.0 && decoded[7] > 1.0, 'UV values greater than one are preserved')
        assert(errors.max <= 1.0e-4, 'selected UV codec stays within its numeric gate')
        assert((encoded[:errors][:max] - errors.max).abs <= 1.0e-12, 'UV maximum error is measured')
      end

      def test_transform_codecs
        identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        mirror_non_uniform = [-2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0.5, 0, 7, -4, 2, 1]
        theta = Math::PI / 7.0
        rotated = [
          Math.cos(theta), Math.sin(theta), 0, 0,
          -Math.sin(theta), Math.cos(theta), 0, 0,
          0, 0, 1, 0,
          1.25, 2.5, -3.75, 1
        ]
        transforms = [identity, mirror_non_uniform, rotated]
        encoded = BOMC::TransformCodec.encode(transforms)
        decoded = BOMC::TransformCodec.decode(encoded)
        max_error = transforms.each_with_index.map { |matrix, index| max_delta(matrix, decoded[index]) }.max
        names = encoded[:candidates].map { |candidate| candidate[:name] }

        assert(names == %w[float64_3x4 float32_3x4 decomposed_float32 decomposed_quantized hybrid], 'all required transform candidates are benchmarked')
        assert(max_error <= 1.0e-5, 'transform matrix error stays within gate')
        assert(decoded[1][0] < 0.0 && decoded[1][5] > 0.0, 'mirror and non-uniform scale survive')
        assert((encoded[:errors][:max] - max_error).abs <= 1.0e-12, 'transform maximum error is measured')

        shear = identity.dup
        shear[4] = 0.25
        shear_encoded = BOMC::TransformCodec.encode([shear])
        assert([BOMC::TransformCodec::FLOAT64_3X4, BOMC::TransformCodec::FLOAT32_3X4, BOMC::TransformCodec::HYBRID].include?(shear_encoded[:codec]), 'shear rejects decomposed-only representation')
        assert(max_delta(shear, BOMC::TransformCodec.decode(shear_encoded)[0]) <= 1.0e-5, 'shear transform is preserved by affine fallback')
      end

      def point_errors(source, decoded)
        source.each_slice(3).with_index.map do |point, index|
          offset = index * 3
          Math.sqrt(3.times.map { |axis| (point[axis].to_f - decoded[offset + axis].to_f)**2 }.inject(0.0, :+))
        end
      end

      def pair_errors(source, decoded)
        source.each_slice(2).with_index.map do |pair, index|
          offset = index * 2
          Math.sqrt(2.times.map { |axis| (pair[axis].to_f - decoded[offset + axis].to_f)**2 }.inject(0.0, :+))
        end
      end

      def angular_errors(source, decoded)
        source.each_slice(3).with_index.map do |normal, index|
          offset = index * 3
          decoded_normal = decoded[offset, 3]
          a_length = vector_length(normal)
          b_length = vector_length(decoded_normal)
          next 0.0 if a_length.zero? && b_length.zero?
          next 180.0 if a_length.zero? || b_length.zero?
          a = normal.map { |value| value.to_f / a_length }
          b = decoded_normal.map { |value| value.to_f / b_length }
          dot = 3.times.map { |axis| a[axis] * b[axis] }.inject(0.0, :+)
          Math.acos([[dot, -1.0].max, 1.0].min) * 180.0 / Math::PI
        end
      end

      def normalize(vector)
        length = vector_length(vector)
        vector.map { |value| value.to_f / length }
      end

      def vector_length(vector)
        Math.sqrt(vector.map { |value| value.to_f * value.to_f }.inject(0.0, :+))
      end

      def max_delta(left, right)
        left.each_with_index.map { |value, index| (value.to_f - right[index].to_f).abs }.max
      end

      def test_compiled_round_trip
        graph = compiled_fixture
        production = BOMCWriter.pack(graph, profile: :production)
        production_again = BOMCWriter.pack(graph, profile: :production)
        debug = BOMCWriter.pack(graph, profile: :debug)
        parsed = BOMC::Container.parse(production[:bytes])
        decoded = BOMCDecoder.decode(production[:bytes])
        decoded_debug = BOMCDecoder.decode(debug[:bytes])
        section_types = parsed[:sections].map { |section| section[:type] }

        assert(section_types.include?(BOMC::SECTION_MODEL), 'compiled model section exists')
        assert(section_types.include?(BOMC::SECTION_POSITIONS), 'independent position stream exists')
        assert(section_types.include?(BOMC::SECTION_TOPOLOGY), 'independent topology stream exists')
        assert(section_types.include?(BOMC::SECTION_NORMALS), 'independent normal stream exists')
        assert(section_types.include?(BOMC::SECTION_UVS), 'independent UV stream exists')
        assert(section_types.include?(BOMC::SECTION_VISUAL_EDGES), 'independent visual edge stream exists')
        assert(section_types.include?(BOMC::SECTION_FALLBACK), 'independent fallback stream exists')
        assert(section_types.include?(BOMC::SECTION_TEXTURE_BLOBS), 'texture blobs are inside the container')
        assert(!section_types.include?(BOMC::SECTION_DEBUG), 'production omits debug mappings')
        assert(BOMC::Container.parse(debug[:bytes])[:sections].any? { |section| section[:type] == BOMC::SECTION_DEBUG }, 'debug profile includes binary mappings')
        assert(!production[:bytes].include?('classification_policy'), 'production contains no provenance key strings')
        assert(!production[:bytes].include?('surface-fixture-1'), 'production omits stable surface IDs')
        assert(decoded_debug[:debug].values.flatten.include?('surface-fixture-1'), 'debug preserves stable surface IDs')

        assert(decoded[:materials].length == 2, 'material table count round-trips')
        assert(decoded[:tags].length == 1, 'tag table count round-trips')
        assert(decoded[:meshes].length == 1, 'shared mesh is emitted once')
        assert(decoded[:definitions].length == 3, 'nested definitions round-trip')
        assert(decoded[:instances].length == 5, 'instance hierarchy and fallback nodes round-trip')
        assert(decoded[:fallback].map { |row| row[:kind] } == %w[image text], 'image and text fallback kinds round-trip')
        assert(decoded[:fallback][0][:position] == [2.0, 1.0, 0.5], 'image fallback placement round-trips')
        assert(decoded[:fallback][0][:width_m] == 1.5 && decoded[:fallback][0][:height_m] == 0.75, 'image fallback dimensions round-trip')
        assert(decoded[:fallback][0][:texture] == 0, 'image fallback references embedded deduplicated resource')
        assert(decoded[:fallback][1][:text] == 'Room annotation', 'text fallback payload round-trips')
        assert(decoded[:textures].length == 1, 'identical material and image resource bytes are deduplicated')
        assert(decoded[:textures][0][:bytes] == graph[:materials][0][:texture][:bytes], 'embedded texture bytes round-trip')
        assert(decoded[:materials][0][:texture] == decoded[:materials][1][:texture], 'materials reference the same texture index')
        assert(decoded[:meshes][0][:faces][0][:holes] == [[4, 5, 6, 7]], 'face holes round-trip exactly')
        assert(decoded[:meshes][0][:faces][0][:triangles] == graph[:meshes][0][:faces][0][:triangles], 'triangle winding and indices round-trip exactly')
        assert(decoded[:meshes][0][:faces][0][:uv][:front_outer][0][0] < 0.0, 'negative face UV survives compiled round-trip')
        assert(decoded[:meshes][0][:faces][0][:uv][:front_outer][1][0] > 1.0, 'repeating face UV greater than one survives')
        assert(decoded[:meshes][0][:edges][0][:vertices] == [0, 1], 'visual edge endpoints round-trip')
        assert(decoded[:meshes][0][:edges][0][:soft] && !decoded[:meshes][0][:edges][0][:smooth], 'visual edge flags round-trip')
        assert(decoded[:coverage][:unaccounted] == 0, 'compiled geometry completeness has no unaccounted faces')
        assert(production[:metrics][:textures][:deduplicated] == 2, 'material and image texture deduplication savings are reported')
        assert(production[:metrics][:adaptive_indices][:saved_bytes] > 0, 'adaptive index-width savings are reported')
        assert(production[:metrics][:topology][:saved_bytes] > 0, 'topology varint savings are reported')
        assert(Digest::SHA256.hexdigest(production[:bytes]) == Digest::SHA256.hexdigest(production_again[:bytes]), 'compiled output is deterministic')

        output_dir = Dir.mktmpdir('bomc-writer')
        begin
          path = File.join(output_dir, 'fixture.bomc')
          written = BOMCWriter.write(path, graph, profile: :production)
          assert(File.binread(path) == production[:bytes], 'atomic writer publishes exact compiled bytes')
          assert(written[:bytes] == File.size(path), 'compiled writer reports file bytes')
          assert(written[:sha256] == Digest::SHA256.file(path).hexdigest, 'compiled writer reports file SHA256')
          assert(Dir.glob(File.join(output_dir, '*.part')).empty?, 'atomic writer leaves no partial file')
        ensure
          FileUtils.remove_entry(output_dir) if output_dir && Dir.exist?(output_dir)
        end
      end

      def test_model_eval_adapter
        path = File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)
        payload = JSON.parse(File.read(path), symbolize_names: true)
        adapted = BOMC::ModelAdapter.from_model_eval(payload, base_path: File.dirname(path))
        compiled = BOMCWriter.pack(payload, profile: :production, base_path: File.dirname(path))
        decoded = BOMCDecoder.decode(compiled[:bytes])
        assert(adapted[:meshes].length == payload[:meshes].length, 'existing Model-Eval JSON adapts without SketchUp')
        assert(adapted[:definitions][0][:kind] == 'model_definition', 'legacy root definition normalizes to the BOMC definition vocabulary')
        assert(decoded[:meshes].length == payload[:meshes].length, 'adapted Model-Eval JSON compiles and decodes')
        assert(decoded[:coverage][:unaccounted] == 0, 'adapted Model-Eval JSON has complete disposition')
        assert(BOMCValidator.validate!(payload, decoded)[:definitions][:exact], 'legacy Model-Eval definitions pass differential validation')
        profiled = BOMCDecoder.profile(compiled[:bytes])
        assert(profiled[:model][:meshes].length == decoded[:meshes].length, 'profiled reference decode returns the same logical model')
        assert([:container_ms, :metadata_ms, :analytical_ms, :visual_ms, :texture_ms, :validation_ms, :logical_decode_ms, :total_ms].all? { |key| profiled[:timings][key].is_a?(Numeric) }, 'reference decoder reports stage timings')
      end

      def test_differential_validation
        graph = compiled_fixture
        result = BOMCWriter.pack(graph, profile: :production)
        decoded = BOMCDecoder.decode(result[:bytes])
        comparison = BOMCValidator.validate!(graph, decoded)
        assert(comparison[:counts][:exact], 'differential table counts are exact')
        assert(comparison[:materials][:exact], 'differential material columns are exact within opacity quantization')
        assert(comparison[:tags][:exact], 'differential tag columns are exact')
        assert(comparison[:definitions][:exact], 'differential shared definition columns are exact')
        assert(comparison[:instances][:exact], 'differential instance hierarchy and semantics are exact')
        assert(comparison[:fallback][:exact], 'differential image/text fallback records are exact')
        assert(comparison[:topology][:exact], 'differential topology, holes, and winding are exact')
        assert(comparison[:positions][:max_error_m] <= 0.001, 'differential positions stay within one millimetre')
        assert(comparison[:positions][:p95_error_m] <= comparison[:positions][:max_error_m], 'differential position p95 is reported')
        assert(comparison[:positions][:rms_error_m] <= comparison[:positions][:max_error_m], 'differential position RMS is reported')
        assert(comparison[:normals][:max_angular_error_deg] <= 0.1, 'differential normals stay within angular gate')
        assert(comparison[:uv][:max_error] <= 1.0e-4, 'differential UV stays within numeric gate')
        assert(comparison[:transforms][:max_error] <= 1.0e-5, 'differential transforms stay within matrix gate')
        assert(comparison[:areas][:max_error_m2] <= 0.011, 'differential area stays within 0.1 percent gate')
        assert(comparison[:visual_edges][:exact], 'differential visual edges are exact')
        assert(comparison[:textures][:exact], 'differential texture content hashes are exact')
        assert(comparison[:coverage][:unaccounted] == 0, 'differential coverage has no unaccounted geometry')
      end

      def test_shared_definition_scaling
        scales = [1, 10, 100, 1_000, 10_000]
        rows = scales.map do |count|
          result = BOMCWriter.pack(shared_definition_fixture(count), profile: :production)
          geometry_bytes = [:positions, :topology, :normals, :uv, :visual_edges].map do |name|
            result[:metrics][:sections].fetch(name)[:stored_bytes]
          end.inject(0, :+)
          decoded = BOMCDecoder.decode(result[:bytes])
          assert(decoded[:instances].length == count + 1, "#{count} shared instances decode without expansion")
          { count: count, total_bytes: result[:bytes].bytesize, geometry_bytes: geometry_bytes }
        end
        assert(rows.map { |row| row[:geometry_bytes] }.uniq.length == 1, 'geometry payload remains constant from 1 to 10,000 instances')
        assert(rows[-1][:total_bytes] < rows[0][:total_bytes] + rows[-1][:count] * 64, 'instance growth remains compact and linear')
      end

      def compiled_fixture
        texture_bytes = "\x89PNG\r\n\x1a\nBOMC deterministic texture".b
        positions = [
          0, 0, 0, 4, 0, 0, 4, 3, 0, 0, 3, 0,
          1, 1, 0, 1, 2, 0, 2, 2, 0, 2, 1, 0
        ]
        triangles = [
          0, 1, 7, 0, 7, 4,
          1, 2, 6, 1, 6, 7,
          2, 3, 5, 2, 5, 6,
          3, 0, 4, 3, 4, 5
        ]
        {
          format: { name: 'BOM Engine Canonical', version: '3.0.0' },
          source: { file_name: 'fixture.skp', model_name: 'BOMC Fixture', scope: 'model', exported_at: '2026-08-13T00:00:00Z' },
          coordinate_system: { units: 'm', handedness: 'right', up_axis: 'Z' },
          materials: [
            {
              id: 'material-fixture-1', name: 'Brick', display_name: 'Brick',
              color: { r: 170, g: 80, b: 40, a: 255 }, opacity: 1.0,
              texture: { bytes: texture_bytes, filename: 'brick-a.png', image_width_px: 4, image_height_px: 4, width_m: 1.0, height_m: 1.0 }
            },
            {
              id: 'material-fixture-2', name: 'Brick duplicate', display_name: 'Brick duplicate',
              color: { r: 170, g: 80, b: 40, a: 255 }, opacity: 0.75,
              texture: { bytes: texture_bytes.dup, filename: 'brick-b.png', image_width_px: 4, image_height_px: 4, width_m: 1.0, height_m: 1.0 }
            }
          ],
          tags: [{ id: 'tag-fixture-1', name: 'Architecture', visible: true }],
          transforms: [
            [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            [-1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0.5, 0, 10, 0, 0, 1],
            [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 5, 0, 1]
          ],
          meshes: [{
            id: 'mesh-fixture-1', definition_id: 'definition-panel', positions_m: positions,
            faces: [{
              id: 'surface-fixture-1', source_identity: { persistent_id: 'face-pid-1' },
              outer: [0, 1, 2, 3], holes: [[4, 5, 6, 7]], triangles: triangles,
              front_material_id: 'material-fixture-1', back_material_id: 'material-fixture-2', tag_id: 'tag-fixture-1',
              normal: [0, 0, 1], area_m2: 11.0, surface_hint: 'floor', hidden: false,
              semantic: { label: 'Main Floor', role: 'floor', source: 'instance_name', classification_policy: 'label_first' },
              uv: {
                front_outer: [[-0.5, 0.0], [2.5, 0.0], [2.5, 1.5], [-0.5, 1.5]],
                front_holes: [[[0.25, 0.25], [0.25, 0.75], [0.75, 0.75], [0.75, 0.25]]],
                back_outer: [[-0.5, 0.0], [2.5, 0.0], [2.5, 1.5], [-0.5, 1.5]],
                back_holes: [[[0.25, 0.25], [0.25, 0.75], [0.75, 0.75], [0.75, 0.25]]]
              }
            }],
            edges: [{ id: 'edge-fixture-1', vertices: [0, 1], soft: true, smooth: false }]
          }],
          definitions: [
            { id: 'definition-root', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: ['node-panel', 'node-image', 'node-text'] },
            { id: 'definition-panel', name: 'Panel', kind: 'component_definition', mesh_id: 'mesh-fixture-1', node_ids: ['node-nested'] },
            { id: 'definition-nested', name: 'Nested Detail', kind: 'component_definition', mesh_id: nil, node_ids: [] }
          ],
          nodes: [
            { id: 'node-root', kind: 'root', name: 'Model Root', owner_definition_id: nil, definition_id: 'definition-root', transform_id: 0, visible: true, source_identity: { persistent_id: 'root-pid' } },
            { id: 'node-panel', kind: 'component_instance', name: 'Panel 1', owner_definition_id: 'definition-root', definition_id: 'definition-panel', transform_id: 1, material_override_id: nil, tag_id: 'tag-fixture-1', visible: true, source_identity: { persistent_id: 'panel-pid' }, semantic: { label: 'Facade Panel', role: 'facade', source: 'instance_name', classification_policy: 'label_first' } },
            { id: 'node-nested', kind: 'component_instance', name: 'Nested Detail 1', owner_definition_id: 'definition-panel', definition_id: 'definition-nested', transform_id: 2, material_override_id: 'material-fixture-2', tag_id: 'tag-fixture-1', visible: true, source_identity: { persistent_id: 'nested-pid' }, semantic: { label: nil, role: nil, source: 'none', classification_policy: 'geometry_fallback' } },
            { id: 'node-image', kind: 'image', name: 'Facade Reference', owner_definition_id: 'definition-root', definition_id: nil, transform_id: 0, material_override_id: nil, tag_id: 'tag-fixture-1', visible: true, image: { filename: 'facade.png', bytes: texture_bytes.dup, width_m: 1.5, height_m: 0.75, position: [2.0, 1.0, 0.5], image_width_px: 4, image_height_px: 4 } },
            { id: 'node-text', kind: 'text', name: 'Room annotation', owner_definition_id: 'definition-root', definition_id: nil, transform_id: 0, material_override_id: nil, tag_id: 'tag-fixture-1', visible: true, text: 'Room annotation', attachment: { target_persistent_id: 'panel-pid' } }
          ]
        }
      end


      def shared_definition_fixture(instance_count)
        graph = compiled_fixture
        graph[:materials] = []
        graph[:meshes][0][:faces][0][:front_material_id] = nil
        graph[:meshes][0][:faces][0][:back_material_id] = nil
        graph[:definitions] = [
          { id: 'definition-root', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] },
          { id: 'definition-panel', name: 'Panel', kind: 'component_definition', mesh_id: 'mesh-fixture-1', node_ids: [] }
        ]
        graph[:transforms] = [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]]
        graph[:nodes] = [{
          id: 'node-root', kind: 'root', name: 'Model Root', owner_definition_id: nil,
          definition_id: 'definition-root', transform_id: 0, visible: true
        }]
        instance_count.times do |index|
          transform = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, index.to_f, 0, 0, 1]
          graph[:transforms] << transform
          id = "node-panel-#{index}"
          graph[:nodes] << {
            id: id, kind: 'component_instance', name: 'Panel', owner_definition_id: 'definition-root',
            definition_id: 'definition-panel', transform_id: index + 1, visible: true
          }
          graph[:definitions][0][:node_ids] << id
        end
        graph
      end
    end
  end
end

exit(BOMEngine::Tests::BOMCTest.run ? 0 : 1)
