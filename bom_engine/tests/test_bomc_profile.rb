# frozen_string_literal: true
# Unit tests for BOMC Profile contracts (Batch 1)

require 'test/unit'
require_relative '../bomc_profile'

class TestBOMCProfile < Test::Unit::TestCase
  def test_supported_profile_names
    assert_equal [:exact, :research, :visual], BOMEngine::BOMCProfile.names
  end

  def test_exact_profile_contract
    p = BOMEngine::BOMCProfile.fetch(:exact)
    assert_equal :exact, p.name
    assert_equal false, p.requires_source_size
    assert_equal false, p.requires_source_size?
    assert_nil p.preferred_ratio
    assert_nil p.hard_ratio
    assert_equal 0.0, p.position_error_m
    assert_equal 0.0, p.normal_error_deg
    assert_equal 0.0, p.uv_error
    assert_equal 0.0, p.transform_error
    assert_equal :pixel_lossless, p.texture_policy
    assert_equal :exact, p.geometry_policy
    assert_equal false, p.allow_topology_simplification
    assert_equal false, p.allow_topology_simplification?
    assert p.frozen?
  end

  def test_research_profile_contract
    p = BOMEngine::BOMCProfile.fetch(:research)
    assert_equal :research, p.name
    assert_equal true, p.requires_source_size
    assert_equal true, p.requires_source_size?
    assert_equal 0.90, p.preferred_ratio
    assert_equal 0.90, p.hard_ratio
    assert_equal 0.0005, p.position_error_m
    assert_equal 0.1, p.normal_error_deg
    assert_equal 0.0001, p.uv_error
    assert_equal 0.00001, p.transform_error
    assert_equal :perceptual_bounded, p.texture_policy
    assert_equal :bounded_error, p.geometry_policy
    assert_equal false, p.allow_topology_simplification
    assert p.frozen?
  end

  def test_visual_profile_contract
    p = BOMEngine::BOMCProfile.fetch(:visual)
    assert_equal :visual, p.name
    assert_equal true, p.requires_source_size
    assert_equal true, p.requires_source_size?
    assert_equal 0.60, p.preferred_ratio
    assert_equal 0.90, p.hard_ratio
    assert_equal :semantic_policy, p.position_error_m
    assert_equal :semantic_policy, p.normal_error_deg
    assert_equal :semantic_policy, p.uv_error
    assert_equal 0.00001, p.transform_error
    assert_equal :web_aggressive_bounded, p.texture_policy
    assert_equal :semantic_bounded, p.geometry_policy
    assert_equal false, p.allow_topology_simplification
    assert p.frozen?
  end

  def test_case_insensitive_and_string_lookups
    assert_same BOMEngine::BOMCProfile.fetch(:exact), BOMEngine::BOMCProfile.fetch('exact')
    assert_same BOMEngine::BOMCProfile.fetch(:exact), BOMEngine::BOMCProfile.fetch('EXACT')
    assert_same BOMEngine::BOMCProfile.fetch(:research), BOMEngine::BOMCProfile.fetch('Research')
    assert_same BOMEngine::BOMCProfile.fetch(:visual), BOMEngine::BOMCProfile.fetch('VISUAL')
  end

  def test_unknown_profile_raises_clear_error
    err = assert_raise(ArgumentError) do
      BOMEngine::BOMCProfile.fetch(:maximum_lossless)
    end
    assert err.message.include?('maximum_lossless')
    assert err.message.include?('exact, research, visual')

    assert_raise(ArgumentError) do
      BOMEngine::BOMCProfile.fetch(:standard)
    end
    assert_raise(ArgumentError) do
      BOMEngine::BOMCProfile.fetch(:compact)
    end
    assert_raise(ArgumentError) do
      BOMEngine::BOMCProfile.fetch(:non_existent)
    end
  end

  def test_immutability
    p = BOMEngine::BOMCProfile.fetch(:exact)
    assert p.frozen?
    assert_raise(FrozenError, RuntimeError) do
      p.instance_variable_set(:@hard_ratio, 0.5)
    end
  end
end
