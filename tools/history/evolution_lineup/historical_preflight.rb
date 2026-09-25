# frozen_string_literal: true

# Historical engines remain authentic snapshots. This checks the model-specific
# matrix assumptions before one of them spends time writing a partial export.
module SibamboHistory
  module EvolutionLab
    module HistoricalPreflight
      KINDS = %w[tiered_json canonical_v3 cleanpkg].freeze
      AFFINE_EPSILON = 1.0e-12

      module_function

      def validate!(model, kind:)
        raise ArgumentError, 'Engine historis tidak dikenal.' unless KINDS.include?(kind.to_s)
        raise ArgumentError, 'Model SketchUp tidak tersedia.' unless model && model.respond_to?(:entities)

        collections = [model.entities]
        visited_definitions = {}
        until collections.empty?
          entities = collections.pop
          entities.each do |entity|
            inspect_transform!(entity, kind)
            next unless entity.respond_to?(:definition)

            definition = entity.definition
            next unless definition && definition.respond_to?(:entities)
            key = definition.object_id
            next if visited_definitions[key]

            visited_definitions[key] = true
            collections << definition.entities
          end
        end
        true
      end

      def inspect_transform!(entity, kind)
        return unless entity.respond_to?(:transformation)

        raw = entity.transformation.to_a
        name = entity.respond_to?(:name) && !entity.name.to_s.empty? ? entity.name : entity.class.name
        unless raw.is_a?(Array) && raw.length == 16 && raw.all? { |value| numeric_finite?(value) }
          raise ArgumentError, "Transform tidak valid pada #{name}; ekspor #{kind} dihentikan sebelum membuat file."
        end
        return unless kind.to_s == 'cleanpkg'
        return if [3, 7, 11].all? { |index| raw[index].to_f.abs <= AFFINE_EPSILON } &&
                  (raw[15].to_f - 1.0).abs <= AFFINE_EPSILON

        raise ArgumentError, "CleanPKG tidak mendukung transform non-affine pada #{name}. Pilih E4 BOMC; file lama tidak diubah."
      end

      def numeric_finite?(value)
        Float(value).finite?
      rescue ArgumentError, TypeError
        false
      end
      private_class_method :inspect_transform!, :numeric_finite?
    end
  end
end
