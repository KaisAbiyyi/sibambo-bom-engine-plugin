# frozen_string_literal: true
# BOMC Candidate model for rate/distortion budget solving (Batch 4 & T6)

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
                  :params,
                  :bytes,
                  :codec,
                  :error_report

      alias stored_size_estimate stored_bytes_estimate

      def initialize(
        id:,
        domain:,
        owner_id:,
        stored_bytes_estimate: nil,
        stored_size_estimate: nil,
        distortion_score: 0.0,
        hard_constraints_passed: true,
        quality_evidence: {},
        error_report: nil,
        deterministic_rank: 0,
        params: {},
        bytes: nil,
        codec: nil
      )
        @id = id.to_sym
        @domain = domain.to_sym
        @owner_id = owner_id
        estimate = stored_size_estimate || stored_bytes_estimate || 0
        @stored_bytes_estimate = Integer(estimate)
        @distortion_score = Float(distortion_score)
        @hard_constraints_passed = !!hard_constraints_passed
        @quality_evidence = (quality_evidence || {}).dup.freeze
        @error_report = (error_report || quality_evidence || {}).dup.freeze
        @deterministic_rank = Integer(deterministic_rank)
        @params = (params || {}).dup.freeze
        @bytes = bytes ? bytes.b.freeze : nil
        @codec = codec ? Integer(codec) : (@params[:codec] ? Integer(@params[:codec]) : nil)
        freeze
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
          stored_size_estimate: @stored_bytes_estimate,
          distortion_score: @distortion_score,
          hard_constraints_passed: @hard_constraints_passed,
          quality_evidence: @quality_evidence,
          error_report: @error_report,
          deterministic_rank: @deterministic_rank,
          params: @params,
          bytes: @bytes,
          codec: @codec
        }
      end
    end

    class PreparedCandidates
      attr_reader :source_digest,
                  :profile,
                  :policy_revision,
                  :candidate_groups,
                  :fixed_sections

      def initialize(
        source_digest:,
        profile:,
        policy_revision:,
        candidate_groups: {},
        fixed_sections: []
      )
        @source_digest = source_digest.to_s.freeze
        @profile = profile.to_sym
        @policy_revision = policy_revision.to_s.freeze
        groups = {}
        if candidate_groups.is_a?(Hash)
          candidate_groups.each do |k, v|
            groups[k] = Array(v).dup.freeze
          end
        elsif candidate_groups.is_a?(Array)
          candidate_groups.each do |grp|
            if grp.is_a?(Hash)
              owner = grp[:owner_id] || grp['owner_id']
              cands = grp[:candidates] || grp['candidates'] || []
              groups[owner] = Array(cands).dup.freeze
            end
          end
        end
        @candidate_groups = groups.freeze
        @fixed_sections = Array(fixed_sections).dup.freeze
        freeze
      end

      def to_h
        {
          source_digest: @source_digest,
          profile: @profile,
          policy_revision: @policy_revision,
          candidate_groups: @candidate_groups,
          fixed_sections: @fixed_sections
        }
      end

      def [](key)
        case key.to_sym
        when :source_digest then @source_digest
        when :profile then @profile
        when :policy_revision then @policy_revision
        when :candidate_groups then @candidate_groups
        when :fixed_sections then @fixed_sections
        end
      end
    end
  end

  PreparedCandidates = BOMCCandidate::PreparedCandidates
end
