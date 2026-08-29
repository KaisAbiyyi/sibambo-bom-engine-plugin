# frozen_string_literal: true
# BOMC Deterministic Rate/Distortion Byte Budget Solver (Batch 4)

require_relative 'bomc_profile'
require_relative 'bomc_candidate'

module BOMEngine
  module BOMCBudgetSolver
    SOURCE_SIZE_REQUIRED = :SOURCE_SIZE_REQUIRED
    BUDGET_NOT_FEASIBLE = :BUDGET_NOT_FEASIBLE
    FIDELITY_CONSTRAINT_VIOLATION = :FIDELITY_CONSTRAINT_VIOLATION
    ENCODER_INTERNAL_ERROR = :ENCODER_INTERNAL_ERROR

    class SolverError < StandardError
      attr_reader :error_code, :details

      def initialize(message, error_code, details = {})
        @error_code = error_code
        @details = details
        super(message)
      end
    end

    class SourceSizeRequiredError < SolverError
      def initialize(message = 'Source SKP byte size is required for budget-constrained profile.', details = {})
        super(message, SOURCE_SIZE_REQUIRED, details)
      end
    end

    class BudgetNotFeasibleError < SolverError
      def initialize(message = 'Budget is not feasible on available candidate frontier.', details = {})
        super(message, BUDGET_NOT_FEASIBLE, details)
      end
    end

    class FidelityConstraintViolationError < SolverError
      def initialize(message = 'No candidate satisfies the required fidelity constraints.', details = {})
        super(message, FIDELITY_CONSTRAINT_VIOLATION, details)
      end
    end

    class EncoderInternalError < SolverError
      def initialize(message = 'Encoder internal error occurred during budget solving.', details = {})
        super(message, ENCODER_INTERNAL_ERROR, details)
      end
    end

    module_function

    def solve(profile:, profile_contract: nil, source_skp_bytes: nil, candidate_groups: {}, fixed_bytes_estimate: 0)
      contract = if profile_contract
                   profile_contract.is_a?(BOMCProfile::Profile) ? profile_contract : BOMCProfile.fetch(profile_contract)
                 elsif [:exact, :research, :visual].include?(profile.to_sym)
                   BOMCProfile.fetch(profile.to_sym)
                 else
                   BOMCProfile.fetch(:visual)
                 end

      source_bytes = source_skp_bytes ? Integer(source_skp_bytes) : nil

      if contract.requires_source_size?
        if source_bytes.nil? || source_bytes <= 0
          raise SourceSizeRequiredError.new(
            "Profile #{contract.name} requires positive source SKP byte size.",
            profile: contract.name,
            source_skp_bytes: source_bytes
          )
        end
      end

      if contract.profile == :exact
        # Exact profile: select highest-fidelity candidate for each group unconditionally
        selected = {}
        candidate_groups.each do |owner_id, candidates|
          valid = candidates.select(&:pass_hard_constraints?)
          raise FidelityConstraintViolationError.new("No valid candidate for #{owner_id}") if valid.empty?
          selected[owner_id] = valid.min_by { |c| [c.distortion_score, c.deterministic_rank] }
        end
        return {
          status: :exact_no_budget_required,
          profile: contract.name,
          hard_budget_bytes: nil,
          preferred_target_bytes: nil,
          selected_candidates: selected,
          total_estimated_bytes: Integer(fixed_bytes_estimate) + selected.values.sum(&:stored_bytes_estimate),
          audit_trail: [{ step: :exact_highest_fidelity, selected: selected.transform_values(&:id) }]
        }
      end

      hard_budget_bytes = (source_bytes * contract.hard_ratio).floor
      preferred_target_bytes = contract.preferred_ratio ? (source_bytes * contract.preferred_ratio).floor : hard_budget_bytes

      # 1. Filter candidates by hard constraints & profile error bounds
      frontiers = {}
      candidate_groups.each do |owner_id, candidates|
        passing = candidates.select do |c|
          next false unless c.pass_hard_constraints?
          satisfies_profile_fidelity?(c, contract)
        end

        if passing.empty?
          raise FidelityConstraintViolationError.new(
            "Owner #{owner_id} has no candidate passing fidelity constraints for profile #{contract.name}.",
            owner_id: owner_id,
            profile: contract.name
          )
        end

        # Prune dominated candidates and sort by stored_bytes_estimate descending (highest fidelity first)
        frontiers[owner_id] = build_pareto_frontier(passing)
      end

      # 2. Start from highest fidelity candidate per group (index 0)
      current_indices = {}
      frontiers.each { |owner_id, _| current_indices[owner_id] = 0 }

      current_selected = frontiers.transform_values { |frontier| frontier[0] }
      current_total_bytes = Integer(fixed_bytes_estimate) + current_selected.values.sum(&:stored_bytes_estimate)
      audit_trail = [{
        step: 0,
        action: :initial_highest_fidelity,
        total_estimated_bytes: current_total_bytes,
        hard_budget_bytes: hard_budget_bytes,
        preferred_target_bytes: preferred_target_bytes,
        selections: current_selected.transform_values(&:id)
      }]

      # 3. Iteratively transition to lower-byte candidates if over budget
      step = 1
      while current_total_bytes > hard_budget_bytes
        # Find best downward transition
        best_transition = nil
        best_metric = -Float::INFINITY

        frontiers.each do |owner_id, frontier|
          current_idx = current_indices[owner_id]
          next if current_idx >= frontier.length - 1

          current_c = frontier[current_idx]
          next_c = frontier[current_idx + 1]

          byte_savings = current_c.stored_bytes_estimate - next_c.stored_bytes_estimate
          next if byte_savings <= 0

          delta_distortion = [next_c.distortion_score - current_c.distortion_score, 0.0].max
          efficiency = delta_distortion > 0.0 ? (byte_savings.to_f / delta_distortion) : (byte_savings * 1_000_000.0)

          tie_key = [
            next_c.domain.to_s,
            next_c.owner_id.to_s,
            next_c.deterministic_rank
          ]

          candidate_transition = {
            owner_id: owner_id,
            from_idx: current_idx,
            to_idx: current_idx + 1,
            from_id: current_c.id,
            to_id: next_c.id,
            byte_savings: byte_savings,
            delta_distortion: delta_distortion,
            efficiency: efficiency,
            tie_key: tie_key
          }

          if best_transition.nil? ||
             candidate_transition[:efficiency] > best_transition[:efficiency] ||
             (candidate_transition[:efficiency] == best_transition[:efficiency] && candidate_transition[:byte_savings] > best_transition[:byte_savings]) ||
             (candidate_transition[:efficiency] == best_transition[:efficiency] && candidate_transition[:byte_savings] == best_transition[:byte_savings] && (candidate_transition[:tie_key] <=> best_transition[:tie_key]) < 0)
            best_transition = candidate_transition
          end
        end

        break if best_transition.nil?

        owner_id = best_transition[:owner_id]
        current_indices[owner_id] = best_transition[:to_idx]
        current_selected[owner_id] = frontiers[owner_id][best_transition[:to_idx]]
        current_total_bytes -= best_transition[:byte_savings]

        audit_trail << {
          step: step,
          transition: best_transition,
          total_estimated_bytes: current_total_bytes,
          selections: current_selected.transform_values(&:id)
        }
        step += 1
      end

      # 4. Check feasibility
      if current_total_bytes > hard_budget_bytes
        raise BudgetNotFeasibleError.new(
          "Achievable size #{current_total_bytes} bytes exceeds hard budget #{hard_budget_bytes} bytes (#{contract.hard_ratio * 100}% of source #{source_bytes} bytes).",
          achievable_bytes: current_total_bytes,
          hard_budget_bytes: hard_budget_bytes,
          source_skp_bytes: source_bytes,
          profile: contract.name,
          audit_trail: audit_trail
        )
      end

      {
        status: :budget_passed,
        profile: contract.name,
        source_skp_bytes: source_bytes,
        hard_budget_bytes: hard_budget_bytes,
        preferred_target_bytes: preferred_target_bytes,
        selected_candidates: current_selected,
        total_estimated_bytes: current_total_bytes,
        audit_trail: audit_trail
      }
    end

    def satisfies_profile_fidelity?(candidate, contract)
      ev = candidate.quality_evidence
      if contract.position_error_m.is_a?(Numeric) && ev[:max_position_error_m]
        return false if ev[:max_position_error_m].to_f > contract.position_error_m + 1e-12
      end
      if contract.normal_error_deg.is_a?(Numeric) && ev[:max_normal_error_deg]
        return false if ev[:max_normal_error_deg].to_f > contract.normal_error_deg + 1e-12
      end
      if contract.uv_error.is_a?(Numeric) && ev[:max_uv_error]
        return false if ev[:max_uv_error].to_f > contract.uv_error + 1e-12
      end
      if contract.transform_error.is_a?(Numeric) && ev[:max_transform_error]
        return false if ev[:max_transform_error].to_f > contract.transform_error + 1e-12
      end
      true
    end
    private_class_method :satisfies_profile_fidelity?

    def build_pareto_frontier(candidates)
      # Sort candidates by stored_bytes_estimate descending, then distortion_score ascending
      sorted = candidates.sort_by do |c|
        [-c.stored_bytes_estimate, c.distortion_score, c.deterministic_rank]
      end

      # Keep only non-dominated candidates
      frontier = []
      sorted.each do |c|
        if frontier.empty?
          frontier << c
        else
          last = frontier.last
          if c.stored_bytes_estimate < last.stored_bytes_estimate
            frontier << c
          elsif c.distortion_score < last.distortion_score
            frontier[-1] = c
          end
        end
      end
      frontier
    end
    private_class_method :build_pareto_frontier
  end
end
