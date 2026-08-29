# frozen_string_literal: true
# Unit tests for BOMC 1.2 True Exact Profile (Batch 3)

require 'test/unit'
require 'json'
require_relative '../bomc_profile'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_codecs'

class TestBOMCExactProfile < Test::Unit::TestCase
  def setup
    root = File.expand_path('../..', __dir__)
    fixture_path = File.join(root, 'examples', 'model-eval-json-v1-small.json')
    @graph = JSON.parse(File.read(fixture_path), symbolize_names: true)
  end

  def test_exact_profile_codecs_and_zero_error
    packed = BOMEngine::BOMCWriter.pack(@graph, profile: :exact)
    metrics = packed[:metrics]

    # Positions: FLOAT64_ABSOLUTE (1), max error 0.0
    metrics[:positions].each do |pos_metric|
      assert_equal BOMEngine::BOMC::PositionCodec::FLOAT64_ABSOLUTE, pos_metric[:codec], 'Position codec must be FLOAT64_ABSOLUTE'
      assert_in_delta 0.0, pos_metric.dig(:errors, :max), 1e-12
    end

    # Normals: FLOAT64 (3), max error 0.0
    assert_equal BOMEngine::BOMC::NormalCodec::FLOAT64, metrics.dig(:normals, :codec), 'Normal codec must be FLOAT64'
    assert_in_delta 0.0, metrics.dig(:normals, :errors, :max), 1e-12

    # UVs: FLOAT64 (5), max error 0.0
    metrics[:uv].each do |uv_metric|
      assert_equal BOMEngine::BOMC::UVCodec::FLOAT64, uv_metric[:codec], 'UV codec must be FLOAT64'
      assert_in_delta 0.0, uv_metric.dig(:errors, :max), 1e-12
    end

    # Transforms: FLOAT64_3X4 (1), max error 0.0
    assert_equal BOMEngine::BOMC::TransformCodec::FLOAT64_3X4, metrics.dig(:transforms, :codec), 'Transform codec must be FLOAT64_3X4'
    assert_in_delta 0.0, metrics.dig(:transforms, :errors, :max), 1e-12
  end

  def test_exact_profile_round_trip_fidelity
    packed = BOMEngine::BOMCWriter.pack(@graph, profile: :exact)
    decoded = BOMEngine::BOMCDecoder.decode(packed[:bytes])

    # Contract verification
    contract = decoded[:encoding_contract]
    assert_not_nil contract
    assert_equal :exact, contract[:profile]
    assert_equal false, contract[:source_size_required]
    assert_equal :pixel_lossless, contract[:texture_policy]
    assert_in_delta 0.0, contract[:position_max_error_m], 1e-12
    assert_in_delta 0.0, contract[:normal_max_error_deg], 1e-12
    assert_in_delta 0.0, contract[:uv_max_error], 1e-12
    assert_in_delta 0.0, contract[:transform_max_error], 1e-12

    normalized = BOMEngine::BOMC::ModelAdapter.normalize(@graph)

    # Positions round trip exactly
    decoded[:meshes].each_with_index do |mesh, mesh_idx|
      input_mesh = normalized[:meshes][mesh_idx]
      assert_equal input_mesh[:positions].length, mesh[:positions].length
      input_mesh[:positions].each_with_index do |expected_val, idx|
        assert_equal expected_val.to_f, mesh[:positions][idx], "Position mismatch at mesh #{mesh_idx} index #{idx}"
      end
    end

    # Normals round trip exactly
    decoded[:meshes].each_with_index do |mesh, mesh_idx|
      input_mesh = normalized[:meshes][mesh_idx]
      mesh[:faces].each_with_index do |face, face_idx|
        expected_normal = input_mesh[:faces][face_idx][:normal]
        assert_equal expected_normal.map(&:to_f), face[:normal], "Normal mismatch at mesh #{mesh_idx} face #{face_idx}"
      end
    end

    # Transforms round trip exactly
    normalized[:transforms].each_with_index do |expected_transform, idx|
      decoded_transform = decoded[:transforms][idx]
      expected_transform.each_with_index do |val, val_idx|
        assert_in_delta val.to_f, decoded_transform[val_idx], 1e-12, "Transform mismatch at transform #{idx} [#{val_idx}]"
      end
    end
  end

  def test_exact_profile_determinism
    pack1 = BOMEngine::BOMCWriter.pack(@graph, profile: :exact)
    pack2 = BOMEngine::BOMCWriter.pack(@graph, profile: :exact)

    assert_equal pack1[:sha256], pack2[:sha256], 'Exact profile output must be byte-deterministic'
    assert_equal pack1[:bytes], pack2[:bytes]
  end
end
