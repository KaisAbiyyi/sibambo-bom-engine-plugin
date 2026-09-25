# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require_relative '../bomc_extension'
require_relative 'sketchup_mock_helper'
require_relative '../constants'
require_relative '../traversal'
require_relative '../semantic_labeler'
require_relative '../canonical_graph_builder'
require_relative '../material_extractor'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

class TestExactHiddenGeometry < Test::Unit::TestCase
  def test_exact_retains_hidden_face_and_group_but_visual_keeps_scene_scope
    model = Sketchup::Model.new
    model.entities.add_face([0, 0, 0], [10, 0, 0], [0, 10, 0])
    hidden_face = model.entities.add_face([-10, 0, 0], [-20, 0, 0], [-10, 10, 0])
    hidden_face.hidden = true
    hidden_group = model.entities.add_group
    hidden_group.hidden = true
    hidden_group.entities.add_face([0, 0, 0], [5, 0, 0], [0, 5, 0])

    common = { model: model, entities: model.entities,
      parent_transform: Geom::Transformation.new, spatial: {} }
    visual = BOMEngine::CanonicalGraphBuilder.build(**common,
      settings: { include_edges: false, scene_scope: 'all' })
    exact = BOMEngine::CanonicalGraphBuilder.build(**common,
      settings: { include_edges: false, scene_scope: 'all', preserve_hidden_geometry: true })

    assert_equal 1, visual[:meshes].sum { |mesh| mesh[:faces].length }
    assert_equal 0, visual[:nodes].count { |node| node[:kind] == 'group_instance' }
    assert_equal 3, exact[:meshes].sum { |mesh| mesh[:faces].length }
    assert_equal 1, exact[:nodes].count { |node| node[:kind] == 'group_instance' }

    decoded = BOMEngine::BOMCDecoder.decode(BOMEngine::BOMCWriter.pack(exact, profile: :exact)[:bytes])
    assert_equal 3, decoded[:meshes].sum { |mesh| mesh[:faces].length }
    assert_equal 1, decoded[:meshes].sum { |mesh| mesh[:faces].count { |face| face[:hidden] } }
    assert_equal false, decoded[:instances].find { |instance| instance[:kind] == 'group_instance' }[:visible]
  end

  def test_profile_snapshot_routes_hidden_preservation_only_to_exact
    model = Sketchup::Model.new
    face = model.entities.add_face([0, 0, 0], [10, 0, 0], [0, 10, 0])
    face.hidden = true
    Dir.mktmpdir('exact-hidden-snapshot') do |directory|
      checkpoint = ->(**_event) {}
      visual = BOMEngine::BOMCExtension.send(:snapshot_model, model, directory, checkpoint, profile: :visual)
      exact = BOMEngine::BOMCExtension.send(:snapshot_model, model, directory, checkpoint, profile: :exact)
      assert_equal 0, visual[:meshes].sum { |mesh| mesh[:faces].length }
      assert_equal 1, exact[:meshes].sum { |mesh| mesh[:faces].length }
      assert_equal true, exact[:meshes].first[:faces].first[:hidden]
    end
  end
end
