# frozen_string_literal: true

require 'test/unit'
require_relative 'sketchup_mock_helper' unless defined?(Sketchup)
require_relative '../scene_visibility_resolver'
require_relative '../canonical_graph_builder'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

class TestSceneSectionCutDisplay < Test::Unit::TestCase
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
    @plane = Sketchup::SectionPlane.new([0.0, 0.0, 1.0, -50.0])
    @model.entities.add_section_plane([0.0, 0.0, 50.0], [0.0, 0.0, 1.0])
    @plane = @model.entities.to_a.last
  end

  def page(name, cuts_displayed)
    page = @model.pages.add(name)
    page.use_section_planes = true
    page.active_section_planes = [@plane]
    page.use_rendering_options = true
    page.rendering_options['DisplaySectionCuts'] = cuts_displayed
    page.rendering_options['DisplaySectionPlanes'] = false
    page
  end

  def test_active_plane_without_displayed_cuts_is_metadata_only_and_roundtrips
    page('CUT_OFF', false)
    page('CUT_ON', true)

    graph = BOMEngine::CanonicalGraphBuilder.build(
      model: @model,
      entities: @model.entities,
      parent_transform: Geom::Transformation.new,
      settings: { scene_scope: 'all', output_format: 'bomc_v1_1' },
      spatial: {},
      texture_writer: nil
    )

    off = graph[:scenes].find { |scene| scene[:name] == 'CUT_OFF' }
    on = graph[:scenes].find { |scene| scene[:name] == 'CUT_ON' }
    plane_id = "section:#{@plane.persistent_id}"
    assert_equal [plane_id], off.dig(:section_state, :active_section_plane_ids)
    assert_equal [plane_id], on.dig(:section_state, :active_section_plane_ids)
    assert_equal false, off.dig(:section_state, :section_cuts_displayed)
    assert_equal true, on.dig(:section_state, :section_cuts_displayed)
    assert_equal 'metadata-only', off.dig(:section_state, :rendering_support)
    assert_equal 'full', on.dig(:section_state, :rendering_support)

    decoded = BOMEngine::BOMCDecoder.decode(BOMEngine::BOMCWriter.pack(graph)[:bytes])
    decoded_off = decoded[:scenes].find { |scene| scene[:name] == 'CUT_OFF' }
    decoded_on = decoded[:scenes].find { |scene| scene[:name] == 'CUT_ON' }
    assert_equal false, decoded_off.dig(:section_state, :section_cuts_displayed)
    assert_equal [], decoded_off.dig(:section_state, :active_clip_plane_indices)
    assert_equal 'metadata-only', decoded_off.dig(:section_state, :rendering_support)
    assert_equal true, decoded_on.dig(:section_state, :section_cuts_displayed)
    assert_equal [0], decoded_on.dig(:section_state, :active_clip_plane_indices)
    assert_equal 'full', decoded_on.dig(:section_state, :rendering_support)
  end

  def test_four_scene_transition_preserves_same_plane_but_toggles_execution
    [true, false, true, false].each_with_index { |displayed, index| page("CUT_#{index}", displayed) }
    scenes = BOMEngine::SceneVisibilityResolver.resolve_scenes(@model)
    states = scenes.sort_by { |scene| scene[:name] }.map { |scene| scene.dig(:section_state, :section_cuts_displayed) }
    assert_equal [true, false, true, false], states
    plane_id = "section:#{@plane.persistent_id}"
    assert_equal 4, scenes.count { |scene| scene.dig(:section_state, :active_section_plane_ids) == [plane_id] }
    assert_equal 2, scenes.count { |scene| scene.dig(:section_state, :rendering_support) == 'full' }
    assert_equal 2, scenes.count { |scene| scene.dig(:section_state, :rendering_support) == 'metadata-only' }
  end
end
