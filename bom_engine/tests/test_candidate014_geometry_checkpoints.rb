# frozen_string_literal: true
require 'test/unit'
require_relative '../bomc_codecs'

class TestCandidate014GeometryCheckpoints < Test::Unit::TestCase
  def test_uv_codec_math_maps_same_values_with_more_bounded_checkpoints
    values = (0...130).map(&:to_f)
    events = []
    with_poll = BOMEngine::BOMC::CodecMath.map(values, ->(**event) { events << event }, :encode_uv) do |value,_|
      value * 2.0
    end
    without_poll = BOMEngine::BOMC::CodecMath.map(values, nil, :encode_uv) { |value,_| value * 2.0 }
    assert_equal without_poll, with_poll
    assert_equal [1,2,3,4], events.map { |event| event.fetch(:processed) }
  end

  def test_topology_checkpoint_responds_before_original_1024_items
    events = []
    100.times { |index| BOMEngine::BOMC::CodecMath.poll(->(**event) { events << event }, :encode_topology, index, 100) }
    assert_equal [1,2,3], events.map { |event| event.fetch(:processed) }
    assert(events.all? { |event| event[:stage] == :encode_topology })
  end

  def test_non_geometry_poll_cadence_unchanged
    events = []
    2000.times { |index| BOMEngine::BOMC::CodecMath.poll(->(**event) { events << event }, :encode_positions, index, 2000) }
    assert_equal [1], events.map { |event| event.fetch(:processed) }
  end

  def test_uv_candidate_error_summary_is_bit_identical_to_original_scalar_formula
    source = Array.new(1000) { |index| Math.sin(index * 0.5) }
    decoded = source.each_with_index.map do |value, index|
      value + ((index % 3) - 1) * 0.0000001
    end
    original = source.each_slice(2).each_with_index.map do |pair, index|
      offset = index * 2
      Math.sqrt(2.times.map { |axis| (pair[axis] - decoded[offset + axis])**2 }.inject(0.0, :+))
    end
    expected = BOMEngine::BOMC::CodecMath.error_summary(original)
    events = []
    report = BOMEngine::BOMC::UVCodec.send(:uv_candidate, 'test', 1, ''.b,
      [0,0], [0,0], source, decoded, 0.01, 0, :class_a,
      ->(**event) { events << event })
    assert_equal expected, report[:errors]
    assert_equal true, report[:passed]
    assert_equal (1..15).to_a, events.filter_map { |event| event[:processed] if event[:stage] == :encode_uv }
  end
end
