# bom_engine/tests/test_scene_visibility_resolver.rb
# Comprehensive unit tests for SceneVisibilityResolver and scene preservation semantics.

require 'test/unit'
require 'digest'
require 'json'
require_relative '../scene_visibility_resolver'
require_relative '../bomc_format'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

module BOMEngine
  class TestSceneVisibilityResolver < Test::Unit::TestCase
    # Mock classes for SketchUp Page, Layer, Entity, Camera
    class MockPoint
      attr_accessor :x, :y, :z
      def initialize(x, y, z); @x = x; @y = y; @z = z; end
    end

    class MockVector
      attr_accessor :x, :y, :z
      def initialize(x, y, z); @x = x; @y = y; @z = z; end
    end

    class MockCamera
      attr_accessor :eye, :target, :up, :fov, :height, :aspect_ratio, :perspective
      def initialize(perspective: true, fov: 35.0, eye: MockPoint.new(10, -10, 10), target: MockPoint.new(0, 0, 0), up: MockVector.new(0, 0, 1), height: nil, aspect_ratio: 0.0)
        @perspective = perspective
        @fov = fov
        @eye = eye
        @target = target
        @up = up
        @height = height
        @aspect_ratio = aspect_ratio
      end
      def perspective?; @perspective; end
    end

    class MockLayerFolder
      attr_accessor :name, :visible, :persistent_id
      def initialize(name, visible: true, persistent_id: nil)
        @name = name
        @visible = visible
        @persistent_id = persistent_id || name
      end
      def visible?; @visible; end
    end

    class MockLayer
      attr_accessor :name, :visible, :persistent_id, :folder
      def initialize(name, visible: true, persistent_id: nil, folder: nil)
        @name = name
        @visible = visible
        @persistent_id = persistent_id || name
        @folder = folder
      end
      def visible?; @visible; end
    end

    class MockPage
      attr_accessor :name, :description, :camera, :use_camera, :use_hidden_layers, :layers,
                    :use_hidden_objects, :use_hidden_geometry, :hidden_entities,
                    :use_section_planes, :active_section_planes, :persistent_id,
                    :transition_time, :layer_folders, :use_rendering_options,
                    :rendering_options

      def initialize(name, persistent_id: nil, camera: nil, use_camera: true,
                     use_hidden_layers: true, layers: [],
                     use_hidden_objects: true, use_hidden_geometry: false, hidden_entities: [],
                     use_section_planes: false, active_section_planes: [],
                     transition_time: 0.0, layer_folders: [], use_rendering_options: true,
                     rendering_options: { 'DisplaySectionCuts' => true, 'DisplaySectionPlanes' => false })
        @name = name
        @description = "Description for #{name}"
        @persistent_id = persistent_id || "pid_#{name.downcase}"
        @camera = camera || MockCamera.new
        @use_camera = use_camera
        @use_hidden_layers = use_hidden_layers
        @layers = layers # Hidden layers on this page
        @use_hidden_objects = use_hidden_objects
        @use_hidden_geometry = use_hidden_geometry
        @hidden_entities = hidden_entities
        @use_section_planes = use_section_planes
        @active_section_planes = active_section_planes
        @transition_time = transition_time
        @layer_folders = layer_folders
        @use_rendering_options = use_rendering_options
        @rendering_options = rendering_options
      end

      def use_camera?; @use_camera; end
      def use_hidden_layers?; @use_hidden_layers; end
      def use_hidden_objects?; @use_hidden_objects; end
      def use_hidden_geometry?; @use_hidden_geometry; end
      def use_section_planes?; @use_section_planes; end
      def use_rendering_options?; @use_rendering_options; end

      def get_drawingelement_visibility(element)
        if @drawingelement_visibility && @drawingelement_visibility.key?(element)
          @drawingelement_visibility[element]
        elsif @hidden_entities.include?(element) || (element.respond_to?(:hidden?) && element.hidden?)
          false
        else
          true
        end
      end

      def set_drawingelement_visibility(element, visible)
        @drawingelement_visibility ||= {}
        val = visible ? true : false
        @drawingelement_visibility[element] = val
        if val
          @hidden_entities.delete(element)
        else
          @hidden_entities << element unless @hidden_entities.include?(element)
        end
      end
    end

    class MockModel
      attr_accessor :pages, :layers, :guid, :path, :name, :description, :active_view
      def initialize(pages: [], layers: [])
        @pages = pages
        @layers = layers
        @guid = 'mock-guid-1234'
        @path = 'mock_model.skp'
        @name = 'Mock Model'
        @description = 'Mock model description'
      end
    end

    def test_pers_vs_str_tag_isolation
      layer_arch = MockLayer.new('ARCH', visible: true, persistent_id: '101')
      layer_struct = MockLayer.new('STRUCT', visible: true, persistent_id: '102')

      # Scene PERS hides STRUCT
      page_pers = MockPage.new('PERS', persistent_id: 'page_pers', layers: [layer_struct])
      # Scene STR hides ARCH
      page_str = MockPage.new('STR', persistent_id: 'page_str', layers: [layer_arch])

      model = MockModel.new(pages: [page_pers, page_str], layers: [layer_arch, layer_struct])

      scenes = SceneVisibilityResolver.resolve_scenes(model)
      assert_equal 2, scenes.length

      pers_profile = scenes.find { |s| s[:name] == 'PERS' }
      str_profile = scenes.find { |s| s[:name] == 'STR' }

      assert_not_nil pers_profile
      assert_not_nil str_profile

      # PERS: ARCH is visible, STRUCT is hidden
      assert_includes pers_profile.dig(:visibility, :visible_tag_ids), 'tag:101'
      assert_includes pers_profile.dig(:visibility, :hidden_tag_ids), 'tag:102'

      # STR: ARCH is hidden, STRUCT is visible
      assert_includes str_profile.dig(:visibility, :hidden_tag_ids), 'tag:101'
      assert_includes str_profile.dig(:visibility, :visible_tag_ids), 'tag:102'

      # Signatures must be distinct
      assert_not_equal pers_profile[:visibility_signature], str_profile[:visibility_signature]
    end

    def test_camera_only_change_preserves_visibility_signature
      layer_arch = MockLayer.new('ARCH', visible: true, persistent_id: '101')
      layer_struct = MockLayer.new('STRUCT', visible: true, persistent_id: '102')

      cam_a = MockCamera.new(eye: MockPoint.new(20, 0, 5))
      cam_b = MockCamera.new(eye: MockPoint.new(0, 20, 5))

      page_a = MockPage.new('TAMPAK A', persistent_id: 'page_tampak_a', camera: cam_a)
      page_b = MockPage.new('TAMPAK B', persistent_id: 'page_tampak_b', camera: cam_b)

      model = MockModel.new(pages: [page_a, page_b], layers: [layer_arch, layer_struct])

      scenes = SceneVisibilityResolver.resolve_scenes(model)
      assert_equal 2, scenes.length

      scene_a = scenes.find { |s| s[:name] == 'TAMPAK A' }
      scene_b = scenes.find { |s| s[:name] == 'TAMPAK B' }

      # Stable IDs must be distinct
      assert_not_equal scene_a[:id], scene_b[:id]
      # Camera must be distinct
      assert_not_equal scene_a.dig(:camera, :eye_m), scene_b.dig(:camera, :eye_m)
      # Visibility signature MUST BE IDENTICAL because visibility is identical
      assert_equal scene_a[:visibility_signature], scene_b[:visibility_signature]
    end

    def test_scene_rename_preserves_stable_id_and_signature
      layer = MockLayer.new('ARCH', visible: true, persistent_id: '101')
      page = MockPage.new('PERS', persistent_id: 'stable_pers_guid')

      model1 = MockModel.new(pages: [page], layers: [layer])
      scene1 = SceneVisibilityResolver.resolve_scenes(model1).first

      # Rename the page
      page.name = 'Perspective Architecture'
      model2 = MockModel.new(pages: [page], layers: [layer])
      scene2 = SceneVisibilityResolver.resolve_scenes(model2).first

      assert_equal scene1[:id], scene2[:id], 'Stable ID must not depend on scene name'
      assert_equal scene1[:visibility_signature], scene2[:visibility_signature], 'Signature must not depend on scene name'
      assert_equal 'Perspective Architecture', scene2[:name]
    end

    def test_tag_node_row_reorder_preserves_signature
      sig1 = SceneVisibilityResolver.compute_visibility_signature(
        visible_tag_ids: ['tag:101', 'tag:102', 'tag:103'],
        hidden_tag_ids: ['tag:201', 'tag:202'],
        visible_node_overrides: ['node:1', 'node:2'],
        hidden_node_overrides: ['node:3'],
        active_section_plane_ids: []
      )

      # Reverse / permutation of the input order
      sig2 = SceneVisibilityResolver.compute_visibility_signature(
        visible_tag_ids: ['tag:103', 'tag:101', 'tag:102'],
        hidden_tag_ids: ['tag:202', 'tag:201'],
        visible_node_overrides: ['node:2', 'node:1'],
        hidden_node_overrides: ['node:3'],
        active_section_plane_ids: []
      )

      assert_equal sig1, sig2, 'Signature must be deterministic and invariant to row order'
    end

    def test_hidden_by_default_tag_made_visible_in_scene
      # Tag hidden by default in model
      layer = MockLayer.new('FURNITURE', visible: false, persistent_id: '105')
      # Page does not include layer in hidden list (meaning it is visible on this page)
      page = MockPage.new('INTERIOR', persistent_id: 'page_interior', layers: [])

      model = MockModel.new(pages: [page], layers: [layer])

      assert_equal true, SceneVisibilityResolver.effective_tag_visibility(layer, page)
      scene = SceneVisibilityResolver.resolve_scenes(model).first
      assert_includes scene.dig(:visibility, :visible_tag_ids), 'tag:105'
    end

    def test_layer_folder_visibility
      folder = MockLayerFolder.new('STRUCT_FOLDER', visible: false, persistent_id: 'f_struct')
      layer = MockLayer.new('BEAMS', visible: true, persistent_id: '106', folder: folder)
      page = MockPage.new('ARCH_VIEW', persistent_id: 'page_arch', layer_folders: [folder])

      assert_equal false, SceneVisibilityResolver.effective_tag_visibility(layer, page)
    end

    def test_active_vs_all_scenes_exportable_universe
      layer_pers = MockLayer.new('PERS_ONLY', visible: true, persistent_id: '101')
      layer_str = MockLayer.new('STR_ONLY', visible: true, persistent_id: '102')
      layer_hidden_all = MockLayer.new('UNUSED_HIDDEN', visible: false, persistent_id: '103')

      page_pers = MockPage.new('PERS', persistent_id: 'p_pers', layers: [layer_str, layer_hidden_all])
      page_str = MockPage.new('STR', persistent_id: 'p_str', layers: [layer_pers, layer_hidden_all])

      model = MockModel.new(pages: [page_pers, page_str], layers: [layer_pers, layer_str, layer_hidden_all])
      scenes = SceneVisibilityResolver.resolve_scenes(model)

      # In active mode with PERS selected:
      entity_pers = Struct.new(:layer).new(layer_pers)
      entity_str = Struct.new(:layer).new(layer_str)
      entity_hidden = Struct.new(:layer).new(layer_hidden_all)

      # Active scene = PERS
      assert_equal true, SceneVisibilityResolver.exportable_universe?(entity_pers, scenes, scope: 'active')
      assert_equal false, SceneVisibilityResolver.exportable_universe?(entity_str, scenes, scope: 'active')
      assert_equal false, SceneVisibilityResolver.exportable_universe?(entity_hidden, scenes, scope: 'active')

      # All scenes mode:
      assert_equal true, SceneVisibilityResolver.exportable_universe?(entity_pers, scenes, scope: 'all')
      assert_equal true, SceneVisibilityResolver.exportable_universe?(entity_str, scenes, scope: 'all')
      assert_equal false, SceneVisibilityResolver.exportable_universe?(entity_hidden, scenes, scope: 'all')
    end

    def test_bomc_section_scenes_roundtrip
      layer1 = { id: 'tag:101', name: 'ARCH', visible: true }
      layer2 = { id: 'tag:102', name: 'STRUCT', visible: false }

      graph = {
        format: { name: 'BOM Engine Canonical', version: '3.0.0' },
        materials: [{ id: 'mat:1', name: 'Concrete', color: { hex: '#888888' }, opacity: 1.0 }],
        tags: [layer1, layer2],
        definitions: [
          { id: 'def:root', name: 'Root', kind: 'model_definition', node_ids: ['node:1', 'node:2'] },
          { id: 'def:box', name: 'Box', kind: 'component_definition', mesh_id: 'mesh:1', node_ids: [] }
        ],
        meshes: [
          {
            id: 'mesh:1',
            definition_id: 'def:box',
            positions_m: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
            faces: [
              {
                id: 'face:1',
                outer: [0, 1, 2, 3],
                holes: [],
                triangles: [0, 1, 2, 0, 2, 3],
                front_material_id: 'mat:1',
                back_material_id: nil,
                tag_id: 'tag:101',
                normal: [0.0, 0.0, 1.0],
                area_m2: 1.0,
                surface_type: 'wall'
              }
            ],
            edges: []
          }
        ],
        nodes: [
          { id: 'node:root', kind: 'root', name: 'Root', definition_id: 'def:root', transform_id: 0 },
          { id: 'node:1', kind: 'component_instance', name: 'ArchBox', owner_definition_id: 'def:root', definition_id: 'def:box', transform_id: 0, tag_id: 'tag:101', visible: true },
          { id: 'node:2', kind: 'component_instance', name: 'StructBox', owner_definition_id: 'def:root', definition_id: 'def:box', transform_id: 0, tag_id: 'tag:102', visible: false }
        ],
        transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
        scenes: [
          {
            id: 'scene:doc:pers',
            name: 'PERS',
            description: 'Perspective Scene',
            is_active_at_export: true,
            camera: {
              projection: 'perspective',
              eye_m: [15.0, -15.0, 10.0],
              target_m: [0.0, 0.0, 0.0],
              up: [0.0, 0.0, 1.0],
              field_of_view_degrees: 35.0,
              aspect_ratio: 1.77
            },
            use_camera: true,
            transition_time_seconds: 1.5,
            visibility: {
              visible_tag_ids: ['tag:101'],
              hidden_tag_ids: ['tag:102'],
              visible_node_overrides: [],
              hidden_node_overrides: []
            },
            stores_tag_visibility: true,
            stores_hidden_objects: true,
            stores_hidden_geometry: false,
            stores_section_planes: false,
            section_state: { active_section_plane_ids: [], rendering_support: 'metadata-only' },
            visibility_signature: 'sig_pers_12345'
          },
          {
            id: 'scene:doc:str',
            name: 'STR',
            description: 'Structural Scene',
            is_active_at_export: false,
            camera: {
              projection: 'orthographic',
              eye_m: [0.0, 0.0, 20.0],
              target_m: [0.0, 0.0, 0.0],
              up: [0.0, 1.0, 0.0],
              orthographic_height_m: 12.5,
              aspect_ratio: 1.33
            },
            use_camera: true,
            transition_time_seconds: 0.0,
            visibility: {
              visible_tag_ids: ['tag:102'],
              hidden_tag_ids: ['tag:101'],
              visible_node_overrides: [],
              hidden_node_overrides: []
            },
            stores_tag_visibility: true,
            stores_hidden_objects: true,
            stores_hidden_geometry: false,
            stores_section_planes: false,
            section_state: { active_section_plane_ids: [], rendering_support: 'metadata-only' },
            visibility_signature: 'sig_str_67890'
          }
        ]
      }

      packed = BOMCWriter.pack(graph)
      assert_not_nil packed[:bytes]

      decoded = BOMCDecoder.decode(packed[:bytes])
      assert_equal 2, decoded[:scenes].length
      assert_equal 'scene:doc:pers', decoded[:active_scene_id]

      pers = decoded[:scenes].find { |s| s[:id] == 'scene:doc:pers' }
      str = decoded[:scenes].find { |s| s[:id] == 'scene:doc:str' }

      assert_equal 'PERS', pers[:name]
      assert_equal true, pers[:is_active_at_export]
      assert_equal 'perspective', pers.dig(:camera, :projection)
      assert_equal 15.0, pers.dig(:camera, :eye_m, 0)
      assert_equal 'sig_pers_12345', pers[:visibility_signature]
      assert_includes pers.dig(:visibility, :visible_tag_indices), 0
      assert_includes pers.dig(:visibility, :hidden_tag_indices), 1
      assert_includes pers.dig(:visibility, :visible_tag_ids), 'tag:101'
      assert_includes pers.dig(:visibility, :hidden_tag_ids), 'tag:102'

      assert_equal 'STR', str[:name]
      assert_equal false, str[:is_active_at_export]
      assert_equal 'orthographic', str.dig(:camera, :projection)
      assert_equal 12.5, str.dig(:camera, :orthographic_height_m)
      assert_equal 'sig_str_67890', str[:visibility_signature]
      assert_includes str.dig(:visibility, :visible_tag_indices), 1
      assert_includes str.dig(:visibility, :hidden_tag_indices), 0
      assert_includes str.dig(:visibility, :visible_tag_ids), 'tag:102'
      assert_includes str.dig(:visibility, :hidden_tag_ids), 'tag:101'
    end

    def test_legacy_bomc_without_scenes_generates_synthetic_default_scene
      # Graph with NO scenes
      graph = {
        format: { name: 'BOM Engine Canonical', version: '3.0.0' },
        materials: [{ id: 'mat:1', name: 'Material', color: { hex: '#ffffff' }, opacity: 1.0 }],
        tags: [{ id: 'tag:1', name: 'Layer0', visible: true }],
        definitions: [{ id: 'def:root', name: 'Root', kind: 'model_definition', node_ids: [] }],
        meshes: [],
        nodes: [{ id: 'node:root', kind: 'root', name: 'Root', definition_id: 'def:root', transform_id: 0 }],
        transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
        scenes: []
      }

      packed = BOMCWriter.pack(graph)
      decoded = BOMCDecoder.decode(packed[:bytes])

      assert_equal 1, decoded[:scenes].length
      default_scene = decoded[:scenes].first
      assert_equal 'scene:doc:default', default_scene[:id]
      assert_equal 'legacy-synthetic', default_scene[:source]
      assert_equal true, default_scene[:is_active_at_export]
      assert_equal 'scene:doc:default', decoded[:active_scene_id]
      assert_not_nil default_scene[:visibility_signature]
    end

    class MockDrawingElement
      attr_accessor :persistent_id, :entityID, :layer, :hidden
      def initialize(persistent_id, layer: nil, hidden: false)
        @persistent_id = persistent_id
        @entityID = persistent_id.to_i rescue 1000
        @layer = layer
        @hidden = hidden
      end
      def hidden?; @hidden; end
      def visible?; !@hidden; end
    end

    def test_different_hidden_component_changes_signature
      elem_a = MockDrawingElement.new('comp_a')
      elem_b = MockDrawingElement.new('comp_b')
      layer = MockLayer.new('Layer0', visible: true, persistent_id: 'l0')

      page_pers = MockPage.new('PERS', persistent_id: 'p_pers', hidden_entities: [elem_b])
      page_str = MockPage.new('STR', persistent_id: 'p_str', hidden_entities: [elem_a])

      nodes = [
        { id: 'node:root', kind: 'root', definition_id: 'def:root' },
        { id: 'node:def:root:comp:comp_a', kind: 'component_instance', persistent_id: 'comp_a', _entity: elem_a },
        { id: 'node:def:root:comp:comp_b', kind: 'component_instance', persistent_id: 'comp_b', _entity: elem_b }
      ]

      model = MockModel.new(pages: [page_pers, page_str], layers: [layer])
      scenes = SceneVisibilityResolver.resolve_scenes(model, nodes: nodes)

      pers_scene = scenes.find { |s| s[:name] == 'PERS' }
      str_scene = scenes.find { |s| s[:name] == 'STR' }

      assert_includes pers_scene.dig(:visibility, :hidden_node_overrides), 'node:def:root:comp:comp_b'
      assert_includes str_scene.dig(:visibility, :hidden_node_overrides), 'node:def:root:comp:comp_a'
      assert_not_equal pers_scene[:visibility_signature], str_scene[:visibility_signature],
        'Scenes with different hidden components MUST have different visibility signatures'
    end

    def test_different_hidden_nested_group_changes_signature
      elem_group = MockDrawingElement.new('nested_grp_1')
      layer = MockLayer.new('Layer0', visible: true, persistent_id: 'l0')

      page1 = MockPage.new('SCENE_1', persistent_id: 'p_1', hidden_entities: [])
      page2 = MockPage.new('SCENE_2', persistent_id: 'p_2', hidden_entities: [elem_group])

      nodes = [
        { id: 'node:root', kind: 'root', definition_id: 'def:root' },
        { id: 'node:def:root:group:nested_grp_1', kind: 'group_instance', persistent_id: 'nested_grp_1', _entity: elem_group }
      ]

      model = MockModel.new(pages: [page1, page2], layers: [layer])
      scenes = SceneVisibilityResolver.resolve_scenes(model, nodes: nodes)

      s1 = scenes.find { |s| s[:name] == 'SCENE_1' }
      s2 = scenes.find { |s| s[:name] == 'SCENE_2' }

      assert_empty s1.dig(:visibility, :hidden_node_overrides)
      assert_includes s2.dig(:visibility, :hidden_node_overrides), 'node:def:root:group:nested_grp_1'
      assert_not_equal s1[:visibility_signature], s2[:visibility_signature]
    end

    def test_drawingelement_visibility_override_values
      elem_hidden = MockDrawingElement.new('elem_hid', hidden: false)
      elem_vis = MockDrawingElement.new('elem_vis', hidden: true) # Base hidden, overridden to visible on page

      page = MockPage.new('OVERRIDE_SCENE', persistent_id: 'p_ov')
      def page.get_drawingelement_visibility(elem)
        return false if elem.persistent_id == 'elem_hid'
        return true if elem.persistent_id == 'elem_vis'
        nil
      end

      nodes = [
        { id: 'node:root', kind: 'root', definition_id: 'def:root' },
        { id: 'node:1', kind: 'component_instance', persistent_id: 'elem_hid', _entity: elem_hidden },
        { id: 'node:2', kind: 'component_instance', persistent_id: 'elem_vis', _entity: elem_vis }
      ]

      model = MockModel.new(pages: [page], layers: [MockLayer.new('Layer0', visible: true, persistent_id: 'l0')])
      scenes = SceneVisibilityResolver.resolve_scenes(model, nodes: nodes)
      scene = scenes.first

      assert_includes scene.dig(:visibility, :hidden_node_overrides), 'node:1'
      assert_includes scene.dig(:visibility, :visible_node_overrides), 'node:2'
    end

    def test_layer_page_behavior_four_cases
      # Case A: Visible-by-default (page_behavior 0x0000), unchanged (not in page.layers)
      tag_a = MockLayer.new('TagA', visible: true, persistent_id: '101')
      # Case B: Visible-by-default (page_behavior 0x0000), hidden by scene (in page.layers)
      tag_b = MockLayer.new('TagB', visible: true, persistent_id: '102')
      # Case C: Hidden-by-default (page_behavior 0x0001), unchanged (not in page.layers)
      tag_c = MockLayer.new('TagC', visible: false, persistent_id: '103')
      tag_c.define_singleton_method(:page_behavior) { 0x0001 }
      # Case D: Hidden-by-default (page_behavior 0x0001), made visible by scene (in page.layers)
      tag_d = MockLayer.new('TagD', visible: false, persistent_id: '104')
      tag_d.define_singleton_method(:page_behavior) { 0x0001 }

      page = MockPage.new('TEST_SCENE', persistent_id: 'p_test', layers: [tag_b, tag_d])

      assert_equal true, SceneVisibilityResolver.effective_tag_visibility(tag_a, page), 'Case A: visible default unchanged -> visible'
      assert_equal false, SceneVisibilityResolver.effective_tag_visibility(tag_b, page), 'Case B: visible default in page.layers -> hidden'
      assert_equal false, SceneVisibilityResolver.effective_tag_visibility(tag_c, page), 'Case C: hidden default unchanged -> hidden'
      assert_equal true, SceneVisibilityResolver.effective_tag_visibility(tag_d, page), 'Case D: hidden default in page.layers -> visible'
    end

    def test_effective_visible_occurrences_calculation
      elem_a = MockDrawingElement.new('comp_a')
      elem_b = MockDrawingElement.new('comp_b')
      layer = MockLayer.new('Layer0', visible: true, persistent_id: 'l0')

      page_pers = MockPage.new('PERS', persistent_id: 'p_pers', hidden_entities: [elem_b])
      page_all = MockPage.new('ALL', persistent_id: 'p_all', hidden_entities: [])

      nodes = [
        { id: 'node:root', kind: 'root', definition_id: 'def:root' },
        { id: 'node:def:root:comp:comp_a', kind: 'component_instance', persistent_id: 'comp_a', definition_id: 'def:a', _entity: elem_a },
        { id: 'node:def:root:comp:comp_b', kind: 'component_instance', persistent_id: 'comp_b', definition_id: 'def:b', _entity: elem_b }
      ]

      definitions = [
        { id: 'def:root', node_ids: ['node:def:root:comp:comp_a', 'node:def:root:comp:comp_b'] },
        { id: 'def:a', node_ids: [] },
        { id: 'def:b', node_ids: [] }
      ]

      model = MockModel.new(pages: [page_pers, page_all], layers: [layer])
      scenes = SceneVisibilityResolver.resolve_scenes(model, nodes: nodes, definitions: definitions)

      pers = scenes.find { |s| s[:name] == 'PERS' }
      all = scenes.find { |s| s[:name] == 'ALL' }

      assert_equal 1, pers[:effective_visible_occurrence_count]
      assert_equal 2, all[:effective_visible_occurrence_count]
    end

    def test_bomc_section_scenes_with_node_overrides_roundtrip
      graph = {
        format: { name: 'BOM Engine Canonical', version: '3.0.0' },
        materials: [{ id: 'mat:1', name: 'Material', color: { hex: '#ffffff' }, opacity: 1.0 }],
        tags: [{ id: 'tag:1', name: 'Layer0', visible: true }],
        definitions: [
          { id: 'def:root', name: 'Root', kind: 'model_definition', node_ids: ['node:inst:1', 'node:inst:2'] },
          { id: 'def:comp', name: 'Comp', kind: 'component_definition', node_ids: [] }
        ],
        meshes: [],
        nodes: [
          { id: 'node:root', kind: 'root', name: 'Root', definition_id: 'def:root', transform_id: 0 },
          { id: 'node:inst:1', kind: 'component_instance', name: 'Inst1', definition_id: 'def:comp', transform_id: 0, persistent_id: '1001' },
          { id: 'node:inst:2', kind: 'component_instance', name: 'Inst2', definition_id: 'def:comp', transform_id: 0, persistent_id: '1002' }
        ],
        transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
        scenes: [
          {
            id: 'scene:doc:1',
            name: 'Scene 1',
            description: '',
            is_active_at_export: true,
            camera: { projection: 'perspective', eye_m: [10, 10, 10], target_m: [0, 0, 0], up: [0, 0, 1], field_of_view_degrees: 35.0, aspect_ratio: 1.0 },
            use_camera: true,
            transition_time_seconds: 0.0,
            visibility: {
              visible_tag_ids: ['tag:1'],
              hidden_tag_ids: [],
              visible_node_overrides: ['node:inst:1'],
              hidden_node_overrides: ['node:inst:2']
            },
            stores_tag_visibility: true,
            stores_hidden_objects: true,
            stores_hidden_geometry: false,
            stores_section_planes: false,
            section_state: { active_section_plane_ids: [], rendering_support: 'metadata-only' },
            visibility_signature: 'sig_override_1'
          }
        ]
      }

      packed = BOMCWriter.pack(graph)
      decoded = BOMCDecoder.decode(packed[:bytes])

      scene = decoded[:scenes].first
      assert_equal 1, scene.dig(:visibility, :visible_node_indices).length
      assert_equal 1, scene.dig(:visibility, :hidden_node_indices).length
      assert_equal [1], scene.dig(:visibility, :visible_node_indices) # node:inst:1 is index 1
      assert_equal [2], scene.dig(:visibility, :hidden_node_indices)  # node:inst:2 is index 2
    end

    def test_section_clip_plane_capture_and_scene_v5_resolution
      graph = {
        format: { name: 'canonical', version: '3.0.0' },
        materials: [{ id: 'mat:1', name: 'Material 1' }],
        tags: [{ id: 'tag:1', name: 'Tag 1', visible: true }],
        definitions: [
          { id: 'def:root', name: 'Root' },
          { id: 'def:table', name: 'Table', mesh_id: 'mesh:1' }
        ],
        meshes: [
          {
            id: 'mesh:1',
            definition_id: 'def:table',
            positions_m: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            faces: [{ id: 'f1', outer: [0, 1, 2], holes: [], triangles: [0, 1, 2], normal: [0.0, 0.0, 1.0], area_m2: 0.5, front_material_id: 'mat:1', tag_id: 'tag:1' }],
            edges: []
          }
        ],
        nodes: [
          { id: 'node:root', kind: 'root', name: 'Root', definition_id: 'def:root', transform_id: 0 },
          { id: 'node:table_1', kind: 'component_instance', name: 'Table 1', definition_id: 'def:table', transform_id: 0, persistent_id: '101' },
          { id: 'node:table_2', kind: 'component_instance', name: 'Table 2', definition_id: 'def:table', transform_id: 0, persistent_id: '102' }
        ],
        transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
        clip_planes: [
          {
            id: 'section:global_cut',
            source_persistent_id: '9001',
            origin_m: [0.0, 0.0, 1.2],
            normal: [0.0, 0.0, 1.0],
            keep_side: 1,
            flags: 1
          },
          {
            id: 'section:table_cut',
            source_persistent_id: '9002',
            origin_m: [0.5, 0.0, 0.0],
            normal: [1.0, 0.0, 0.0],
            keep_side: 1,
            owner_definition_id: 'def:table',
            owner_instance_id: 'node:table_1',
            flags: 1
          }
        ],
        scenes: [
          {
            id: 'scene:doc:1',
            name: 'Scene with Global Cut',
            description: '',
            is_active_at_export: true,
            camera: { projection: 'perspective', eye_m: [10, 10, 10], target_m: [0, 0, 0], up: [0, 0, 1], field_of_view_degrees: 35.0, aspect_ratio: 1.0 },
            use_camera: true,
            transition_time_seconds: 0.0,
            visibility: { visible_tag_ids: ['tag:1'], hidden_tag_ids: [], visible_node_overrides: [], hidden_node_overrides: [] },
            stores_tag_visibility: true,
            stores_hidden_objects: true,
            stores_hidden_geometry: false,
            stores_section_planes: true,
            section_state: { active_section_plane_ids: ['section:global_cut'], section_cuts_displayed: true },
            visibility_signature: 'sig_cut_1'
          },
          {
            id: 'scene:doc:2',
            name: 'Scene with Nested Cut',
            description: '',
            is_active_at_export: false,
            camera: { projection: 'perspective', eye_m: [10, 10, 10], target_m: [0, 0, 0], up: [0, 0, 1], field_of_view_degrees: 35.0, aspect_ratio: 1.0 },
            use_camera: true,
            transition_time_seconds: 0.0,
            visibility: { visible_tag_ids: ['tag:1'], hidden_tag_ids: [], visible_node_overrides: [], hidden_node_overrides: [] },
            stores_tag_visibility: true,
            stores_hidden_objects: true,
            stores_hidden_geometry: false,
            stores_section_planes: true,
            section_state: { active_section_plane_ids: ['section:table_cut'], section_cuts_displayed: true },
            visibility_signature: 'sig_cut_2'
          },
          {
            id: 'scene:doc:3',
            name: 'Scene without Cut',
            description: '',
            is_active_at_export: false,
            camera: { projection: 'perspective', eye_m: [10, 10, 10], target_m: [0, 0, 0], up: [0, 0, 1], field_of_view_degrees: 35.0, aspect_ratio: 1.0 },
            use_camera: true,
            transition_time_seconds: 0.0,
            visibility: { visible_tag_ids: ['tag:1'], hidden_tag_ids: [], visible_node_overrides: [], hidden_node_overrides: [] },
            stores_tag_visibility: true,
            stores_hidden_objects: true,
            stores_hidden_geometry: false,
            stores_section_planes: false,
            section_state: { active_section_plane_ids: [] },
            visibility_signature: 'sig_cut_3'
          }
        ]
      }

      packed = BOMCWriter.pack(graph)
      decoded = BOMCDecoder.decode(packed[:bytes])

      assert_equal 2, decoded[:clip_planes].length
      global_cut = decoded[:clip_planes][0]
      assert_equal 'section:global_cut', global_cut[:stable_id]
      assert_equal [0.0, 0.0, 1.2], global_cut[:origin_m]
      assert_equal [0.0, 0.0, 1.0], global_cut[:normal]
      assert_in_delta(-1.2, global_cut[:plane_constant], 1.0e-6)
      assert_nil global_cut[:owner_definition_id]

      nested_cut = decoded[:clip_planes][1]
      assert_equal 'section:table_cut', nested_cut[:stable_id]
      assert_equal 'def:table', nested_cut[:owner_definition_id]
      assert_equal 'node:table_1', nested_cut[:owner_instance_id]

      scenes = decoded[:scenes]
      assert_equal 3, scenes.length

      # Scene 1: references clip plane 0 (global)
      assert_equal ['section:global_cut'], scenes[0].dig(:section_state, :active_section_plane_ids)
      assert_equal [0], scenes[0].dig(:section_state, :active_clip_plane_indices)
      assert_equal 'full', scenes[0].dig(:section_state, :rendering_support)

      # Scene 2: references clip plane 1 (nested)
      assert_equal ['section:table_cut'], scenes[1].dig(:section_state, :active_section_plane_ids)
      assert_equal [1], scenes[1].dig(:section_state, :active_clip_plane_indices)
      assert_equal 'full', scenes[1].dig(:section_state, :rendering_support)

      # Scene 3: no active clip plane
      assert_equal [], scenes[2].dig(:section_state, :active_section_plane_ids)
      assert_equal [], scenes[2].dig(:section_state, :active_clip_plane_indices)
      assert_equal 'metadata-only', scenes[2].dig(:section_state, :rendering_support)
    end

    # 1. Official Page API surface regressions: Page DOES NOT have visible_entities or layer_visible?
    def test_official_page_api_surface_does_not_expose_fake_methods
      page = MockPage.new('PERS')
      assert_equal false, page.respond_to?(:visible_entities), 'Page MUST NOT expose visible_entities'
      assert_equal false, page.respond_to?(:layer_visible?), 'Page MUST NOT expose layer_visible?'
      assert_equal true, page.respond_to?(:get_drawingelement_visibility), 'Page MUST expose get_drawingelement_visibility'
      assert_equal true, page.respond_to?(:hidden_entities), 'Page MUST expose hidden_entities'
    end

    # 2. Conjunctive visibility: Hidden tag CANNOT be bypassed by positive DrawingElement state
    def test_hidden_tag_cannot_be_bypassed_by_positive_drawingelement_state
      layer_hidden = MockLayer.new('HiddenLayer', visible: true, persistent_id: '101')
      elem = MockDrawingElement.new('comp_1', layer: layer_hidden, hidden: false)
      page = MockPage.new('SCENE_TAG_HIDDEN', layers: [layer_hidden]) # layer_hidden is hidden in page

      # Force positive DrawingElement visibility
      page.define_singleton_method(:get_drawingelement_visibility) { |_ent| true }

      effective = SceneVisibilityResolver.effective_entity_visibility(elem, page)
      assert_equal false, effective, 'Positive DrawingElement visibility MUST NOT bypass hidden tag'
    end

    # 3. Conjunctive visibility: Hidden parent CANNOT be bypassed by positive child state
    def test_hidden_parent_cannot_be_bypassed_by_positive_child_state
      layer = MockLayer.new('Layer0', visible: true, persistent_id: '100')
      child_elem = MockDrawingElement.new('child_1', layer: layer, hidden: false)
      page = MockPage.new('SCENE_PARENT_HIDDEN')
      page.define_singleton_method(:get_drawingelement_visibility) { |_ent| true }

      effective = SceneVisibilityResolver.effective_entity_visibility(child_elem, page, parent_visibility: false)
      assert_equal false, effective, 'Positive child state MUST NOT make child visible through an invisible parent'
    end

    # 4. Conjunctive visibility: Base-hidden element unhidden in Scene with visible tag and ancestors is visible
    def test_base_hidden_element_unhidden_in_scene_is_visible
      layer = MockLayer.new('Layer0', visible: true, persistent_id: '100')
      elem_base_hidden = MockDrawingElement.new('comp_base_hidden', layer: layer, hidden: true)
      page = MockPage.new('SCENE_UNHIDE')
      page.define_singleton_method(:get_drawingelement_visibility) { |_ent| true }

      effective = SceneVisibilityResolver.effective_entity_visibility(elem_base_hidden, page, parent_visibility: true)
      assert_equal true, effective, 'Base-hidden element unhidden in Scene with visible tag & parent MUST be visible'
    end

    # 5. Non-unit section plane normalization (e.g. 2z - 100 = 0)
    def test_non_unit_section_plane_normalization
      plane_mock = Object.new
      # 2z - 100 = 0 -> [0, 0, 2, -100] -> normal [0, 0, 1], dist = -50 inches
      plane_mock.define_singleton_method(:get_plane) { [0.0, 0.0, 2.0, -100.0] }
      plane_mock.define_singleton_method(:persistent_id) { 'plane_nonunit' }
      plane_mock.define_singleton_method(:active?) { true }

      record = SceneVisibilityResolver.create_clip_plane_record(plane_mock)
      assert_equal [0.0, 0.0, 1.0], record[:normal], 'Normal must be normalized to unit vector'
      # -d_norm = 50 inches = 1.27 meters
      assert_in_delta 1.27, record[:origin_m][2], 1.0e-5, 'Origin Z must be 1.27 meters'
      assert_in_delta(-1.27, record[:plane_constant], 1.0e-5)
    end

    # 6. Truthful rendering_support: unresolvable active section plane produces 'metadata-only'
    def test_unresolved_active_section_plane_produces_metadata_only
      page = MockPage.new('SCENE_UNRESOLVED', use_section_planes: true, active_section_planes: [Object.new])
      page.define_singleton_method(:active_section_planes) { [] }
      page.define_singleton_method(:active_section_plane) { nil }
      # Override extract_active_section_planes to return an ID that does not exist in model
      def page.active_section_planes; ['section:nonexistent_id']; end

      profile = SceneVisibilityResolver.build_scene_profile(page)
      assert_equal 'metadata-only', profile.dig(:section_state, :rendering_support)
    end

    # 7. DrawingElement applicability: Nested faces/edges are not independently scene controlled
    def test_nested_face_edge_not_scene_applicable
      page = MockPage.new('SCENE_TEST', use_hidden_geometry: true)

      nested_face = Object.new
      nested_face.define_singleton_method(:parent) { Object.new } # Parent is a ComponentDefinition, not Model

      applicable = SceneVisibilityResolver.drawingelement_scene_applicable?(nested_face, page, is_root: false)
      assert_equal false, applicable, 'Nested faces must NOT be independently Scene-controlled'
    end
  end
end
