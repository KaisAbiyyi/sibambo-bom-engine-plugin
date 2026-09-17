# frozen_string_literal: true

require 'test/unit'
require 'json'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'

class TestExactFidelityValidation < Test::Unit::TestCase
  def setup
    @graph = JSON.parse(File.read(File.expand_path('../../examples/canonical-v3-small.json', __dir__)), symbolize_names: true)
  end

  def round_trip
    BOMEngine::BOMCDecoder.decode(BOMEngine::BOMCWriter.pack(@graph, profile: :exact).fetch(:bytes))
  end

  def report(decoded)
    BOMEngine::BOMCValidator.validate_profile(source: @graph, decoded: decoded, profile: :exact)
  end

  def test_identical_oblique_normal_has_zero_error
    # Real RUMAH L JSON normal: acos(dot(n,n)) used to report ~1e-6 degrees.
    normal = [0.0, 0.8660211847456428, 0.5000073075183536]
    @graph[:meshes][0][:faces][0][:normal] = normal
    decoded = round_trip
    assert_equal normal, decoded[:meshes][0][:faces][0][:normal]
    result = report(decoded)
    assert_equal [], result[:failures]
    assert_equal 0.0, result[:domains][:normals][:max_angular_error_deg]
  end

  def test_exact_normal_magnitude_changes_are_not_hidden_by_equal_direction
    decoded = round_trip
    decoded[:meshes][0][:faces][0][:normal] = [0.0, 0.0, 2.0]
    assert_include report(decoded)[:failures], 'normals'
  end

  def test_area_fidelity_compares_input_geometry_not_independently_rounded_metadata
    # The 1x1 source square is preserved, while the independently supplied area
    # is already different before encoding. Keep that discrepancy visible.
    @graph[:meshes][0][:faces][0][:area_m2] = 1.00000005
    decoded = round_trip
    assert_equal 1.0, decoded[:meshes][0][:faces][0][:area_m2]
    result = report(decoded)
    assert_equal [], result[:failures]
    assert_equal 0.0, result[:domains][:areas][:max_error_m2]
    assert_equal 'source_geometry', result[:domains][:areas][:basis]
    assert_in_delta 5.0e-8, result[:domains][:areas][:source_metadata_max_delta_m2], 1.0e-15
  end

  def test_area_corruption_cannot_pass_by_matching_the_source_metadata
    @graph[:meshes][0][:faces][0][:area_m2] = 1.00000005
    decoded = round_trip
    decoded[:meshes][0][:faces][0][:area_m2] = 1.00000005
    assert_include report(decoded)[:failures], 'areas'
  end

  def test_area_fallback_subtracts_holes_without_triangles
    mesh = @graph[:meshes][0]
    mesh[:positions_m] = [0,0,0, 4,0,0, 4,4,0, 0,4,0, 1,1,0, 1,3,0, 3,3,0, 3,1,0]
    face = mesh[:faces][0]
    face[:triangles] = []
    face[:holes] = [[4,5,6,7]]
    face[:area_m2] = 12.00000005
    decoded = round_trip
    assert_equal 12.0, decoded[:meshes][0][:faces][0][:area_m2]
    assert_equal [], report(decoded)[:failures]
  end

  def test_actual_geometry_and_nonfinite_normal_corruption_still_fail
    decoded = round_trip
    decoded[:meshes][0][:positions][3] += 0.001
    assert_include report(decoded)[:failures], 'positions'
    decoded = round_trip
    decoded[:meshes][0][:faces][0][:normal] = [0.0, 0.0, Float::INFINITY]
    assert_include report(decoded)[:failures], 'normals'
  end
end
