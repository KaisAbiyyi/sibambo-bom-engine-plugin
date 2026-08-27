# frozen_string_literal: true

require 'test/unit'
require 'json'
require_relative 'sketchup_mock_helper' unless defined?(Sketchup)
require_relative '../constants'
require_relative '../traversal'
require_relative '../canonical_graph_builder'
require_relative '../scene_visibility_resolver'
require_relative '../bomc_model_adapter'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

class TestSceneSharedUniverse < Test::Unit::TestCase
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
  end

  # 1. Geometry hidden in active PERS but visible in STR is physically present once
  def test_geometry_hidden_in_active_scene_present_in_shared_universe
    tag_pers = @model.layers.add('Tag_PERS')
    tag_str = @model.layers.add('Tag_STR')

    # PERS scene (active) hides Tag_STR
    scene_pers = @model.pages.add('PERS')
    scene_pers.use_hidden_layers = true
    scene_pers.layers = [tag_str]
    @model.pages.selected_page = scene_pers

    # STR scene (inactive) hides Tag_PERS
    scene_str = @model.pages.add('STR')
    scene_str.use_hidden_layers = true
    scene_str.layers = [tag_pers]

    # Create element on Tag_STR (base-hidden, but explicitly shown in STR page)
    def_str = @model.definitions.add('Structure_Column')
    face_str = def_str.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
    face_str.layer = tag_str
    inst_str = @model.entities.add_instance(def_str, Geom::Transformation.new)
    inst_str.layer = tag_str
    inst_str.hidden = true
    scene_str.set_drawingelement_visibility(inst_str, true)

    # Create element on Tag_PERS (visible in PERS, hidden in STR)
    def_pers = @model.definitions.add('Pers_Furniture')
    face_pers = def_pers.entities.add_face([0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0])
    face_pers.layer = tag_pers
    inst_pers = @model.entities.add_instance(def_pers, Geom::Transformation.new)
    inst_pers.layer = tag_pers

    # With scene_scope: 'all', both definitions and instances survive canonical graph
    graph_all = SibamboHistory::V20260827_02::CanonicalGraphBuilder.build(
      model: @model,
      entities: @model.entities,
      parent_transform: Geom::Transformation.new,
      settings: { scene_scope: 'all', output_format: 'bomc_v1_1' },
      spatial: {},
      texture_writer: nil
    )

    definition_names = graph_all[:definitions].map { |d| d[:name] }
    assert_include definition_names, 'Structure_Column', 'Structure definition must be in shared universe'
    assert_include definition_names, 'Pers_Furniture', 'Furniture definition must be in shared universe'

    node_names = graph_all[:nodes].map { |n| n[:name] }
    assert_include node_names, 'Structure_Column', 'Structure instance node must be in shared universe'
    assert_include node_names, 'Pers_Furniture', 'Furniture instance node must be in shared universe'

    # Pack to BOMC and decode
    pack_result = SibamboHistory::V20260827_02::BOMCWriter.pack(graph_all, profile: :production)
    decoded = SibamboHistory::V20260827_02::BOMCDecoder.decode(pack_result[:bytes])

    # Shared universe contains each geometry-bearing definition and instance exactly once
    decoded_defs = decoded[:definitions].map { |d| d[:name] }
    assert_include decoded_defs, 'Structure_Column'
    assert_include decoded_defs, 'Pers_Furniture'

    # Verify differing effective scene visibility
    pers_scene = decoded[:scenes].find { |s| s[:name] == 'PERS' }
    str_scene = decoded[:scenes].find { |s| s[:name] == 'STR' }
    assert_not_nil pers_scene
    assert_not_nil str_scene

    # PERS hides Tag_STR, STR hides Tag_PERS
    tag_str_idx = decoded[:tags].index { |t| t[:name] == 'Tag_STR' }
    tag_pers_idx = decoded[:tags].index { |t| t[:name] == 'Tag_PERS' }
    assert_include pers_scene.dig(:visibility, :hidden_tag_indices), tag_str_idx
    assert_include str_scene.dig(:visibility, :hidden_tag_indices), tag_pers_idx
  end

  # 2. Two Scenes yield meaningfully different effective occurrence masks
  def test_two_scenes_yield_different_effective_occurrence_masks
    tag1 = @model.layers.add('Architecture')
    tag2 = @model.layers.add('Structure')

    scene1 = @model.pages.add('Scene_Arch')
    scene2 = @model.pages.add('Scene_Str')

    scenes_raw = [
      {
        id: 'scene_arch',
        name: 'Scene_Arch',
        is_active_at_export: true,
        visibility: {
          visible_tag_ids: ["tag:#{tag1.persistent_id}"],
          hidden_tag_ids: ["tag:#{tag2.persistent_id}"],
          visible_node_overrides: [],
          hidden_node_overrides: ['node:def:root:inst_2']
        }
      },
      {
        id: 'scene_str',
        name: 'Scene_Str',
        is_active_at_export: false,
        visibility: {
          visible_tag_ids: ["tag:#{tag2.persistent_id}"],
          hidden_tag_ids: ["tag:#{tag1.persistent_id}"],
          visible_node_overrides: ['node:def:root:inst_2'],
          hidden_node_overrides: ['node:def:root:inst_1']
        }
      }
    ]

    tag_index = { "tag:#{tag1.persistent_id}" => 0, "tag:#{tag2.persistent_id}" => 1 }
    node_index = { 'node:def:root:inst_1' => 0, 'node:def:root:inst_2' => 1 }

    adapted = SibamboHistory::V20260827_02::BOMC::ModelAdapter.send(:adapt_scenes, scenes_raw, tag_index, node_index)

    assert_equal 2, adapted.length
    arch_vis = adapted[0][:visibility]
    str_vis = adapted[1][:visibility]

    assert_not_equal arch_vis[:visible_tag_indices], str_vis[:visible_tag_indices]
    assert_not_equal arch_vis[:hidden_tag_indices], str_vis[:hidden_tag_indices]
    assert_not_equal arch_vis[:hidden_node_indices], str_vis[:hidden_node_indices]
    assert_equal [0], arch_vis[:visible_tag_indices]
    assert_equal [1], arch_vis[:hidden_tag_indices]
    assert_equal [1], arch_vis[:hidden_node_indices]
    assert_equal [1], str_vis[:visible_tag_indices]
    assert_equal [0], str_vis[:hidden_tag_indices]
    assert_equal [0], str_vis[:hidden_node_indices]
  end

  # 3. Nested parent visibility inheritance
  def test_nested_parent_visibility_inheritance
    parent_group = @model.entities.add_group
    parent_group.name = 'ParentGroup'
    child_group = parent_group.entities.add_group
    child_group.name = 'ChildGroup'
    face = child_group.entities.add_face([0, 0, 0], [5, 0, 0], [5, 5, 0], [0, 5, 0])

    page = @model.pages.add('Scene_HiddenParent')
    page.hidden_entities = [parent_group]

    # Effective visibility of child entity when parent is hidden
    vis = SibamboHistory::V20260827_02::SceneVisibilityResolver.effective_entity_visibility(
      parent_group,
      page,
      parent_visibility: true
    )
    assert_equal false, vis, 'Parent entity visibility override must be false'

    child_vis = SibamboHistory::V20260827_02::SceneVisibilityResolver.effective_entity_visibility(
      child_group,
      page,
      parent_visibility: vis
    )
    assert_equal false, child_vis, 'Child entity must inherit false from parent visibility'
  end

  # 4. Stable node/tag IDs compile to runtime indices
  def test_stable_node_and_tag_ids_compile_to_runtime_indices
    canonical_nodes = [
      { id: 'node:root', kind: 'root' },
      { id: 'node:inst_a', kind: 'component_instance', persistent_id: '101' },
      { id: 'node:inst_b', kind: 'component_instance', persistent_id: '102' }
    ]
    node_index = SibamboHistory::V20260827_02::BOMC::ModelAdapter.send(:index_node_ids, canonical_nodes)

    assert_equal 1, node_index['node:inst_a']
    assert_equal 1, node_index['101']
    assert_equal 1, node_index['node:pid:101']
    assert_equal 2, node_index['node:inst_b']
    assert_equal 2, node_index['102']
    assert_equal 2, node_index['node:pid:102']

    tags = [{ id: 'tag:10', stable_id: 'tag:10' }, { id: 'tag:20', stable_id: 'tag:20' }]
    tag_index = { 'tag:10' => 0, 'tag:20' => 1 }

    raw_scenes = [{
      id: 'sc1',
      name: 'Scene 1',
      visibility: {
        visible_tag_ids: ['tag:20'],
        hidden_tag_ids: ['tag:10'],
        visible_node_overrides: ['node:pid:102'],
        hidden_node_overrides: ['node:inst_a']
      }
    }]

    adapted = SibamboHistory::V20260827_02::BOMC::ModelAdapter.send(:adapt_scenes, raw_scenes, tag_index, node_index)
    vis = adapted.first[:visibility]

    assert_equal [1], vis[:visible_tag_indices]
    assert_equal [0], vis[:hidden_tag_indices]
    assert_equal [2], vis[:visible_node_indices]
    assert_equal [1], vis[:hidden_node_indices]
  end

  # 5. Unresolved overrides are counted/reported and preserved on-disk
  def test_unresolved_overrides_counted_and_reported
    def1 = @model.definitions.add('UnresolvedBox')
    def1.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
    @model.entities.add_instance(def1, Geom::Transformation.new)
    graph = SibamboHistory::V20260827_02::CanonicalGraphBuilder.build(
      model: @model,
      entities: @model.entities,
      parent_transform: Geom::Transformation.new,
      settings: { scene_scope: 'all', output_format: 'bomc_v1_1' },
      spatial: {},
      texture_writer: nil
    )

    valid_node_id = graph[:nodes].last[:id]
    raw_scenes = [{
      id: 'sc_unresolved',
      name: 'Unresolved Scene',
      visibility: {
        visible_tag_ids: [],
        hidden_tag_ids: [],
        visible_node_overrides: ['node:missing_node_a', 'node:missing_node_b'],
        hidden_node_overrides: [valid_node_id, 'node:missing_node_c']
      }
    }]

    tag_index = {}
    node_index = { valid_node_id => 1 }
    adapted = SibamboHistory::V20260827_02::BOMC::ModelAdapter.send(:adapt_scenes, raw_scenes, tag_index, node_index)
    vis = adapted.first[:visibility]

    assert_equal 2, vis[:source_visible_node_override_count]
    assert_equal 2, vis[:source_hidden_node_override_count]
    assert_equal 0, vis[:resolved_visible_node_override_count]
    assert_equal 1, vis[:resolved_hidden_node_override_count]
    assert_equal 2, vis[:unresolved_visible_node_override_count]
    assert_equal 1, vis[:unresolved_hidden_node_override_count]
    assert_equal ['node:missing_node_a', 'node:missing_node_b'], vis[:unresolved_visible_node_overrides]
    assert_equal ['node:missing_node_c'], vis[:unresolved_hidden_node_overrides]

    # Pack and decode to verify on-disk preservation in Section 19 v2
    graph[:scenes] = raw_scenes
    pack_result = SibamboHistory::V20260827_02::BOMCWriter.pack(graph, profile: :production)
    decoded = SibamboHistory::V20260827_02::BOMCDecoder.decode(pack_result[:bytes])
    decoded_vis = decoded[:scenes].first[:visibility]

    assert_equal 2, decoded_vis[:source_visible_node_override_count]
    assert_equal 2, decoded_vis[:source_hidden_node_override_count]
    assert_equal 0, decoded_vis[:resolved_visible_node_override_count]
    assert_equal 1, decoded_vis[:resolved_hidden_node_override_count]
    assert_equal ['node:missing_node_a', 'node:missing_node_b'], decoded_vis[:unresolved_visible_node_overrides]
    assert_equal ['node:missing_node_c'], decoded_vis[:unresolved_hidden_node_overrides]
  end

  # 5b. Backward compatibility for v1 scenes section
  def test_backward_compatible_v1_scenes_section_decoded
    # Construct a raw binary v1 scene section (version 1)
    tag_count = 2
    tag_bitset_bytes = (tag_count + 7) / 8
    scenes_count = 1

    # v1 header: version 1, tag_count 2, scenes_count 1
    data = [1, tag_count, scenes_count].pack('CCV')

    # scene header (68 bytes)
    id_idx, name_idx, desc_idx, sig_idx = 0, 1, 0, 0
    flags = 0x01 | 0x02 | 0x04 | 0x08 | 0x40 # active, camera, tags, objects, persp
    eye = [10.0, -10.0, 10.0]
    tgt = [0.0, 0.0, 0.0]
    up = [0.0, 0.0, 1.0]
    fov = 35.0
    aspect = 1.33
    trans = 0.0

    data << [id_idx, name_idx, desc_idx, sig_idx, flags,
             eye[0], eye[1], eye[2], tgt[0], tgt[1], tgt[2], up[0], up[1], up[2],
             fov, aspect, trans].pack('VVVVVe3e3e3e3')

    # bitset
    data << [0x03].pack('C*') # both tags visible

    # hidden nodes: 1 node (node index 0)
    data << SibamboHistory::V20260827_02::BOMC::Binary.write_varuint(1)
    data << SibamboHistory::V20260827_02::BOMC::Binary.write_varuint(0)

    # visible nodes: 0 nodes
    data << SibamboHistory::V20260827_02::BOMC::Binary.write_varuint(0)

    strings = ['scene:doc:v1_test', 'V1 Scene']
    tags = [{ stable_id: 'tag:0' }, { stable_id: 'tag:1' }]
    instances = [{ stable_id: 'node:0' }]

    decoder = SibamboHistory::V20260827_02::BOMCDecoder::Decoder.allocate
    decoded_scenes = decoder.send(:decode_scenes, data, strings, tags, instances)
    assert_equal 1, decoded_scenes.length
    vis = decoded_scenes.first[:visibility]
    assert_equal 0, vis[:source_visible_node_override_count]
    assert_equal 1, vis[:source_hidden_node_override_count]
    assert_equal 0, vis[:resolved_visible_node_override_count]
    assert_equal 1, vis[:resolved_hidden_node_override_count]
    assert_equal [], vis[:unresolved_visible_node_overrides]
    assert_equal [], vis[:unresolved_hidden_node_overrides]
  end

  # 6. No per-Scene geometry duplication
  def test_no_per_scene_geometry_duplication
    def1 = @model.definitions.add('SharedBox')
    def1.entities.add_face([0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0])
    @model.entities.add_instance(def1, Geom::Transformation.new)

    3.times { |i| @model.pages.add("Scene_#{i}") }

    graph = SibamboHistory::V20260827_02::CanonicalGraphBuilder.build(
      model: @model,
      entities: @model.entities,
      parent_transform: Geom::Transformation.new,
      settings: { scene_scope: 'all', output_format: 'bomc_v1_1' },
      spatial: {},
      texture_writer: nil
    )

    bomc_model = SibamboHistory::V20260827_02::BOMC::ModelAdapter.from_canonical(graph)

    assert_equal 1, bomc_model[:meshes].length, 'Mesh must exist exactly once'
    assert_equal 2, bomc_model[:definitions].length, 'Definitions must be root + SharedBox'
    assert_equal 2, bomc_model[:instances].length, 'Instances must be root + 1 component instance'
    assert_equal 3, bomc_model[:scenes].length, '3 scenes must be present'
  end

  # 7. Shared-universe scope survives BOMC write/decode
  def test_shared_universe_scope_survives_bomc_write_and_decode
    def1 = @model.definitions.add('CubeDef')
    def1.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
    @model.entities.add_instance(def1, Geom::Transformation.new)
    @model.pages.add('Scene_A')
    @model.pages.add('Scene_B')

    graph = SibamboHistory::V20260827_02::CanonicalGraphBuilder.build(
      model: @model,
      entities: @model.entities,
      parent_transform: Geom::Transformation.new,
      settings: { scene_scope: 'all', output_format: 'bomc_v1_1' },
      spatial: {},
      texture_writer: nil
    )

    pack_result = SibamboHistory::V20260827_02::BOMCWriter.pack(graph, profile: :production)
    bytes = pack_result[:bytes]

    assert_not_nil bytes
    assert bytes.bytesize.positive?

    decoded = SibamboHistory::V20260827_02::BOMCDecoder.decode(bytes)

    assert_not_nil decoded
    flags = decoded.dig(:container, :flags) || 0
    assert_equal SibamboHistory::V20260827_02::BOMC::FLAG_SCOPE_ALL, (flags & SibamboHistory::V20260827_02::BOMC::FLAG_SCOPE_ALL), 'FLAG_SCOPE_ALL must be set'
    assert_equal SibamboHistory::V20260827_02::BOMC::FLAG_HAS_SCENES, (flags & SibamboHistory::V20260827_02::BOMC::FLAG_HAS_SCENES), 'FLAG_HAS_SCENES must be set'

    assert_equal 2, decoded[:scenes].length
    assert_equal 'Scene_A', decoded[:scenes][0][:name]
    assert_equal 'Scene_B', decoded[:scenes][1][:name]
    assert_equal 1, decoded[:meshes].length
  end

  # 8. Stable tag and node override identities survive Section 19 v3 roundtrip
  def test_stable_tag_and_node_override_identities_survive_v3_roundtrip
    tags = [
      { id: 'tag:arch_walls', stable_id: 'tag:arch_walls', name: 'Walls', visible: true },
      { id: 'tag:arch_doors', stable_id: 'tag:arch_doors', name: 'Doors', visible: false }
    ]
    instances = [
      { id: 'node:root_0', stable_id: 'node:root_0', name: 'Root', kind: 'root', definition_id: 'def:0', transform_id: 0, visible: true },
      { id: 'node:custom_wall_123', stable_id: 'node:custom_wall_123', name: 'Wall_Instance', kind: 'component_instance', definition_id: 'def:1', owner_definition_id: 'def:0', transform_id: 0, visible: true },
      { id: 'node:custom_door_456', stable_id: 'node:custom_door_456', name: 'Door_Instance', kind: 'component_instance', definition_id: 'def:2', owner_definition_id: 'def:0', transform_id: 0, visible: true }
    ]
    scenes = [{
      id: 'scene:doc:plan_view',
      name: 'Plan View',
      description: 'Ground floor plan',
      stable_id: 'scene:doc:plan_view',
      is_active_at_export: true,
      use_camera: true,
      camera: {
        projection: 'orthographic',
        eye_m: [0, 0, 100],
        target_m: [0, 0, 0],
        up: [0, 1, 0],
        orthographic_height_m: 50.0,
        aspect_ratio: 1.5
      },
      transition_time_seconds: 0.0,
      visibility: {
        visible_tag_ids: ['tag:arch_walls'],
        hidden_tag_ids: ['tag:arch_doors'],
        visible_node_overrides: ['node:custom_door_456', 'node:external_proxy'],
        hidden_node_overrides: ['node:custom_wall_123', 'node:unloaded_xref']
      }
    }]

    identity = SibamboHistory::V20260827_02::BOMC::ModelAdapter::IDENTITY
    graph = {
      format: { name: 'BOM Engine Canonical', version: '3.0.0' },
      source: { file_name: 'stable_ids.skp', model_name: 'Stable IDs', scope: 'all' },
      coordinate_system: { units: 'm', handedness: 'right', up_axis: 'Z' },
      materials: [],
      tags: tags,
      transforms: [identity.dup],
      meshes: [{
        id: 'mesh:0', definition_id: 'def:1',
        positions_m: [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0],
        faces: [{ id: 'f:0', outer: [0, 1, 2], holes: [], triangles: [0, 1, 2], normal: [0.0, 0.0, 1.0] }],
        edges: []
      }],
      definitions: [
        { id: 'def:0', name: 'Root', kind: 'model_definition', node_ids: ['node:custom_wall_123', 'node:custom_door_456'] },
        { id: 'def:1', name: 'Wall', kind: 'component_definition', mesh_id: 'mesh:0', node_ids: [] },
        { id: 'def:2', name: 'Door', kind: 'component_definition', mesh_id: 'mesh:0', node_ids: [] }
      ],
      nodes: instances,
      scenes: scenes
    }

    pack_result = SibamboHistory::V20260827_02::BOMCWriter.pack(graph, profile: :production)
    decoded = SibamboHistory::V20260827_02::BOMCDecoder.decode(pack_result[:bytes])
    decoded_scene = decoded[:scenes].first
    vis = decoded_scene[:visibility]

    # Exact survival of stable tag IDs
    assert_equal ['tag:arch_walls'], vis[:visible_tag_ids]
    assert_equal ['tag:arch_doors'], vis[:hidden_tag_ids]
    assert_equal [0], vis[:visible_tag_indices]
    assert_equal [1], vis[:hidden_tag_indices]

    # Exact survival of stable node override IDs
    assert_equal ['node:custom_door_456', 'node:external_proxy'], vis[:visible_node_overrides]
    assert_equal ['node:custom_wall_123', 'node:unloaded_xref'], vis[:hidden_node_overrides]
    assert_equal [2], vis[:visible_node_indices]
    assert_equal [1], vis[:hidden_node_indices]

    # Truthful counts
    assert_equal 2, vis[:source_visible_node_override_count]
    assert_equal 2, vis[:source_hidden_node_override_count]
    assert_equal 1, vis[:resolved_visible_node_override_count]
    assert_equal 1, vis[:resolved_hidden_node_override_count]
    assert_equal ['node:external_proxy'], vis[:unresolved_visible_node_overrides]
    assert_equal ['node:unloaded_xref'], vis[:unresolved_hidden_node_overrides]
  end

  # 8. Relevant baseline rendering/edge semantics are unchanged
  def test_baseline_rendering_edge_semantics_unchanged
    def1 = @model.definitions.add('EdgeTestDef')
    face = def1.entities.add_face([0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0])
    edge = def1.entities.add_edge([0, 0, 0], [2, 0, 0])
    edge.soft = true
    edge.smooth = true

    tf = Geom::Transformation.new
    edge_data = SibamboHistory::V20260827_02::Traversal.build_edge(edge, tf)

    assert_equal 'Edge', edge_data[:type]
    assert_equal true, edge_data[:soft]
    assert_equal true, edge_data[:smooth]
    assert_equal({ x: 0.0, y: 0.0, z: 0.0 }, edge_data[:start])
    assert_equal({ x: (2.0 * SibamboHistory::V20260827_02::Constants::IN_TO_M).round(5), y: 0.0, z: 0.0 }, edge_data[:end])

    normal = SibamboHistory::V20260827_02::Traversal.world_normal(face, tf)
    assert_equal 0.0, normal.x.round(4)
    assert_equal 0.0, normal.y.round(4)
    assert_equal 1.0, normal.z.round(4)
  end
end
