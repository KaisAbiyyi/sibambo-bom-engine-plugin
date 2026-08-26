# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../semantic_v2'
require_relative '../clean_analysis'

class CleanAnalysisTextureExtractorTest < Minitest::Test
  Scope = Struct.new(:root_definition_uuid)
  Snapshot = Struct.new(:scope, :primitives, :occurrences, :materials)
  SnapshotMaterial = Struct.new(:source_uuid, :texture)
  Model = Struct.new(:materials)

  class IdentityPlan
    def initialize(values)
      @values = values
    end

    def source_uuid_for(entity)
      @values.fetch(entity)
    end
  end

  def setup
    return if Object.const_defined?(:Sketchup)

    sketchup = Module.new
    sketchup.define_singleton_method(:create_texture_writer) { nil }
    Object.const_set(:Sketchup, sketchup)
    @remove_sketchup = true
  end

  def teardown
    Object.send(:remove_const, :Sketchup) if @remove_sketchup
  end

  def test_texture_extraction_ignores_model_materials_missing_from_identity_plan
    referenced = Object.new
    unused = Object.new
    uuid = '00000000-0000-4000-8000-000000000001'
    snapshot = Snapshot.new(
      Scope.new('00000000-0000-4000-8000-000000000002'),
      [],
      [],
      [SnapshotMaterial.new(uuid, nil)]
    )

    bundle = SibamboHistory::V20260812_01::CleanAnalysis::TextureExtractor.extract(
      model: Model.new([unused, referenced]),
      roots: [],
      identity_plan: IdentityPlan.new(referenced => uuid),
      snapshot: snapshot
    )

    assert_instance_of SibamboHistory::V20260812_01::CleanAnalysis::TextureBundle, bundle
    assert_empty bundle.assets
  end
end
