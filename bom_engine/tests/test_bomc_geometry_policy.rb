# frozen_string_literal: true
# Unit tests for BOMC Semantic-Aware Geometry Policy (Batch 5)

require 'test/unit'
require_relative '../bomc_geometry_policy'
require_relative '../bomc_codecs'

class TestBOMCGeometryPolicy < Test::Unit::TestCase
  def test_semantic_role_classification
    # Class A: Protected analytical
    [:wall, :exterior_wall, :interior_wall, :floor, :ceiling, :roof, :door, :window, :column, :beam, :stair, :foundation, :structure, :room, :room_boundary].each do |role|
      assert_equal :class_a, BOMEngine::BOMCGeometryPolicy.classify_role(role), "Role #{role} must classify as class_a"
    end

    # Class C: Decorative / site
    [:furniture, :landscape, :site, :decorative, :planting].each do |role|
      assert_equal :class_c, BOMEngine::BOMCGeometryPolicy.classify_role(role), "Role #{role} must classify as class_c"
    end

    # Class B: Functional visual / unknown fallback
    [:railing, :fixture, :equipment, :facade, :unknown, :something_else, nil, ''].each do |role|
      assert_equal :class_b, BOMEngine::BOMCGeometryPolicy.classify_role(role), "Role #{role} must classify as class_b"
    end
  end

  def test_mesh_semantic_class_precedence
    # Analytical face elevates entire mesh to Class A
    mesh_with_wall = [{ semantic_role: :wall }, { semantic_role: :furniture }]
    assert_equal :class_a, BOMEngine::BOMCGeometryPolicy.mesh_semantic_class(mesh_with_wall)

    # Functional face elevates above decorative
    mesh_with_railing = [{ semantic_role: :railing }, { semantic_role: :furniture }]
    assert_equal :class_b, BOMEngine::BOMCGeometryPolicy.mesh_semantic_class(mesh_with_railing)

    # Pure decorative
    mesh_furniture = [{ semantic_role: :furniture }, { semantic_role: :planting }]
    assert_equal :class_c, BOMEngine::BOMCGeometryPolicy.mesh_semantic_class(mesh_furniture)

    # Empty / unknown faces default to Class B
    assert_equal :class_b, BOMEngine::BOMCGeometryPolicy.mesh_semantic_class([])
    assert_equal :class_b, BOMEngine::BOMCGeometryPolicy.mesh_semantic_class([{ semantic_role: :unknown }])
  end

  def test_exact_profile_tolerances
    [:class_a, :class_b, :class_c].each do |klass|
      assert_equal 0.0, BOMEngine::BOMCGeometryPolicy.position_tolerance(profile: :exact, semantic_class: klass)
      assert_equal 0.0, BOMEngine::BOMCGeometryPolicy.normal_tolerance(profile: :exact, semantic_class: klass)
      assert_equal 0.0, BOMEngine::BOMCGeometryPolicy.uv_tolerance(profile: :exact, semantic_class: klass)
    end
    assert_equal 0.0, BOMEngine::BOMCGeometryPolicy.transform_tolerance(profile: :exact)
  end

  def test_research_profile_tolerances
    [:class_a, :class_b, :class_c].each do |klass|
      assert_in_delta 0.0005, BOMEngine::BOMCGeometryPolicy.position_tolerance(profile: :research, semantic_class: klass), 1e-12
      assert_in_delta 0.10, BOMEngine::BOMCGeometryPolicy.normal_tolerance(profile: :research, semantic_class: klass), 1e-12
      assert_in_delta 1.0e-4, BOMEngine::BOMCGeometryPolicy.uv_tolerance(profile: :research, semantic_class: klass), 1e-12
    end
    assert_in_delta 1.0e-5, BOMEngine::BOMCGeometryPolicy.transform_tolerance(profile: :research), 1e-12
  end

  def test_visual_profile_tolerances
    # Class A: 0.5 mm, 0.10 deg, 1e-4 uv
    assert_in_delta 0.0005, BOMEngine::BOMCGeometryPolicy.position_tolerance(profile: :visual, semantic_class: :class_a), 1e-12
    assert_in_delta 0.10, BOMEngine::BOMCGeometryPolicy.normal_tolerance(profile: :visual, semantic_class: :class_a), 1e-12
    assert_in_delta 1.0e-4, BOMEngine::BOMCGeometryPolicy.uv_tolerance(profile: :visual, semantic_class: :class_a), 1e-12

    # Class B: 1.0 mm, 0.25 deg, 2.5e-4 uv
    assert_in_delta 0.0010, BOMEngine::BOMCGeometryPolicy.position_tolerance(profile: :visual, semantic_class: :class_b), 1e-12
    assert_in_delta 0.25, BOMEngine::BOMCGeometryPolicy.normal_tolerance(profile: :visual, semantic_class: :class_b), 1e-12
    assert_in_delta 2.5e-4, BOMEngine::BOMCGeometryPolicy.uv_tolerance(profile: :visual, semantic_class: :class_b), 1e-12

    # Class C: 2.0 mm, 0.50 deg, 5.0e-4 uv
    assert_in_delta 0.0020, BOMEngine::BOMCGeometryPolicy.position_tolerance(profile: :visual, semantic_class: :class_c), 1e-12
    assert_in_delta 0.50, BOMEngine::BOMCGeometryPolicy.normal_tolerance(profile: :visual, semantic_class: :class_c), 1e-12
    assert_in_delta 5.0e-4, BOMEngine::BOMCGeometryPolicy.uv_tolerance(profile: :visual, semantic_class: :class_c), 1e-12
  end

  def test_candidates_carry_semantic_class
    positions = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    encoded_pos = BOMEngine::BOMC::PositionCodec.encode(positions, semantic_class: :class_a)
    assert encoded_pos[:candidates].all? { |c| c[:semantic_class] == :class_a }

    normals = [0.0, 0.0, 1.0]
    encoded_norm = BOMEngine::BOMC::NormalCodec.encode(normals, semantic_class: :class_b)
    assert encoded_norm[:candidates].all? { |c| c[:semantic_class] == :class_b }

    uvs = [0.0, 0.0, 1.0, 1.0]
    encoded_uv = BOMEngine::BOMC::UVCodec.encode(uvs, semantic_class: :class_c)
    assert encoded_uv[:candidates].all? { |c| c[:semantic_class] == :class_c }
  end
end
