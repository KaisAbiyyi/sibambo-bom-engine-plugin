# frozen_string_literal: true
require 'test/unit'
require_relative '../bomc_sketchup_colorize'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

class TestBOMCSemanticColorize < Test::Unit::TestCase
  def test_matches_sketchup_reference_cpp_vector
    rgb = BOMEngine::BOMCSketchupColorize.colorize_pixel(
      115, 137, 98,
      92.58741048890613,
      0.13725490868091583,
      -0.11229892646129502,
      true
    )
    assert_equal [147, 156, 158], rgb
  end

  def test_semantic_verification_can_decline_an_over_budget_proof
    frame = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data).new(
      1, 1, 32, 0, "\x80\x80\x80\xff".b
    )
    result = BOMEngine::BOMCSketchupColorize.verify(
      uncolorized: frame, colorized: frame, mode: :shift,
      deltas: { h: 0, l: 0, s: 0 }, max_seconds: 0
    )
    assert_equal false, result[:passed]
    assert_equal :time_budget_exceeded, result[:reason]
  end

  def test_material_v2_round_trips_parametric_colorization
    graph = {
      materials: [{
        id: 'm', name: 'm', display_name: 'm',
        color: { r: 255, g: 255, b: 255, a: 255 }, opacity: 1.0,
        material_type: 2, semantic_colorize_active: true, colorize_type: 'shift',
        colorize_deltas: { h: 92.5, l: 0.1, s: -0.2 },
        colorize_output_sha256: 'ab' * 32
      }],
      definitions: [{ id: 'd', kind: 'root', node_ids: [] }],
      nodes: [{ id: 'root', kind: 'root', definition_id: 'd', transform_id: 0 }],
      transforms: [BOMEngine::BOMC::ModelAdapter::IDENTITY],
      meshes: [], tags: []
    }
    packed = BOMEngine::BOMCWriter.pack(graph, profile: :exact)
    material = BOMEngine::BOMCDecoder.decode(packed[:bytes])[:materials][0]

    assert_equal 2, material[:material_type]
    assert_equal true, material[:semantic_colorize_active]
    assert_equal 'shift', material[:colorize_type]
    assert_equal({ h: 92.5, l: 0.1, s: -0.2 }, material[:colorize_deltas])
    assert_equal 'ab' * 32, material[:colorize_output_sha256]
  end
end
