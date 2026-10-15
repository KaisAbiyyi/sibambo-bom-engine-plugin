# frozen_string_literal: true

module EvolutionFixture
  module_function

  def graph(texture_path: nil)
    materials = [
      {
        id: 'material:front', name: 'Front', display_name: 'Front',
        color: { red: 220, green: 180, blue: 120, alpha: 255 }, opacity: 1.0,
        material_type: 2, colorize_type: 'shift', colorize_deltas: { h: 12.5, l: 0.04, s: -0.03 }
      },
      {
        id: 'material:back', name: 'Back', display_name: 'Back',
        color: { red: 80, green: 120, blue: 200, alpha: 190 }, opacity: 0.745,
        material_type: 0
      }
    ]
    if texture_path
      materials[0][:texture] = {
        filename: File.basename(texture_path), source_path: texture_path,
        width_m: 1.25, height_m: 0.75, image_width_px: 4, image_height_px: 4,
        staging_evidence: {
          quality: { compatible: true, alpha_preserved: true, mean_squared_error: 0.0, max_channel_error: 0, psnr_db: Float::INFINITY }
        }
      }
    end

    face = {
      id: 'face:101', source_identity: { persistent_id: '101' },
      outer: [0, 1, 2, 3, 4, 5],
      holes: [[6, 7, 8, 9]],
      triangles: [0, 1, 6, 1, 7, 6, 1, 2, 7, 2, 8, 7, 2, 3, 8, 3, 9, 8, 3, 4, 9, 4, 5, 9, 5, 0, 6, 5, 6, 9],
      front_material_id: 'material:front', back_material_id: 'material:back',
      front_appearance_required: true, back_appearance_required: true,
      tag_id: 'tag:hidden', normal: [0.0, 0.0, 1.0], area_m2: 5.0,
      area_space: 'definition_local', surface_hint: 'horizontal',
      semantic: { label: 'floor-opening', role: 'floor' }, hidden: true,
      uv: {
        front_outer: [[0.0, 0.0], [1.0000000000003, 0.0], [1.0, 0.5], [1.0, 1.0], [0.5, 1.0], [0.0, 1.0]],
        front_holes: [[[0.2, 0.2], [0.4, 0.2], [0.4, 0.4], [0.2, 0.4]]],
        back_outer: [[0.0, 0.0], [1.0, 0.0], [1.0, 0.5], [1.0, 1.0], [0.5, 1.0], [0.0, 1.0]],
        back_holes: [[[0.2, 0.2], [0.2, 0.4], [0.4, 0.4], [0.4, 0.2]]]
      }
    }
    positions = [
      0.0, 0.0, 0.0,
      3.0, 0.0, 0.0,
      3.0, 1.5, 0.0,
      3.0, 3.0, 0.0,
      1.5, 3.0, 0.0,
      0.0, 3.0, 0.0,
      1.0, 1.0, 0.0,
      2.0, 1.0, 0.0,
      2.0, 2.0, 0.0,
      1.0, 2.0, 0.0
    ]
    identity = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
    nonuniform = [2.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 0.0, 1.5, 0.0, 10.0, 2.0, 1.0, 1.0]
    mirrored = [-1.0, 0.0, 0.0, 0.0, 0.0, 1.25, 0.0, 0.0, 0.0, 0.0, 0.75, 0.0, -4.0, 1.0, 0.5, 1.0]
    {
      format: { name: 'BOM Engine Canonical', version: '3.0.0', schema: 'fixture' },
      source: { kind: 'SketchUp', identity: { persistent_id: 'fixture-model' }, file_path: 'C:/private/fixture.skp', file_name: 'fixture.skp', model_name: 'Evolution Fixture' },
      units: { geometry_length_unit: 'meter', area_unit: 'square_meter' },
      coordinate_system: { handedness: 'right', up_axis: '+Z', storage: 'definition_local' },
      metadata: { fixture: true },
      tags: [{ id: 'tag:hidden', name: 'HiddenFixture', visible: false }],
      materials: materials,
      transforms: [identity, nonuniform, mirrored],
      meshes: [{
        id: 'mesh:def:shape', definition_id: 'def:shape', coordinate_space: 'definition_local', positions_m: positions, faces: [face],
        edges: [{ id: 'edge:201', source_identity: { persistent_id: '201' }, vertices: [0, 1], tag_id: 'tag:hidden', hidden: true, soft: true, smooth: false }]
      }],
      definitions: [
        { id: 'def:root', kind: 'root', name: 'Root', mesh_id: nil, node_ids: ['node:a', 'node:b', 'node:image', 'node:text'] },
        { id: 'def:shape', kind: 'component_definition', name: 'Shape', mesh_id: 'mesh:def:shape', node_ids: [] }
      ],
      nodes: [
        { id: 'node:root', kind: 'root', name: 'Root', owner_definition_id: nil, definition_id: 'def:root', transform_id: 0, material_override_id: nil, tag_id: nil, semantic: {} },
        { id: 'node:a', kind: 'component_instance', name: 'Scaled', owner_definition_id: 'def:root', definition_id: 'def:shape', transform_id: 1, material_override_id: nil, tag_id: 'tag:hidden', visible: true, semantic: { label: 'scaled' } },
        { id: 'node:b', kind: 'component_instance', name: 'Mirrored', owner_definition_id: 'def:root', definition_id: 'def:shape', transform_id: 2, material_override_id: 'material:back', tag_id: nil, visible: true, semantic: { label: 'mirror' } },
        { id: 'node:image', kind: 'image', name: 'Reference', owner_definition_id: 'def:root', definition_id: nil, transform_id: 1, material_override_id: nil, tag_id: 'tag:hidden', visible: true, image: { filename: 'reference.png', width_m: 1.5, height_m: 0.75, position: [2.0, 1.0, 0.5], image_width_px: 4, image_height_px: 4 }, source_identity: { persistent_id: '301' } },
        { id: 'node:text', kind: 'text', name: 'Room note', owner_definition_id: 'def:root', definition_id: nil, transform_id: 0, material_override_id: nil, tag_id: nil, visible: true, text: 'Room note', attachment: { target_persistent_id: '101' }, source_identity: { persistent_id: '302' } }
      ],
      scenes: [
        {
          id: 'scene:one', name: 'Scene One', is_active_at_export: true, use_camera: true,
          camera: { projection: 'perspective', eye_m: [7.0, -8.0, 6.0], target_m: [1.0, 1.0, 0.0], up: [0.0, 0.0, 1.0] },
          visibility: { visible_tag_ids: [], hidden_tag_ids: ['tag:hidden'], visible_node_overrides: [], hidden_node_overrides: [] },
          section_state: { active_clip_plane_indices: [0], section_cuts_displayed: true, rendering_support: 'full' },
          visibility_signature: 'fixture-one'
        },
        {
          id: 'scene:two', name: 'Scene Two', is_active_at_export: false, use_camera: false,
          camera: { projection: 'perspective', eye_m: [0.0, -5.0, 3.0], target_m: [0.0, 0.0, 0.0], up: [0.0, 0.0, 1.0] },
          visibility: { visible_tag_ids: ['tag:hidden'], hidden_tag_ids: [], visible_node_overrides: ['node:a'], hidden_node_overrides: ['node:b'] },
          section_state: { active_clip_plane_indices: [], section_cuts_displayed: false, rendering_support: 'full' },
          visibility_signature: 'fixture-two'
        }
      ],
      clip_planes: [{ index: 0, stable_id: 'clip:0', source_persistent_id: '900', origin_m: [0.0, 0.0, 1.0], normal: [0.0, 0.0, 1.0], plane_constant: -1.0, keep_side: 1, flags: 0 }],
      scene_fidelity_manifest: { scene_count: 2, clip_plane_count: 1 },
      spaces: [], relationships: {}, analysis: {}, statistics: {}
    }
  end
end
