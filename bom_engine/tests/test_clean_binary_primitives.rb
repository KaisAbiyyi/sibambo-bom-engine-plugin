# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../clean_analysis/binary/section_writer'
require_relative '../clean_analysis/binary/position_codec'

class CleanBinaryPrimitivesTest < Minitest::Test
  def test_section_writer_aligns_float64_and_emits_little_endian_types
    writer = BOMEngine::CleanAnalysis::Binary::SectionWriter.new
    u16 = writer.add('small_indices', [1, 256, 65_535], component_type: 'uint16', components: 1)
    f64 = writer.add('areas', [1.5], component_type: 'float64', components: 1)
    u32 = writer.add('large_indices', [70_000], component_type: 'uint32', components: 1)

    assert_equal 0, u16.fetch('byte_offset')
    assert_equal 6, u16.fetch('byte_length')
    assert_equal 8, f64.fetch('byte_offset')
    assert_equal 2, writer.padding_bytes
    assert_equal [1, 256, 65_535], writer.bytes.byteslice(0, 6).unpack('S<*')
    assert_equal [1.5], writer.bytes.byteslice(8, 8).unpack('E*')
    assert_equal [70_000], writer.bytes.byteslice(u32.fetch('byte_offset'), 4).unpack('L<*')
  end

  def test_quantized_int32_local_positions_pass_one_micrometre_budget
    points = [
      [5.333000011, 13.080000015, 8.6],
      [6.487700552, 11.925299473, 10.6],
      [-2.000000499, 20.000000499, -0.25]
    ]

    encoded = BOMEngine::CleanAnalysis::Binary::PositionCodec.encode(points, tolerance: 1.0e-6)
    decoded = BOMEngine::CleanAnalysis::Binary::PositionCodec.decode(encoded)

    assert_equal 'int32', encoded.fetch(:component_type)
    assert_equal 1.0e-6, encoded.fetch(:scale)
    assert_operator encoded.dig(:metrics, :max_error), :<=, 5.000001e-7
    assert_operator encoded.dig(:metrics, :p95_error), :<=, 5.000001e-7
    assert_operator encoded.dig(:metrics, :rms_error), :<=, 5.000001e-7
    points.flatten.zip(decoded.flatten).each do |source, roundtrip|
      assert_in_delta source, roundtrip, 1.0e-6
    end
  end

  def test_codec_reports_float32_candidate_error
    points = [[70.123456789, -631.36521701, 0.0], [71.987654321, 674.07019568, 3.0]]

    benchmark = BOMEngine::CleanAnalysis::Binary::PositionCodec.benchmark(points, tolerance: 1.0e-6)

    assert_equal 0.0, benchmark.dig(:float64, :max_error)
    assert_operator benchmark.dig(:float32_relative, :max_error), :>, 0.0
    assert_operator benchmark.dig(:int32_relative, :max_error), :<=, 5.000001e-7
  end

  def test_float64_fallback_when_int32_range_and_float32_accuracy_fail
    points = [[0.0, 0.0, 0.0], [5000.123456789, 0.0, 0.0]]

    encoded = BOMEngine::CleanAnalysis::Binary::PositionCodec.encode(points, tolerance: 1.0e-6)

    assert_equal 'float64', encoded.fetch(:component_type)
    assert_nil encoded.fetch(:scale)
    assert_equal points.flatten, encoded.fetch(:values)
  end
end
