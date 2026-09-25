# frozen_string_literal: true

require 'test/unit'
require_relative 'sketchup_mock_helper'
require_relative '../constants'
require_relative '../traversal'
require_relative '../semantic_labeler'
require_relative '../canonical_graph_builder'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

class TestSharedGroupDefinitions < Test::Unit::TestCase
  def test_shared_group_geometry_is_stored_once_with_two_instances
    model = Sketchup::Model.new
    first = model.entities.add_group
    first.name = 'First copy'
    first.entities.add_face([0, 0, 0], [10, 0, 0], [0, 10, 0])

    second = model.entities.add_group
    second.name = 'Second copy'
    second.definition = first.definition
    second.entities = first.entities
    second.transformation = Geom::Transformation.translation([20, 0, 0])
    dictionary = Struct.new(:name, :values) do
      def each(&block); values.each(&block); end
    end
    first.define_singleton_method(:attribute_dictionaries) { [dictionary.new('instance', { 'phase' => 'A' })] }
    second.define_singleton_method(:attribute_dictionaries) { [dictionary.new('instance', { 'phase' => 'B' })] }
    first.definition.define_singleton_method(:attribute_dictionaries) { [dictionary.new('definition', { 'shared' => 'yes' })] }

    graph = BOMEngine::CanonicalGraphBuilder.build(
      model: model, entities: model.entities,
      parent_transform: Geom::Transformation.new,
      settings: { include_edges: false, scene_scope: 'all' }, spatial: {}
    )

    groups = graph[:nodes].select { |node| node[:kind] == 'group_instance' }
    group_definitions = graph[:definitions].select { |definition| definition[:kind] == 'group_definition' }
    assert_equal 2, groups.length
    assert_equal ['First copy', 'Second copy'], groups.map { |node| node[:name] }
    assert_equal 1, group_definitions.length
    assert_equal 1, groups.map { |node| node[:definition_id] }.uniq.length
    assert_equal first.definition.guid, group_definitions.first.dig(:source_identity, :guid)
    assert_equal 'yes', group_definitions.first.dig(:attributes, 'definition', 'shared')
    assert_equal %w[A B], groups.map { |node| node.dig(:attributes, 'instance', 'phase') }
    assert_equal 1, graph[:meshes].sum { |mesh| mesh[:faces].length }
    assert_equal [0.0, 0.508], groups.map { |node| graph[:transforms][node[:transform_id]][12] }.sort

    decoded = BOMEngine::BOMCDecoder.decode(BOMEngine::BOMCWriter.pack(graph, profile: :visual)[:bytes])
    assert_equal 1, decoded[:meshes].sum { |mesh| mesh[:faces].length }
    assert_equal 2, decoded[:instances].count { |instance| instance[:kind] == 'group_instance' }
  end
end
