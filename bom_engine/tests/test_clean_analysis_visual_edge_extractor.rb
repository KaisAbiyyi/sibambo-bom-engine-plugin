# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../clean_analysis'

class CleanAnalysisVisualEdgeExtractorTest < Minitest::Test
  Point = Struct.new(:x, :y, :z)
  Vertex = Struct.new(:position)
  Layer = Struct.new(:visible?)
  Definition = Struct.new(:entities)
  Instance = Struct.new(:definition, :transformation)
  Scope = Struct.new(:root_definition_uuid)
  Snapshot = Struct.new(:scope, :occurrences)
  Occurrence = Struct.new(:definition_uuid)

  class Edge
    attr_reader :start, :end, :faces, :layer

    def initialize(start_point, end_point, faces: [], hidden: false, visible: true)
      @start = Vertex.new(start_point)
      @end = Vertex.new(end_point)
      @faces = faces
      @hidden = hidden
      @visible = visible
      @layer = Layer.new(true)
    end

    def hidden?
      @hidden
    end

    def visible?
      @visible
    end
  end

  class IdentityPlan
    def initialize(values)
      @values = values
    end

    def source_uuid_for(entity)
      @values.fetch(entity)
    end
  end

  def test_extracts_only_visible_standalone_root_and_definition_edges
    root_edge = Edge.new(Point.new(0, 0, 0), Point.new(10, 0, 0))
    topology_edge = Edge.new(Point.new(0, 0, 0), Point.new(0, 10, 0), faces: [Object.new])
    hidden_edge = Edge.new(Point.new(0, 0, 0), Point.new(0, 0, 10), hidden: true)
    nested_edge = Edge.new(Point.new(0, 0, 0), Point.new(0, 20, 0))
    definition = Definition.new([nested_edge])
    instance = Instance.new(definition, Object.new)
    hidden_only_edge = Edge.new(Point.new(0, 0, 0), Point.new(30, 0, 0))
    hidden_only_definition = Definition.new([hidden_only_edge])
    hidden_only_instance = Instance.new(hidden_only_definition, Object.new)
    root_uuid = uuid(1)
    definition_uuid = uuid(2)
    plan = IdentityPlan.new(
      root_edge => uuid(3), topology_edge => uuid(4), hidden_edge => uuid(5),
      definition => definition_uuid, nested_edge => uuid(6),
      hidden_only_definition => uuid(7), hidden_only_edge => uuid(8)
    )

    edges = BOMEngine::CleanAnalysis::VisualEdgeExtractor.extract(
      roots: [root_edge, topology_edge, hidden_edge, instance, hidden_only_instance],
      identity_plan: plan,
      snapshot: Snapshot.new(
        Scope.new(root_uuid),
        [Occurrence.new(root_uuid), Occurrence.new(definition_uuid)]
      )
    )

    assert_equal [[root_uuid, uuid(3)], [definition_uuid, uuid(6)]],
                 edges.map { |edge| [edge.fetch(:definition_uuid), edge.fetch(:source_uuid)] }
    assert_equal [[0.0, 0.0, 0.0], [0.254, 0.0, 0.0]], edges.first.fetch(:vertices)
    assert_equal [[0.0, 0.0, 0.0], [0.0, 0.508, 0.0]], edges.last.fetch(:vertices)
  end

  private

  def uuid(index)
    format('20000000-0000-4000-8000-%012x', index)
  end
end
