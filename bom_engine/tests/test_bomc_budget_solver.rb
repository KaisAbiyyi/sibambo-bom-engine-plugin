# frozen_string_literal: true
# Unit tests for BOMC Rate/Distortion Byte Budget Solver (Batch 4)

require 'test/unit'
require_relative '../bomc_budget_solver'
require_relative '../bomc_candidate'
require_relative '../bomc_profile'

class TestBOMCBudgetSolver < Test::Unit::TestCase
  def test_exact_profile_bypasses_size_gate
    c1 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :exact_c,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 140,
      distortion_score: 0.0
    )
    result = BOMEngine::BOMCBudgetSolver.solve(
      profile: :exact,
      source_skp_bytes: 100,
      candidate_groups: { mesh_0: [c1] }
    )
    assert_equal :exact_no_budget_required, result[:status]
    assert_equal :exact_c, result[:selected_candidates][:mesh_0].id
    assert_equal 140, result[:total_estimated_bytes]
  end

  def test_research_profile_requires_source_size
    c1 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c1,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 50,
      distortion_score: 0.0
    )
    assert_raise(BOMEngine::BOMCBudgetSolver::SourceSizeRequiredError) do
      BOMEngine::BOMCBudgetSolver.solve(
        profile: :research,
        source_skp_bytes: nil,
        candidate_groups: { mesh_0: [c1] }
      )
    end
  end

  def test_research_hard_target_90_from_100_source
    # 100 source => hard budget is 90
    c_90 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c_90,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 90,
      distortion_score: 0.05
    )
    c_95 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c_95,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 95,
      distortion_score: 0.01
    )
    result = BOMEngine::BOMCBudgetSolver.solve(
      profile: :research,
      source_skp_bytes: 100,
      candidate_groups: { mesh_0: [c_95, c_90] }
    )
    assert_equal :budget_passed, result[:status]
    assert_equal :c_90, result[:selected_candidates][:mesh_0].id
    assert_equal 90, result[:total_estimated_bytes]
  end

  def test_research_fails_when_best_is_91_from_100_source
    c_91 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c_91,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 91,
      distortion_score: 0.01
    )
    assert_raise(BOMEngine::BOMCBudgetSolver::BudgetNotFeasibleError) do
      BOMEngine::BOMCBudgetSolver.solve(
        profile: :research,
        source_skp_bytes: 100,
        candidate_groups: { mesh_0: [c_91] }
      )
    end
  end

  def test_visual_preferred_60_allows_valid_candidate_80
    # 100 source => preferred 60, hard limit 90. Candidate 80 is <= 90 so it passes.
    c_80 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c_80,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 80,
      distortion_score: 0.02
    )
    result = BOMEngine::BOMCBudgetSolver.solve(
      profile: :visual,
      source_skp_bytes: 100,
      candidate_groups: { mesh_0: [c_80] }
    )
    assert_equal :budget_passed, result[:status]
    assert_equal :c_80, result[:selected_candidates][:mesh_0].id
    assert_equal 80, result[:total_estimated_bytes]
  end

  def test_visual_candidate_95_fails
    c_95 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c_95,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 95,
      distortion_score: 0.01
    )
    assert_raise(BOMEngine::BOMCBudgetSolver::BudgetNotFeasibleError) do
      BOMEngine::BOMCBudgetSolver.solve(
        profile: :visual,
        source_skp_bytes: 100,
        candidate_groups: { mesh_0: [c_95] }
      )
    end
  end

  def test_semantic_distortion_violator_rejected
    c_bad = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c_bad,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 50,
      distortion_score: 0.01,
      quality_evidence: { semantic_distortion: 1.0 }
    )
    assert_raise(BOMEngine::BOMCBudgetSolver::FidelityConstraintViolationError) do
      BOMEngine::BOMCBudgetSolver.solve(
        profile: :research,
        source_skp_bytes: 100,
        candidate_groups: { mesh_0: [c_bad] }
      )
    end
  end

  def test_solver_determinism
    c1 = BOMEngine::BOMCCandidate::Candidate.new(id: :c1, domain: :positions, owner_id: :m1, stored_bytes_estimate: 80, distortion_score: 0.01)
    c2 = BOMEngine::BOMCCandidate::Candidate.new(id: :c2, domain: :positions, owner_id: :m1, stored_bytes_estimate: 40, distortion_score: 0.05)
    c3 = BOMEngine::BOMCCandidate::Candidate.new(id: :c3, domain: :normals, owner_id: :m1, stored_bytes_estimate: 60, distortion_score: 0.02)
    c4 = BOMEngine::BOMCCandidate::Candidate.new(id: :c4, domain: :normals, owner_id: :m1, stored_bytes_estimate: 30, distortion_score: 0.08)

    groups = { pos: [c1, c2], norm: [c3, c4] }

    res1 = BOMEngine::BOMCBudgetSolver.solve(profile: :visual, source_skp_bytes: 100, candidate_groups: groups)
    res2 = BOMEngine::BOMCBudgetSolver.solve(profile: :visual, source_skp_bytes: 100, candidate_groups: groups)

    assert_equal res1[:selected_candidates].transform_values(&:id), res2[:selected_candidates].transform_values(&:id)
    assert_equal res1[:total_estimated_bytes], res2[:total_estimated_bytes]
  end

  def test_prepared_candidates_record_integration
    c1 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c1,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 80,
      distortion_score: 0.01,
      bytes: "candidate_1_bytes",
      codec: 1
    )
    c2 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c2,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 50,
      distortion_score: 0.05,
      bytes: "candidate_2_bytes",
      codec: 2
    )

    prepared = BOMEngine::BOMCCandidate::PreparedCandidates.new(
      source_digest: 'abc123digest',
      profile: :visual,
      policy_revision: '2026.09.08.1',
      candidate_groups: { mesh_0: [c1, c2] },
      fixed_sections: [1, 2, 3]
    )

    assert_equal 'abc123digest', prepared.source_digest
    assert_equal :visual, prepared.profile
    assert_equal '2026.09.08.1', prepared.policy_revision
    assert_equal 1, prepared.candidate_groups.length

    result = BOMEngine::BOMCBudgetSolver.solve(
      profile: :visual,
      source_skp_bytes: 100,
      candidate_groups: prepared
    )

    assert_equal :budget_passed, result[:status]
    assert_equal :c2, result[:selected_candidates][:mesh_0].id
    assert_equal "candidate_2_bytes", result[:selected_candidates][:mesh_0].bytes
    assert_equal 2, result[:selected_candidates][:mesh_0].codec
    assert_equal true, result[:preferred_target_achieved]
    assert_nil result[:diagnostic_reason]
  end

  def test_visual_soft_target_fallback_with_diagnostic
    # 100 source => preferred 60%, hard 90%.
    # Only candidate 75 is available: passes hard budget (<=90), but fails soft target (60%).
    c75 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c75,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 75,
      distortion_score: 0.02
    )
    result = BOMEngine::BOMCBudgetSolver.solve(
      profile: :visual,
      source_skp_bytes: 100,
      candidate_groups: { mesh_0: [c75] }
    )

    assert_equal :budget_passed, result[:status]
    assert_equal :c75, result[:selected_candidates][:mesh_0].id
    assert_equal 75, result[:total_estimated_bytes]
    assert_equal false, result[:preferred_target_achieved]
    assert_not_nil result[:diagnostic_reason]
    assert_match(/Preferred target of 60%/, result[:diagnostic_reason])
    assert_match(/Reason: candidate frontier exhausted/, result[:diagnostic_reason])
  end

  def test_research_does_not_violate_tolerance_to_meet_budget
    # Research profile requires max position error 0.0005m.
    # Candidate 80 has error 0.0008m (violates tolerance)
    c_violator = BOMEngine::BOMCCandidate::Candidate.new(
      id: :c_violator,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 80,
      distortion_score: 0.0008,
      quality_evidence: { max_position_error_m: 0.0008 }
    )
    assert_raise(BOMEngine::BOMCBudgetSolver::FidelityConstraintViolationError) do
      BOMEngine::BOMCBudgetSolver.solve(
        profile: :research,
        source_skp_bytes: 100,
        candidate_groups: { mesh_0: [c_violator] }
      )
    end
  end
end
