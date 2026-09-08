# frozen_string_literal: true

require 'test/unit'
require_relative '../bomc_format'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'

class TestAreaFidelityRegression < Test::Unit::TestCase
  def setup
    # Synthetic face: 10m x 10m vertical wall with a 2m x 2m window cutout in the center
    # Outer loop: [0, 1, 2, 3] (10x10 = 100 m2)
    # Inner cutout vertices: [4, 5, 6, 7] (2x2 = 4 m2 at x=4..6, y=4..6)
    # Net area = 96 m2
    # Vertices:
    # 0: [0, 0, 0], 1: [10, 0, 0], 2: [10, 10, 0], 3: [0, 10, 0]
    # 4: [4, 4, 0], 5: [6, 4, 0], 6: [6, 6, 0], 7: [4, 6, 0]
    @positions = [
      0.0, 0.0, 0.0,
      10.0, 0.0, 0.0,
      10.0, 10.0, 0.0,
      0.0, 10.0, 0.0,
      4.0, 4.0, 0.0,
      6.0, 4.0, 0.0,
      6.0, 6.0, 0.0,
      4.0, 6.0, 0.0
    ]
    # 8 triangles forming the wall around the cutout (net area: 24+24+24+24 = 96 m2)
    # Bottom: (0, 1, 5) and (0, 5, 4)
    # Right: (1, 2, 6) and (1, 6, 5)
    # Top: (2, 3, 7) and (2, 7, 6)
    # Left: (3, 0, 4) and (3, 4, 7)
    @triangles = [
      0, 1, 5,  0, 5, 4,
      1, 2, 6,  1, 6, 5,
      2, 3, 7,  2, 7, 6,
      3, 0, 4,  3, 4, 7
    ]
    @outer = [0, 1, 2, 3]
    @holes = []

    @synthetic_graph = {
      format: { identifier: 'canonical_bom_v3' },
      metadata: { title: 'Area Cutout Regression Test' },
      materials: [
        { id: 'mat_default', name: 'Default', rgba: [0.8, 0.8, 0.8, 1.0], roughness: 0.5, metalness: 0.0 }
      ],
      tags: [],
      definitions: [
        { id: 'def_root', name: 'RootDef', kind: 'model_definition', mesh_id: 'mesh_wall', node_ids: ['inst_wall'] },
        { id: 'def_wall', name: 'WallDef', kind: 'component_definition', mesh_id: 'mesh_wall', node_ids: [] }
      ],
      meshes: [
        {
          id: 'mesh_wall',
          definition_id: 'def_wall',
          positions_m: @positions,
          faces: [
            {
              id: 'face_cutout',
              outer: @outer,
              holes: @holes,
              triangles: @triangles,
              front_material_id: 'mat_default',
              back_material_id: nil,
              normal: [0.0, 0.0, 1.0],
              area_m2: 96.0,
              surface_hint: 'wall'
            }
          ],
          edges: []
        }
      ],
      nodes: [
        {
          id: 'node_root',
          kind: 'root',
          definition_id: 'def_root',
          transform_id: 0,
          visible: true
        },
        {
          id: 'inst_wall',
          kind: 'component_instance',
          definition_id: 'def_wall',
          owner_definition_id: 'def_root',
          transform_id: 0,
          visible: true
        }
      ],
      transforms: [
        [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
      ]
    }
  end

  def test_decoder_uses_triangles_area_for_cutouts
    [:exact, :research, :visual].each do |profile|
      packed = BOMEngine::BOMCWriter.pack(@synthetic_graph, profile: profile)
      decoded = BOMEngine::BOMCDecoder.decode(packed[:bytes])
      face = decoded[:meshes][0][:faces][0]

      # Net area must be 96 m2, not gross outer area of 100 m2
      assert_in_delta 96.0, face[:area_m2], 0.01,
                      "#{profile} decoder should report net triangulated area for face with cutout"

      validation = BOMEngine::BOMCValidator.validate!(@synthetic_graph, decoded)
      assert_equal true, validation[:areas][:passed], "#{profile} validation should pass areas"
      assert_operator validation[:areas][:max_error_m2], :<=, 0.01
    end
  end
end
