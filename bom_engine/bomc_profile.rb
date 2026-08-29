# frozen_string_literal: true
# BOMC Profile Definitions: exact, research, visual contracts.

module BOMEngine
  module BOMCProfile
    class Profile
      attr_reader :name,
                  :requires_source_size,
                  :preferred_ratio,
                  :hard_ratio,
                  :position_error_m,
                  :normal_error_deg,
                  :uv_error,
                  :transform_error,
                  :texture_policy,
                  :geometry_policy,
                  :allow_topology_simplification

      alias profile name
      alias requires_source_size? requires_source_size
      alias allow_topology_simplification? allow_topology_simplification

      def initialize(
        name:,
        requires_source_size:,
        preferred_ratio:,
        hard_ratio:,
        position_error_m:,
        normal_error_deg:,
        uv_error:,
        transform_error:,
        texture_policy:,
        geometry_policy:,
        allow_topology_simplification: false
      )
        @name = name.to_sym
        @requires_source_size = !!requires_source_size
        @preferred_ratio = preferred_ratio ? Float(preferred_ratio) : nil
        @hard_ratio = hard_ratio ? Float(hard_ratio) : nil
        @position_error_m = position_error_m.is_a?(Symbol) ? position_error_m : (position_error_m ? Float(position_error_m) : 0.0)
        @normal_error_deg = normal_error_deg.is_a?(Symbol) ? normal_error_deg : (normal_error_deg ? Float(normal_error_deg) : 0.0)
        @uv_error = uv_error.is_a?(Symbol) ? uv_error : (uv_error ? Float(uv_error) : 0.0)
        @transform_error = transform_error.is_a?(Symbol) ? transform_error : (transform_error ? Float(transform_error) : 0.0)
        @texture_policy = texture_policy.to_sym
        @geometry_policy = geometry_policy.to_sym
        @allow_topology_simplification = !!allow_topology_simplification
        freeze
      end

      def to_h
        {
          name: @name,
          requires_source_size: @requires_source_size,
          preferred_ratio: @preferred_ratio,
          hard_ratio: @hard_ratio,
          position_error_m: @position_error_m,
          normal_error_deg: @normal_error_deg,
          uv_error: @uv_error,
          transform_error: @transform_error,
          texture_policy: @texture_policy,
          geometry_policy: @geometry_policy,
          allow_topology_simplification: @allow_topology_simplification
        }.freeze
      end
    end

    PROFILES = {
      exact: Profile.new(
        name: :exact,
        requires_source_size: false,
        preferred_ratio: nil,
        hard_ratio: nil,
        position_error_m: 0.0,
        normal_error_deg: 0.0,
        uv_error: 0.0,
        transform_error: 0.0,
        texture_policy: :pixel_lossless,
        geometry_policy: :exact,
        allow_topology_simplification: false
      ),
      research: Profile.new(
        name: :research,
        requires_source_size: true,
        preferred_ratio: 0.90,
        hard_ratio: 0.90,
        position_error_m: 0.0005,
        normal_error_deg: 0.1,
        uv_error: 0.0001,
        transform_error: 0.00001,
        texture_policy: :perceptual_bounded,
        geometry_policy: :bounded_error,
        allow_topology_simplification: false
      ),
      visual: Profile.new(
        name: :visual,
        requires_source_size: true,
        preferred_ratio: 0.60,
        hard_ratio: 0.90,
        position_error_m: :semantic_policy,
        normal_error_deg: :semantic_policy,
        uv_error: :semantic_policy,
        transform_error: 0.00001,
        texture_policy: :web_aggressive_bounded,
        geometry_policy: :semantic_bounded,
        allow_topology_simplification: false
      )
    }.freeze

    DEFAULT_PROFILE = :visual

    module_function

    def names
      PROFILES.keys.freeze
    end

    def fetch(name)
      key = name.to_s.downcase.to_sym
      profile = PROFILES[key]
      return profile if profile

      raise ArgumentError, "Unknown BOMC profile '#{name}'. Supported profiles are: #{names.join(', ')}."
    end

    def valid?(name)
      PROFILES.key?(name.to_s.downcase.to_sym)
    end
  end
end
