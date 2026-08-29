# frozen_string_literal: true
require 'test/unit'
require_relative '../scene_clip_program'

class TestSceneClipProgram < Test::Unit::TestCase
  def test_create_plane_normal_and_constant
    plane = BOMEngine::SceneClipProgram.create_plane(
      stable_id: 'section:plane_1',
      source_persistent_id: '12345',
      origin_m: [0.0, 0.0, 2.5],
      normal: [0.0, 0.0, 2.0], # Unnormalized normal
      keep_side: 1
    )

    assert_equal 'section:plane_1', plane[:stable_id]
    assert_equal '12345', plane[:source_persistent_id]
    assert_equal [0.0, 0.0, 2.5], plane[:origin_m]
    assert_in_delta 0.0, plane[:normal][0], 1.0e-9
    assert_in_delta 0.0, plane[:normal][1], 1.0e-9
    assert_in_delta 1.0, plane[:normal][2], 1.0e-9
    # dot([0, 0, 1], [0, 0, 2.5]) = 2.5 => plane_constant = -2.5
    assert_in_delta(-2.5, plane[:plane_constant], 1.0e-9)
    assert_equal 1, plane[:keep_side]
  end

  def test_encode_and_decode_clip_planes_section
    p1 = BOMEngine::SceneClipProgram.create_plane(
      stable_id: 'section:root_cut',
      source_persistent_id: '1001',
      origin_m: [1.0, 2.0, 3.0],
      normal: [1.0, 0.0, 0.0],
      keep_side: 1,
      flags: 1
    )

    p2 = BOMEngine::SceneClipProgram.create_plane(
      stable_id: 'section:nested_cut',
      source_persistent_id: '2002',
      origin_m: [0.5, 0.5, 1.0],
      normal: [0.0, 1.0, 0.0],
      keep_side: 1,
      owner_definition_id: 'def:table',
      owner_instance_id: 'node:table_1',
      flags: 2
    )

    planes = [p1, p2]
    strings = ['section:root_cut', '1001', 'section:nested_cut', '2002', 'def:table', 'node:table_1'].uniq.sort
    string_index = {}
    strings.each_with_index { |s, idx| string_index[s] = idx }

    bytes = BOMEngine::SceneClipProgram.build_section(planes, string_index)
    assert_not_nil bytes
    assert_equal 8 + 80 * 2, bytes.bytesize

    decoded = BOMEngine::SceneClipProgram.decode_section(bytes, strings)
    assert_equal 2, decoded.length

    d1 = decoded[0]
    assert_equal 'section:root_cut', d1[:stable_id]
    assert_equal '1001', d1[:source_persistent_id]
    assert_equal [1.0, 2.0, 3.0], d1[:origin_m]
    assert_equal [1.0, 0.0, 0.0], d1[:normal]
    assert_in_delta(-1.0, d1[:plane_constant], 1.0e-9)
    assert_nil d1[:owner_definition_id]
    assert_nil d1[:owner_instance_id]
    assert_equal 1, d1[:flags]

    d2 = decoded[1]
    assert_equal 'section:nested_cut', d2[:stable_id]
    assert_equal '2002', d2[:source_persistent_id]
    assert_equal [0.5, 0.5, 1.0], d2[:origin_m]
    assert_equal [0.0, 1.0, 0.0], d2[:normal]
    assert_in_delta(-0.5, d2[:plane_constant], 1.0e-9)
    assert_equal 'def:table', d2[:owner_definition_id]
    assert_equal 'node:table_1', d2[:owner_instance_id]
    assert_equal 2, d2[:flags]
  end

  def test_rejects_truncated_clip_plane_section
    strings = ['a', 'b']
    string_index = { 'a' => 0, 'b' => 1 }
    p = BOMEngine::SceneClipProgram.create_plane(
      stable_id: 'a', source_persistent_id: 'b', origin_m: [0, 0, 0], normal: [0, 0, 1]
    )
    bytes = BOMEngine::SceneClipProgram.build_section([p], string_index)
    truncated = bytes[0..30]

    assert_raise(RuntimeError) do
      BOMEngine::SceneClipProgram.decode_section(truncated, strings)
    end
  end
end
