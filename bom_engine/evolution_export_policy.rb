# frozen_string_literal: true

module BOMEngine
  # New host exports only. Historical codec/read validation keeps its original enums.
  module EvolutionExportPolicy
    ENGINES = %i[e2 e3 e4].freeze
    PROFILES = %i[exact visual].freeze

    module_function

    def engine(value)
      normalized = value.to_s.downcase.to_sym
      raise ArgumentError, 'retired_for_new_exports: e1' if normalized == :e1
      raise ArgumentError, "Unsupported Evolution engine: #{value}" unless ENGINES.include?(normalized)
      normalized
    end

    def profile(value)
      normalized = value.to_s.downcase.to_sym
      raise ArgumentError, 'retired_for_new_exports: research' if normalized == :research
      raise ArgumentError, "Unsupported new-export profile: #{value}" unless PROFILES.include?(normalized)
      normalized
    end
  end
end
