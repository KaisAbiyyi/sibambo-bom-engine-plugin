# frozen_string_literal: true

require 'json'

module BOMEngine
  module CleanAnalysis
    # Collects bounded, non-persisted diagnostics while the clean compiler runs.
    class Profiler
      TOP_LIMIT = 20
      SURFACE_TYPES = %w[
        wall floor ceiling roof other_architectural_surface opening
      ].freeze

      def initialize(snapshot)
        unless snapshot.is_a?(BOMEngine::SemanticV2::Snapshot::Document)
          raise ArgumentError, 'clean export profiler requires an extraction snapshot'
        end

        @snapshot = snapshot
        @definition_usage = Hash.new(0)
        snapshot.occurrences.each do |occurrence|
          @definition_usage[occurrence.definition_uuid] += 1 unless occurrence.uuid_path.empty?
        end
        @occurrences = {}
        @definition_bytes = Hash.new(0)
        @expanded_definitions = Hash.new(0)
        @expanded_occurrence_count = 0
        @occurrence_expanded_geometry = 0
        @largest_surfaces = []
      end

      def record_occurrence(occurrence, definition, category:, disposition:)
        key = path_key(occurrence.uuid_path)
        @occurrences[key] = {
          'occurrence_path' => occurrence.uuid_path.dup,
          'definition_id' => definition.source_uuid,
          'category' => category,
          'disposition' => disposition,
          'estimated_serialized_bytes' => 0
        }
        return if occurrence.uuid_path.empty? || disposition != 'expanded'

        @expanded_occurrence_count += 1
        @occurrence_expanded_geometry += definition.primitive_keys.length
        @expanded_definitions[definition.source_uuid] += 1
      end

      def record_component(component, occurrence)
        add_occurrence_bytes(occurrence.uuid_path, JSON.generate(component).bytesize)
      end

      def record_instance(instance, occurrence)
        add_occurrence_bytes(occurrence.uuid_path, JSON.generate(instance).bytesize)
      end

      def record_definition(definition, source_definition_id)
        @definition_bytes[source_definition_id] += JSON.generate(definition).bytesize
      end

      def record_surface(surface, candidate)
        bytes = JSON.generate(surface).bytesize
        definition_id = candidate.fetch(:definition_uuid)
        occurrence_path = candidate.fetch(:occurrence_path)
        @definition_bytes[definition_id] += bytes
        add_occurrence_bytes(occurrence_path, bytes)
        retain_largest(
          @largest_surfaces,
          {
            'id' => surface.fetch('id'),
            'type' => surface.fetch('type'),
            'estimated_serialized_bytes' => bytes,
            'source_count' => surface.fetch('source_count'),
            'definition_id' => definition_id,
            'occurrence_path' => occurrence_path.dup
          }
        )
      end

      def report(document, progress: nil)
        minified_bytes = Writer.measure(document, progress: progress)
        pretty_bytes = Writer.measure(document, progress: progress, pretty_print: true)
        surface_counts = SURFACE_TYPES.each_with_object({}) { |type, counts| counts[type] = 0 }
        document.fetch('surfaces').each do |surface|
          report_progress(progress)
          surface_counts[surface.fetch('type')] += 1
        end
        definition_polygon_count = document.fetch('definitions', []).inject(0) do |sum, definition|
          sum + definition.dig('geometry', 'surfaces').length
        end
        surface_counts['visual_architectural_detail'] = document.fetch('definitions', []).inject(0) do |sum, definition|
          next sum unless definition.fetch('retention') == 'visual_architectural_detail'

          sum + definition.dig('geometry', 'surfaces').length
        end
        surface_counts['unresolved_fallback'] = document.fetch('fallback_geometry').length
        surface_counts['excluded'] = document.fetch('excluded_objects').length

        vertex_occurrences = 0
        positions = {}
        each_geometry_surface(document) do |scope, surface|
          report_progress(progress)
          loops = [surface.fetch('outer')] + surface.fetch('holes')
          loops.each do |loop|
            loop.each do |point|
              vertex_occurrences += 1
              positions["#{scope}|#{position_key(point)}"] = true
            end
          end
        end
        unique_positions = positions.length
        vertex_ratio = unique_positions.zero? ? 0.0 : vertex_occurrences.to_f / unique_positions
        top_level_vertex_occurrences = document.fetch('surfaces').inject(0) do |sum, surface|
          sum + surface.fetch('outer').length +
            surface.fetch('holes').inject(0) { |hole_sum, loop| hole_sum + loop.length }
        end
        definition_vertex_pool_positions = document.fetch('definitions', []).inject(0) do |sum, definition|
          sum + definition.dig('geometry', 'vertices').length
        end
        serialized_vertex_positions = top_level_vertex_occurrences + definition_vertex_pool_positions
        serialized_vertex_ratio = if unique_positions.zero?
                                    0.0
                                  else
                                    serialized_vertex_positions.to_f / unique_positions
                                  end
        instance_definitions = @snapshot.occurrences.reject { |item| item.uuid_path.empty? }
        definitions_by_id = @snapshot.definitions.each_with_object({}) do |definition, index|
          index[definition.source_uuid] = definition
        end
        component_occurrences = instance_definitions.select do |occurrence|
          definitions_by_id.fetch(occurrence.definition_uuid).kind == 'component'
        end
        group_occurrences = instance_definitions.select do |occurrence|
          definitions_by_id.fetch(occurrence.definition_uuid).kind == 'group'
        end
        expanded_unique_geometry = @expanded_definitions.keys.inject(0) do |sum, definition_id|
          sum + definitions_by_id.fetch(definition_id).primitive_keys.length
        end
        expansion_ratio = if expanded_unique_geometry.zero?
                            0.0
                          else
                            @occurrence_expanded_geometry.to_f / expanded_unique_geometry
                          end

        {
          'output_bytes' => {
            'minified' => minified_bytes,
            'pretty_estimated' => pretty_bytes
          },
          'surface_counts' => surface_counts,
          'geometry' => {
            'polygon_count' => document.fetch('surfaces').length + definition_polygon_count,
            'analytical_polygon_count' => document.fetch('surfaces').length,
            'definition_polygon_count' => definition_polygon_count,
            'total_polygon_vertex_occurrences' => vertex_occurrences,
            'unique_vertex_positions' => unique_positions,
            'vertex_duplication_ratio' => rounded_ratio(vertex_ratio),
            'serialized_vertex_positions' => serialized_vertex_positions,
            'serialized_vertex_duplication_ratio' => rounded_ratio(serialized_vertex_ratio),
            'definition_vertex_pool_positions' => definition_vertex_pool_positions
          },
          'sketchup_structure' => structure_report(
            definitions_by_id,
            instance_definitions,
            component_occurrences,
            group_occurrences
          ),
          'expansion' => {
            'expanded_occurrence_count' => @expanded_occurrence_count,
            'source_face_count_in_unique_definitions' => expanded_unique_geometry,
            'occurrence_expanded_geometry' => @occurrence_expanded_geometry,
            'instance_expansion_ratio' => rounded_ratio(expansion_ratio)
          },
          'serialized_byte_attribution' => byte_attribution(document, minified_bytes, progress),
          'top_offenders' => {
            'definitions' => top_definitions(definitions_by_id),
            'component_occurrences' => top_occurrences,
            'surfaces' => sorted_largest(@largest_surfaces)
          }
        }
      end

      private

      def structure_report(definitions_by_id, instances, components, groups)
        root = @snapshot.occurrences.find { |occurrence| occurrence.uuid_path.empty? }
        root_definition = root && definitions_by_id.fetch(root.definition_uuid)
        repeated = @definition_usage.select { |_id, count| count > 1 }
        {
          'loose_face_count' => root_definition ? root_definition.primitive_keys.length : 0,
          'group_count' => groups.length,
          'component_instance_count' => components.length,
          'occurrence_count' => @snapshot.occurrences.length,
          'unique_definition_count' => @snapshot.definitions.length,
          'unique_component_definition_count' => components.map(&:definition_uuid).uniq.length,
          'nested_instance_count' => instances.count { |occurrence| occurrence.uuid_path.length > 1 },
          'repeated_definition_count' => repeated.length,
          'repeated_definition_usage_count' => repeated.values.inject(0, :+)
        }
      end

      def byte_attribution(document, minified_bytes, progress)
        surface_bytes = Hash.new(0)
        polygon_coordinates = 0
        polygon_topology = 0
        document.fetch('surfaces').each do |surface|
          report_progress(progress)
          surface_bytes[surface.fetch('type')] += JSON.generate(surface).bytesize
          polygon_coordinates += JSON.generate(surface.fetch('outer')).bytesize
          polygon_coordinates += JSON.generate(surface.fetch('holes')).bytesize
        end
        definition_bytes = json_record_bytes(document.fetch('definitions', []))
        instance_bytes = json_record_bytes(document.fetch('instances', []))
        component_bytes = json_record_bytes(document.fetch('components'))
        excluded_bytes = json_record_bytes(document.fetch('excluded_objects'))
        fallback_bytes = json_record_bytes(document.fetch('fallback_geometry'))
        document.fetch('definitions', []).each do |definition|
          geometry = definition.fetch('geometry')
          polygon_coordinates += JSON.generate(geometry.fetch('vertices')).bytesize
          definition.dig('geometry', 'surfaces').each do |surface|
            report_progress(progress)
            polygon_topology += JSON.generate(surface.fetch('outer')).bytesize
            polygon_topology += JSON.generate(surface.fetch('holes')).bytesize
          end
        end
        attributed = surface_bytes.values.inject(0, :+) + definition_bytes + instance_bytes +
                     component_bytes + excluded_bytes + fallback_bytes
        repeated_geometry = @definition_bytes.inject(0) do |sum, (definition_id, bytes)|
          @definition_usage[definition_id] > 1 ? sum + bytes : sum
        end
        result = SURFACE_TYPES.each_with_object({}) do |type, values|
          values[type] = surface_bytes[type]
        end
        result.merge(
          'repeated_component_geometry' => repeated_geometry,
          'shared_definitions' => definition_bytes,
          'instances' => instance_bytes,
          'component_records' => component_bytes,
          'metadata' => [minified_bytes - attributed, 0].max,
          'excluded_objects' => excluded_bytes,
          'fallback_geometry' => fallback_bytes,
          'polygon_coordinates' => polygon_coordinates,
          'polygon_topology_indices' => polygon_topology
        )
      end

      def top_definitions(definitions_by_id)
        definitions_by_id.values.map do |definition|
          {
            'definition_id' => definition.source_uuid,
            'kind' => definition.kind,
            'source_face_count' => definition.primitive_keys.length,
            'occurrence_count' => @definition_usage[definition.source_uuid],
            'expanded_occurrence_count' => @expanded_definitions[definition.source_uuid],
            'estimated_serialized_bytes' => @definition_bytes[definition.source_uuid]
          }
        end.sort_by do |item|
          [-item.fetch('estimated_serialized_bytes'), item.fetch('definition_id')]
        end.first(TOP_LIMIT)
      end

      def top_occurrences
        @occurrences.values.reject { |item| item.fetch('occurrence_path').empty? }.sort_by do |item|
          [-item.fetch('estimated_serialized_bytes'), item.fetch('occurrence_path')]
        end.first(TOP_LIMIT)
      end

      def add_occurrence_bytes(path, bytes)
        item = @occurrences[path_key(path)]
        item['estimated_serialized_bytes'] += bytes if item
      end

      def retain_largest(items, item)
        items << item
        items.sort_by! { |entry| [-entry.fetch('estimated_serialized_bytes'), entry.fetch('id')] }
        items.pop while items.length > TOP_LIMIT
      end

      def sorted_largest(items)
        items.sort_by { |entry| [-entry.fetch('estimated_serialized_bytes'), entry.fetch('id')] }
      end

      def path_key(path)
        path.join('/')
      end

      def position_key(point)
        point.map do |value|
          (value.to_f / Compiler::POSITION_TOLERANCE_M).round
        end.join(',')
      end

      def json_record_bytes(records)
        records.inject(0) { |sum, record| sum + JSON.generate(record).bytesize }
      end

      def rounded_ratio(value)
        value.to_f.round(6)
      end

      def each_geometry_surface(document)
        document.fetch('surfaces').each { |surface| yield('model', surface) }
        document.fetch('definitions', []).each do |definition|
          geometry = definition.fetch('geometry')
          vertices = geometry.fetch('vertices')
          geometry.fetch('surfaces').each do |surface|
            resolved = surface.merge(
              'outer' => surface.fetch('outer').map { |index| vertices.fetch(index) },
              'holes' => surface.fetch('holes').map do |loop|
                loop.map { |index| vertices.fetch(index) }
              end
            )
            yield(definition.fetch('id'), resolved)
          end
        end
      end

      def report_progress(progress)
        progress.call('Profiling clean JSON') if progress
      end
    end
  end
end
