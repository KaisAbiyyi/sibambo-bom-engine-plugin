# frozen_string_literal: true

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    # CleanV1-only SketchUp adapter for visible edges that are not polygon
    # topology. Semantic V2 remains unchanged.
    module VisualEdgeExtractor
      INCH_TO_M = 0.0254

      module_function

      def extract(roots:, identity_plan:, snapshot:, include_hidden: false, progress: nil)
        Builder.new(
          identity_plan: identity_plan,
          snapshot: snapshot,
          include_hidden: include_hidden,
          progress: progress
        ).extract(roots)
      end

      class Builder
        def initialize(identity_plan:, snapshot:, include_hidden:, progress:)
          @identity_plan = identity_plan
          @root_definition_uuid = snapshot.scope.root_definition_uuid
          @eligible_definition_uuids = snapshot.occurrences.each_with_object({}) do |occurrence, values|
            values[occurrence.definition_uuid] = true
          end
          @include_hidden = include_hidden == true
          @progress = progress
          @visited_definitions = {}
          @edges = {}
        end

        def extract(roots)
          scan_entities(Array(roots), @root_definition_uuid)
          @edges.values.sort_by do |edge|
            [edge.fetch(:definition_uuid), edge.fetch(:source_uuid)]
          end.freeze
        end

        private

        def scan_entities(entities, definition_uuid)
          entities.each do |entity|
            checkpoint
            if standalone_edge?(entity)
              add_edge(entity, definition_uuid) if visible?(entity)
            elsif instance?(entity)
              scan_definition(entity.definition)
            end
          end
        end

        def scan_definition(definition)
          definition_uuid = source_uuid(definition)
          return unless @eligible_definition_uuids[definition_uuid]
          return if @visited_definitions[definition_uuid]

          @visited_definitions[definition_uuid] = true
          scan_entities(Array(definition.entities), definition_uuid)
        end

        def add_edge(edge, definition_uuid)
          edge_uuid = source_uuid(edge)
          @edges[[definition_uuid, edge_uuid]] = {
            definition_uuid: definition_uuid,
            source_uuid: edge_uuid,
            vertices: [edge.start.position, edge.end.position].map do |position|
              point(position)
            end.freeze
          }.freeze
        end

        def standalone_edge?(entity)
          edge_class = defined?(Sketchup::Edge) && Sketchup::Edge
          is_edge = edge_class ? entity.is_a?(edge_class) :
            entity.respond_to?(:start) && entity.respond_to?(:end) && entity.respond_to?(:faces)
          is_edge && Array(entity.faces).empty?
        end

        def instance?(entity)
          instance_class = defined?(Sketchup::ComponentInstance) && Sketchup::ComponentInstance
          group_class = defined?(Sketchup::Group) && Sketchup::Group
          return true if instance_class && entity.is_a?(instance_class)
          return true if group_class && entity.is_a?(group_class)

          entity.respond_to?(:definition) && entity.respond_to?(:transformation)
        end

        def visible?(entity)
          return true if @include_hidden
          return false if entity.respond_to?(:hidden?) && entity.hidden?
          return false if entity.respond_to?(:visible?) && !entity.visible?

          layer = entity.respond_to?(:layer) ? entity.layer : nil
          !layer.respond_to?(:visible?) || layer.visible?
        end

        def source_uuid(entity)
          @identity_plan.source_uuid_for(entity).to_s.downcase
        end

        def point(position)
          [coordinate(position, 0, :x), coordinate(position, 1, :y), coordinate(position, 2, :z)].map do |value|
            value * INCH_TO_M
          end.freeze
        end

        def coordinate(value, index, method)
          value.respond_to?(method) ? value.public_send(method).to_f : Array(value).fetch(index).to_f
        end

        def checkpoint
          @progress.call('Extracting standalone visual edges') if @progress
        end
      end
    end
  end
end

end # SibamboHistory
