# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/export_fidelity_manifest'

class TestExportFidelityManifest < Minitest::Test
  def sample_graph
    {
      definitions: [
        { id: 'def_root', name: 'Root', kind: 'model_definition', node_ids: ['node_0'] },
        { id: 'def_0', name: 'WallDef', kind: 'component_definition', mesh_id: 'mesh_0', node_ids: [] }
      ],
      nodes: [
        { id: 'node_root', name: 'Model Root', kind: 'root', definition_id: 'def_root' },
        { id: 'node_0', name: 'WallInstance', kind: 'component_instance', owner_definition_id: 'def_root', definition_id: 'def_0', semantic: { role: 'wall', label: 'Dinding Utama' }, tag_id: 'tag_0' }
      ],
      tags: [
        { id: 'tag_0', name: 'Layer0', visible: true }
      ],
      materials: [
        { id: 'mat_0', name: 'Concrete', rgba: [128, 128, 128, 255] }
      ],
      meshes: [
        {
          id: 'mesh_0',
          definition_id: 'def_0',
          positions_m: [0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 2.0, 3.0, 0.0, 0.0, 3.0, 0.0],
          faces: [
            {
              id: 'face_0',
              role: 'wall',
              surface: 'wall_x_pos',
              front_material_id: 'mat_0',
              area_m2: 6.0,
              outer_loop: [0, 1, 2, 3],
              triangles: [0, 1, 2, 0, 2, 3]
            }
          ]
        }
      ],
      scenes: [
        {
          id: 'scene_0',
          name: 'Perspective',
          visibility_signature: 'sig_0',
          visibility: {
            visible_tag_ids: ['tag_0'],
            hidden_tag_ids: [],
            visible_node_ids: ['node_0'],
            hidden_node_ids: []
          },
          camera: {
            projection: 'perspective',
            eye_m: [10, 10, 10],
            target_m: [0, 0, 0],
            up: [0, 1, 0],
            fov_degrees: 45
          },
          section_state: {
            active_clip_plane_indices: [0]
          }
        }
      ],
      clip_planes: [
        {
          stable_id: 'clip_0',
          origin_m: [1.0, 0.0, 0.0],
          normal: [1.0, 0.0, 0.0],
          plane_constant: -1.0,
          keep_side: 1
        }
      ]
    }
  end

  def test_generate_manifest_structure
    manifest = BOMEngine::ExportFidelityManifest.generate_manifest(sample_graph, profile: 'exact')

    assert_equal '1.0.0', manifest[:schema_version]
    assert_equal 'exact', manifest[:profile]
    assert_equal 2, manifest[:definition_count]
    assert_equal 2, manifest[:instance_count]
    assert_equal 1, manifest[:scenes].length
    assert_equal 1, manifest[:clip_planes_count]

    # Semantic hashes
    assert manifest[:semantic_hashes][:roles_sha256]
    assert manifest[:semantic_hashes][:labels_sha256]
    assert manifest[:semantic_hashes][:overall_semantic_sha256]

    # Hierarchy and topology
    assert manifest[:hierarchy_hash]
    assert manifest[:tag_hash]
    assert manifest[:topology_hash]

    # Geometry metrics
    assert_in_delta 6.0, manifest[:geometry_metrics][:total_surface_area_m2], 0.001
    assert_equal 4, manifest[:geometry_metrics][:total_positions_count]
    assert_equal 2, manifest[:geometry_metrics][:total_triangles_count]

    # Scene fidelity
    scene = manifest[:scenes].first
    assert_equal 'scene_0', scene[:id]
    assert_equal ['tag_0'], scene[:visible_tag_ids]
    assert_equal 1, scene[:clip_planes].length
    assert_equal 'clip_0', scene[:clip_planes].first[:stable_id]
  end

  def test_deterministic_manifest_hashes
    manifest1 = BOMEngine::ExportFidelityManifest.generate_manifest(sample_graph, profile: 'research')
    manifest2 = BOMEngine::ExportFidelityManifest.generate_manifest(sample_graph, profile: 'research')

    assert_equal manifest1[:semantic_hashes], manifest2[:semantic_hashes]
    assert_equal manifest1[:hierarchy_hash], manifest2[:hierarchy_hash]
    assert_equal manifest1[:tag_hash], manifest2[:tag_hash]
    assert_equal manifest1[:topology_hash], manifest2[:topology_hash]
  end
end
