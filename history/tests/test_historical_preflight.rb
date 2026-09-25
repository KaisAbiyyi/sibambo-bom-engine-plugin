# frozen_string_literal: true

require 'test/unit'
require_relative '../../tools/history/evolution_lineup/historical_preflight'

class TestHistoricalPreflight < Test::Unit::TestCase
  Transform = Struct.new(:values) do
    def to_a; values; end
  end
  Entity = Struct.new(:transformation, :name, :definition)
  Definition = Struct.new(:entities)
  Model = Struct.new(:entities, :definitions)
  IDENTITY = [1.0, 0.0, 0.0, 0.0,
              0.0, 1.0, 0.0, 0.0,
              0.0, 0.0, 1.0, 0.0,
              0.0, 0.0, 0.0, 1.0].freeze

  def model_with(values)
    Model.new([Entity.new(Transform.new(values), 'Test instance')], [Definition.new([])])
  end

  def test_affine_transform_is_accepted_for_all_historical_formats
    %w[tiered_json canonical_v3 cleanpkg].each do |kind|
      assert_nothing_raised do
        SibamboHistory::EvolutionLab::HistoricalPreflight.validate!(model_with(IDENTITY), kind: kind)
      end
    end
  end

  def test_nonfinite_transform_is_rejected_before_export_in_all_historical_formats
    invalid = IDENTITY.dup
    invalid[12] = Float::INFINITY
    %w[tiered_json canonical_v3 cleanpkg].each do |kind|
      error = assert_raise(ArgumentError) do
        SibamboHistory::EvolutionLab::HistoricalPreflight.validate!(model_with(invalid), kind: kind)
      end
      assert_match(/transform/i, error.message)
    end
  end

  def test_cleanpkg_rejects_nonaffine_matrix_that_its_point_transform_cannot_preserve
    projective = IDENTITY.dup
    projective[3] = 0.125
    %w[tiered_json canonical_v3].each do |kind|
      assert_nothing_raised do
        SibamboHistory::EvolutionLab::HistoricalPreflight.validate!(model_with(projective), kind: kind)
      end
    end
    error = assert_raise(ArgumentError) do
      SibamboHistory::EvolutionLab::HistoricalPreflight.validate!(model_with(projective), kind: 'cleanpkg')
    end
    assert_match(/CleanPKG/, error.message)
    assert_match(/Test instance/, error.message)
  end

  def test_component_definition_instances_are_checked_even_if_not_in_root_entities
    projective = IDENTITY.dup
    projective[15] = 2.0
    definition = Definition.new([Entity.new(Transform.new(projective), 'Nested')])
    model = Model.new([Entity.new(Transform.new(IDENTITY), 'Root', definition)], [definition])
    assert_raise(ArgumentError) do
      SibamboHistory::EvolutionLab::HistoricalPreflight.validate!(model, kind: 'cleanpkg')
    end
  end
end
