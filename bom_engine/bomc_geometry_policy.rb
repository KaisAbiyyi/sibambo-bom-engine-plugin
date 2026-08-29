# frozen_string_literal: true
# Semantic-Aware Geometry Policy and Error Tolerances (Batch 5)

require_relative 'bomc_candidate'

module BOMEngine
  module BOMCGeometryPolicy
    CLASS_A = :class_a # Protected analytical
    CLASS_B = :class_b # Functional visual (default for unknown)
    CLASS_C = :class_c # Decorative / site

    CLASS_A_ROLES = [
      :wall, :exterior_wall, :interior_wall, :floor, :ceiling, :roof,
      :opening, :window, :door, :column, :beam, :stair, :foundation,
      :structure, :room, :room_boundary
    ].freeze

    CLASS_C_ROLES = [
      :furniture, :landscape, :site, :decorative, :planting
    ].freeze

    # Visual Profile Locked Bounds
    VISUAL_BOUNDS = {
      CLASS_A => { position_m: 0.0005, normal_deg: 0.10, uv: 1.0e-4 },
      CLASS_B => { position_m: 0.0010, normal_deg: 0.25, uv: 2.5e-4 },
      CLASS_C => { position_m: 0.0020, normal_deg: 0.50, uv: 5.0e-4 }
    }.freeze

    # Research Profile Locked Bounds (all classes equal)
    RESEARCH_BOUNDS = {
      CLASS_A => { position_m: 0.0005, normal_deg: 0.10, uv: 1.0e-4 },
      CLASS_B => { position_m: 0.0005, normal_deg: 0.10, uv: 1.0e-4 },
      CLASS_C => { position_m: 0.0005, normal_deg: 0.10, uv: 1.0e-4 }
    }.freeze

    # Exact Profile (0 error)
    EXACT_BOUNDS = {
      CLASS_A => { position_m: 0.0, normal_deg: 0.0, uv: 0.0 },
      CLASS_B => { position_m: 0.0, normal_deg: 0.0, uv: 0.0 },
      CLASS_C => { position_m: 0.0, normal_deg: 0.0, uv: 0.0 }
    }.freeze

    TRANSFORM_ERROR = 1.0e-5

    module_function

    def classify_role(role)
      norm_role = role.to_s.downcase.to_sym
      if CLASS_A_ROLES.include?(norm_role)
        CLASS_A
      elsif CLASS_C_ROLES.include?(norm_role)
        CLASS_C
      else
        CLASS_B # Unknown or functional defaults to Class B
      end
    end

    def mesh_semantic_class(faces_or_roles)
      roles = Array(faces_or_roles).map do |item|
        item.is_a?(Hash) ? (item[:semantic_role] || item[:role]) : item
      end.compact

      return CLASS_B if roles.empty?

      classes = roles.map { |r| classify_role(r) }
      if classes.include?(CLASS_A)
        CLASS_A
      elsif classes.include?(CLASS_B)
        CLASS_B
      else
        CLASS_C
      end
    end

    def position_tolerance(profile:, semantic_class:)
      bounds_for(profile, semantic_class)[:position_m]
    end

    def normal_tolerance(profile:, semantic_class:)
      bounds_for(profile, semantic_class)[:normal_deg]
    end

    def uv_tolerance(profile:, semantic_class:)
      bounds_for(profile, semantic_class)[:uv]
    end

    def transform_tolerance(profile:)
      prof = profile.to_s.downcase.to_sym
      prof == :exact ? 0.0 : TRANSFORM_ERROR
    end

    def budget_candidates(reports:, domain:, owner_id:, profile:, semantic_class:)
      domain_key = domain.to_s.downcase.to_sym
      klass = semantic_class.to_s.downcase.to_sym
      tolerance = tolerance_for_domain(profile, klass, domain_key)

      Array(reports).each_with_index.map do |report, index|
        errors = report[:errors] || {}
        maximum_error = errors[:max].to_f
        within_tolerance = maximum_error <= tolerance + 1.0e-12
        quality_evidence = {
          semantic_class: klass,
          max_area_error_m2: report[:area_max_error_m2].to_f,
          semantic_distortion: 0.0,
          protected_topology_distortion: 0.0
        }
        case domain_key
        when :positions
          quality_evidence[:max_position_error_m] = maximum_error
        when :normals
          quality_evidence[:max_normal_error_deg] = maximum_error
        when :uv
          quality_evidence[:max_uv_error] = maximum_error
        else
          raise ArgumentError, "Unsupported geometry candidate domain #{domain}."
        end

        BOMCCandidate::Candidate.new(
          id: "#{domain_key}_#{owner_id}_#{report[:name] || index}",
          domain: domain_key,
          owner_id: owner_id,
          stored_bytes_estimate: report[:deflate_bytes] || report[:raw_bytes] || 0,
          distortion_score: maximum_error,
          hard_constraints_passed: report[:passed] != false && within_tolerance,
          quality_evidence: quality_evidence,
          deterministic_rank: index,
          params: {
            codec: report[:codec],
            candidate_name: report[:name],
            semantic_class: klass,
            raw_bytes: report[:raw_bytes]
          }
        )
      end
    end

    def bounds_for(profile, semantic_class)
      prof = profile.to_s.downcase.to_sym
      klass = semantic_class.to_s.downcase.to_sym
      klass = CLASS_B unless [CLASS_A, CLASS_B, CLASS_C].include?(klass)

      case prof
      when :exact
        EXACT_BOUNDS[klass]
      when :research
        RESEARCH_BOUNDS[klass]
      when :visual, :production, :debug
        VISUAL_BOUNDS[klass]
      else
        VISUAL_BOUNDS[klass]
      end
    end
    private_class_method :bounds_for

    def tolerance_for_domain(profile, semantic_class, domain)
      bounds = bounds_for(profile, semantic_class)
      case domain
      when :positions then bounds[:position_m]
      when :normals then bounds[:normal_deg]
      when :uv then bounds[:uv]
      else raise ArgumentError, "Unsupported geometry candidate domain #{domain}."
      end
    end
    private_class_method :tolerance_for_domain
  end
end
