# frozen_string_literal: true

require 'test/unit'
require_relative '../scene_visibility_resolver'

module BOMEngine
  class TestSceneTagFolderTruth < Test::Unit::TestCase
    class MockFolder
      attr_accessor :visible, :folder

      def initialize(visible: true, folder: nil)
        @visible = visible
        @folder = folder
      end

      def visible?
        @visible
      end
    end

    class MockLayer
      attr_accessor :visible, :folder, :page_behavior, :persistent_id, :name

      def initialize(name, visible: true, folder: nil, page_behavior: 0)
        @name = name
        @visible = visible
        @folder = folder
        @page_behavior = page_behavior
        @persistent_id = name
      end

      def visible?
        @visible
      end
    end

    class MockPages
      attr_accessor :selected_page

      def initialize(pages = [])
        @pages = pages
        pages.each { |page| page.parent = self }
      end

      def to_a
        @pages
      end
    end

    class MockPage
      attr_accessor :name, :layers, :layer_folders, :parent

      def initialize(name, layers: [], layer_folders: [], use_hidden_layers: true)
        @name = name
        @layers = layers
        @layer_folders = layer_folders
        @use_hidden_layers = use_hidden_layers
      end

      def use_hidden_layers?
        @use_hidden_layers
      end
    end

    class MockModel
      attr_accessor :pages

      def initialize(pages)
        @pages = MockPages.new(pages)
      end
    end

    class MockEntity
      attr_reader :layer

      def initialize(layer)
        @layer = layer
      end

      def deleted?; false; end
      def hidden?; false; end
      def visible?; true; end
    end

    def test_selected_page_uses_live_tag_visibility_even_when_page_layers_snapshot_differs
      layer = MockLayer.new('ARCH', visible: true)
      selected = MockPage.new('PERS', layers: [layer])
      pages = MockPages.new([selected])
      pages.selected_page = selected

      assert_equal true, SceneVisibilityResolver.effective_tag_visibility(layer, selected),
        'The selected SketchUp Page must use the live Layer#visible? state.'
    end

    def test_nonselected_scene_does_not_inherit_current_folder_hidden_state
      struct_folder = MockFolder.new(visible: false)
      struct_layer = MockLayer.new('STRUCT', visible: true, folder: struct_folder)
      pers = MockPage.new('PERS', layer_folders: [struct_folder])
      str = MockPage.new('STR', layer_folders: [])
      pages = MockPages.new([pers, str])
      pages.selected_page = pers

      assert_equal true, SceneVisibilityResolver.effective_tag_visibility(struct_layer, str),
        'A folder hidden in the currently selected PERS scene must still be visible in STR when STR does not hide it.'
    end

    def test_union_keeps_geometry_visible_only_in_nonselected_str_folder_state
      struct_folder = MockFolder.new(visible: false)
      struct_layer = MockLayer.new('STRUCT', visible: true, folder: struct_folder)
      pers = MockPage.new('PERS', layer_folders: [struct_folder])
      str = MockPage.new('STR', layer_folders: [])
      model = MockModel.new([pers, str])
      model.pages.selected_page = pers
      entity = MockEntity.new(struct_layer)

      assert_equal true, SceneVisibilityResolver.exportable_universe?(entity, [], model: model, scope: 'all'),
        'STR-only geometry must survive the canonical all-scenes union even while its folder is hidden in PERS.'
    end

    def test_target_page_hidden_folder_hides_tag
      struct_folder = MockFolder.new(visible: true)
      struct_layer = MockLayer.new('STRUCT', visible: true, folder: struct_folder)
      str = MockPage.new('STR', layer_folders: [struct_folder])
      MockPages.new([str])

      assert_equal false, SceneVisibilityResolver.effective_tag_visibility(struct_layer, str)
    end
  end
end
