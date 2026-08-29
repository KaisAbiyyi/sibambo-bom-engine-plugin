# frozen_string_literal: true
# Unit tests for BOMC 1.2 Encoding Contract section (Batch 2)

require 'test/unit'
require_relative '../bomc_profile'
require_relative '../bomc_encoding_contract'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

class TestBOMCEncodingContract < Test::Unit::TestCase
  def test_exact_contract_round_trip
    contract = BOMEngine::BOMCProfile.fetch(:exact)
    bytes = BOMEngine::BOMCEncodingContract.encode(contract, source_skp_bytes: 0, target_bytes: 0)

    assert_equal 76, bytes.bytesize
    decoded = BOMEngine::BOMCEncodingContract.decode(bytes)

    assert_equal 1, decoded[:schema_version]
    assert_equal :exact, decoded[:profile]
    assert_equal false, decoded[:source_size_required]
    assert_equal 0, decoded[:source_skp_bytes]
    assert_nil decoded[:preferred_ratio]
    assert_nil decoded[:hard_ratio]
    assert_equal 0, decoded[:target_bytes]
    assert_in_delta 0.0, decoded[:position_max_error_m]
    assert_in_delta 0.0, decoded[:normal_max_error_deg]
    assert_in_delta 0.0, decoded[:uv_max_error]
    assert_in_delta 0.0, decoded[:transform_max_error]
    assert_equal :pixel_lossless, decoded[:texture_policy]
    assert_equal true, decoded[:semantic_exact]
    assert_equal true, decoded[:scene_exact]
    assert_equal true, decoded[:protected_topology_exact]
    assert_equal 1, decoded[:encoder_revision]
  end

  def test_research_contract_round_trip
    contract = BOMEngine::BOMCProfile.fetch(:research)
    bytes = BOMEngine::BOMCEncodingContract.encode(
      contract,
      source_skp_bytes: 10_000_000,
      target_bytes: 9_000_000,
      encoder_revision: 2
    )

    assert_equal 76, bytes.bytesize
    decoded = BOMEngine::BOMCEncodingContract.decode(bytes)

    assert_equal 1, decoded[:schema_version]
    assert_equal :research, decoded[:profile]
    assert_equal true, decoded[:source_size_required]
    assert_equal 10_000_000, decoded[:source_skp_bytes]
    assert_in_delta 0.90, decoded[:preferred_ratio]
    assert_in_delta 0.90, decoded[:hard_ratio]
    assert_equal 9_000_000, decoded[:target_bytes]
    assert_in_delta 0.0005, decoded[:position_max_error_m]
    assert_in_delta 0.1, decoded[:normal_max_error_deg]
    assert_in_delta 0.0001, decoded[:uv_max_error]
    assert_in_delta 0.00001, decoded[:transform_max_error]
    assert_equal :perceptual_bounded, decoded[:texture_policy]
    assert_equal true, decoded[:semantic_exact]
    assert_equal true, decoded[:scene_exact]
    assert_equal true, decoded[:protected_topology_exact]
    assert_equal 2, decoded[:encoder_revision]
  end

  def test_visual_contract_round_trip
    contract = BOMEngine::BOMCProfile.fetch(:visual)
    bytes = BOMEngine::BOMCEncodingContract.encode(
      contract,
      source_skp_bytes: 5_000_000,
      target_bytes: 3_000_000
    )

    assert_equal 76, bytes.bytesize
    decoded = BOMEngine::BOMCEncodingContract.decode(bytes)

    assert_equal 1, decoded[:schema_version]
    assert_equal :visual, decoded[:profile]
    assert_equal true, decoded[:source_size_required]
    assert_equal 5_000_000, decoded[:source_skp_bytes]
    assert_in_delta 0.60, decoded[:preferred_ratio]
    assert_in_delta 0.90, decoded[:hard_ratio]
    assert_equal 3_000_000, decoded[:target_bytes]
    assert_equal :semantic_policy, decoded[:position_max_error_m]
    assert_equal :semantic_policy, decoded[:normal_max_error_deg]
    assert_equal :semantic_policy, decoded[:uv_max_error]
    assert_in_delta 0.00001, decoded[:transform_max_error]
    assert_equal :web_aggressive_bounded, decoded[:texture_policy]
  end

  def test_rejects_corrupt_size_or_unknown_values
    good_bytes = BOMEngine::BOMCEncodingContract.encode(:visual)

    # Truncated
    assert_raise(RuntimeError) do
      BOMEngine::BOMCEncodingContract.decode(good_bytes[0, 50])
    end

    # Unknown schema version
    bad_schema = good_bytes.dup
    bad_schema.setbyte(0, 99)
    assert_raise(RuntimeError) do
      BOMEngine::BOMCEncodingContract.decode(bad_schema)
    end

    # Unknown profile enum
    bad_profile = good_bytes.dup
    bad_profile.setbyte(2, 99)
    assert_raise(RuntimeError) do
      BOMEngine::BOMCEncodingContract.decode(bad_profile)
    end
  end

  def test_writer_and_decoder_full_container_round_trip
    root = File.expand_path('../..', __dir__)
    fixture_path = File.join(root, 'examples', 'model-eval-json-v1-small.json')
    graph = JSON.parse(File.read(fixture_path), symbolize_names: true)

    packed = BOMEngine::BOMCWriter.pack(
      graph,
      profile: :research,
      source_skp_bytes: 50_000,
      target_bytes: 45_000
    )

    decoded = BOMEngine::BOMCDecoder.decode(packed[:bytes])
    contract = decoded[:encoding_contract]

    assert_not_nil contract, 'Decoded model must contain encoding_contract'
    assert_equal :research, contract[:profile]
    assert_equal 50_000, contract[:source_skp_bytes]
    assert_equal 45_000, contract[:target_bytes]
    assert_in_delta 0.90, contract[:hard_ratio]
  end
end
