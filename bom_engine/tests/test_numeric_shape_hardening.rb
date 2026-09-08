# Run with standalone Ruby:
#   ruby bom_engine/tests/test_numeric_shape_hardening.rb

require_relative '../bomc_model_adapter'
require_relative '../scene_clip_program'

module BOMEngine
  module Tests
    module NumericShapeHardeningTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def assert_raises(message, expected_text)
        error = nil
        begin
          yield
        rescue StandardError => caught
          error = caught
        end
        assert(!error.nil?, message)
        assert(error.message.include?(expected_text), "#{message} reports #{expected_text.inspect}; got #{error.message.inspect}")
        error
      end

      def canonical_graph(position_payload: nil, normal_payload: nil, uv_payload: nil)
        positions = position_payload || [
          0.0, 0.0, 0.0,
          1.0, 0.0, 0.0,
          0.0, 1.0, 0.0
        ]
        normal = normal_payload || [0.0, 0.0, 1.0]
        uv = uv_payload || {
          front_outer: [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]],
          front_holes: []
        }
        {
          format: { name: 'BOM Engine Canonical', version: '3.0.0' },
          source: { file_name: 'hardening.skp', scope: 'all_scenes' },
          coordinate_system: {},
          materials: [
            {
              id: 'material:1', name: 'Mapped', display_name: 'Mapped',
              color: { r: 255, g: 255, b: 255, a: 255 }, opacity: 1.0,
              texture: {
                bytes: 'texture'.b, filename: 'fixture.png',
                image_width_px: 1, image_height_px: 1,
                width_m: 1.0, height_m: 1.0
              }
            }
          ],
          tags: [],
          transforms: [[1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]],
          meshes: [
            {
              id: 'mesh:def:root', definition_id: 'def:root', positions_m: positions,
              faces: [
                {
                  id: 'face:1', outer: [0, 1, 2], holes: [], triangles: [0, 1, 2],
                  front_material_id: 'material:1', back_material_id: nil,
                  normal: normal, area_m2: 0.5, surface_hint: 'wall', hidden: false,
                  uv: uv
                }
              ],
              edges: []
            }
          ],
          definitions: [
            { id: 'def:root', name: 'Root', kind: 'root', mesh_id: 'mesh:def:root', node_ids: [] }
          ],
          nodes: [
            {
              id: 'node:root', kind: 'root', name: 'Root', owner_definition_id: nil,
              definition_id: 'def:root', transform_id: 0, material_override_id: nil,
              tag_id: nil, visible: true
            }
          ],
          scenes: [],
          clip_planes: []
        }
      end

      def test_structured_xyz_hashes_are_normalized_without_array_pair_to_f
        graph = canonical_graph(
          position_payload: [
            { x: 0.0, y: 0.0, z: 0.0 },
            { x: 1.0, y: 0.0, z: 0.0 },
            { x: 0.0, y: 1.0, z: 0.0 }
          ],
          normal_payload: { x: 0.0, y: 0.0, z: 1.0 },
          uv_payload: {
            front_outer: [
              { x: 0.0, y: 0.0 },
              { x: 1.0, y: 0.0 },
              { x: 0.0, y: 1.0 }
            ],
            front_holes: []
          }
        )

        normalized = BOMC::ModelAdapter.normalize(graph)
        mesh = normalized[:meshes].first
        face = mesh[:faces].first
        assert(mesh[:positions] == [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0], 'structured XYZ hashes normalize to flat positions')
        assert(face[:normal] == [0.0, 0.0, 1.0], 'structured XYZ normal hash normalizes to vec3')
        assert(face.dig(:uv, :front_outer) == [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]], 'structured XY UV hashes normalize to vec2 pairs')
      end

      def test_clip_plane_accepts_structured_xyz_hashes
        plane = SceneClipProgram.create_plane(
          stable_id: 'section:1', source_persistent_id: '1',
          origin_m: { x: 0.0, y: 0.421, z: 2.0 },
          normal: { x: 1.0, y: 0.0, z: 0.0 }
        )
        assert(plane[:origin_m] == [0.0, 0.421, 2.0], 'clip plane origin hash normalizes to vec3')
        assert(plane[:normal] == [1.0, 0.0, 0.0], 'clip plane normal hash normalizes to vec3')
      end

      def test_invalid_numeric_shape_reports_field_path_instead_of_naked_no_method_error
        graph = canonical_graph(position_payload: [0.0, [:x, 0.421], 0.0])
        error = assert_raises('invalid positions fail with contextual path', 'meshes[0].positions_m') do
          BOMC::ModelAdapter.normalize(graph)
        end
        assert(!error.message.include?("undefined method `to_f'"), 'invalid numeric shape does not leak raw Ruby NoMethodError')
      end

      def test_scalar_strictness_and_non_finite_rejection
        assert_raises('rejects non-numeric string', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar('not-a-number', path: 'test.field')
        end
        assert_raises('rejects mixed garbage string', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar('1.2garbage', path: 'test.field')
        end
        assert_raises('rejects Float::NAN', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar(Float::NAN, path: 'test.field')
        end
        assert_raises('rejects NaN string', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar('NaN', path: 'test.field')
        end
        assert_raises('rejects Float::INFINITY', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar(Float::INFINITY, path: 'test.field')
        end
        assert_raises('rejects -Float::INFINITY', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar(-Float::INFINITY, path: 'test.field')
        end
        assert_raises('rejects nil', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar(nil, path: 'test.field')
        end
        assert_raises('rejects boolean', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar(true, path: 'test.field')
        end
        assert_raises('rejects symbol', 'BOMC numeric shape invalid at test.field') do
          NumericShape.scalar(:sym, path: 'test.field')
        end

        assert(NumericShape.scalar(42, path: 'test.field') == 42.0, 'integer parses to float')
        assert(NumericShape.scalar('3.14159', path: 'test.field') == 3.14159, 'clean numeric string parses')
      end

      class MockSketchupLength
        def initialize(inches)
          @inches = inches
        end

        def to_f
          @inches * 0.0254
        end
      end

      def test_sketchup_length_support
        len = MockSketchupLength.new(100.0)
        result = NumericShape.scalar(len, path: 'test.length')
        assert((result - 2.54).abs < 1e-6, 'MockSketchupLength converts to meter float')

        coords = NumericShape.vec3([len, len, len], path: 'test.vec3')
        assert(coords.all? { |c| (c - 2.54).abs < 1e-6 }, 'vec3 accepts length objects')
      end

      def test_optional_vectors
        assert(NumericShape.optional_vec2(nil, path: 'test.uv').nil?, 'optional_vec2 preserves nil')
        assert(NumericShape.optional_vec3(nil, path: 'test.normal').nil?, 'optional_vec3 preserves nil')
        assert(NumericShape.optional_vec2([1.0, 2.0], path: 'test.uv') == [1.0, 2.0], 'optional_vec2 parses valid vec2')
        assert(NumericShape.optional_vec3([1.0, 2.0, 3.0], path: 'test.pos') == [1.0, 2.0, 3.0], 'optional_vec3 parses valid vec3')
        assert_raises('optional_vec2 validates invalid content', 'BOMC numeric shape invalid') do
          NumericShape.optional_vec2([1.0, 'bad'], path: 'test.uv')
        end
      end

      def run
        test_structured_xyz_hashes_are_normalized_without_array_pair_to_f
        test_clip_plane_accepts_structured_xyz_hashes
        test_invalid_numeric_shape_reports_field_path_instead_of_naked_no_method_error
        test_scalar_strictness_and_non_finite_rejection
        test_sketchup_length_support
        test_optional_vectors
        puts 'Numeric Shape Hardening Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "Numeric Shape Hardening Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(12)
        false
      end
    end
  end
end

exit(BOMEngine::Tests::NumericShapeHardeningTest.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
