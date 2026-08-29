# frozen_string_literal: true
# BOMC Candidate model for rate/distortion budget solving (Batch 4)

module BOMEngine
  module BOMCCandidate
    class Candidate
      attr_reader :id,
                  :domain,
                  :owner_id,
                  :stored_bytes_estimate,
                  :distortion_score,
                  :hard_constraints_passed,
                  :quality_evidence,
                  :deterministic_rank,
                  :params

      def initialize(
        id:,
        domain:,
        owner_id:,
        stored_bytes_estimate:,
        distortion_score: 0.0,
        hard_constraints_passed: true,
        quality_evidence: {},
        deterministic_rank: 0,
        params: {}
      )
        @id = id.to_sym
        @domain = domain.to_sym
        @owner_id = owner_id
        @stored_bytes_estimate = Integer(stored_bytes_estimate)
        @distortion_score = Float(distortion_score)
        @hard_constraints_passed = !!hard_constraints_passed
        @quality_evidence = quality_evidence || {}
        @deterministic_rank = Integer(deterministic_rank)
        @params = params || {}
      end

      def pass_hard_constraints?
        return false unless @hard_constraints_passed
        sem = @quality_evidence[:semantic_distortion]
        return false if sem && sem.to_f > 0.0
        top = @quality_evidence[:protected_topology_distortion]
        return false if top && top.to_f > 0.0
        true
      end

      def to_h
        {
          id: @id,
          domain: @domain,
          owner_id: @owner_id,
          stored_bytes_estimate: @stored_bytes_estimate,
          distortion_score: @distortion_score,
          hard_constraints_passed: @hard_constraints_passed,
          quality_evidence: @quality_evidence,
          deterministic_rank: @deterministic_rank,
          params: @params
        }
      end
    end
  end
end
