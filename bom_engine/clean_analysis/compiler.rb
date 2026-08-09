# frozen_string_literal: true

require 'digest'

module BOMEngine
  module CleanAnalysis
    # Converts the private extraction snapshot into a small, analysis-oriented
    # document. Polygon surfaces are authoritative; triangulation is never
    # emitted by this compiler.
    class Compiler
      FORMAT_IDENTIFIER = 'bom_engine_clean_v1'.freeze
      FORMAT_VERSION = '1.0.0'.freeze
      POSITION_TOLERANCE_M = 1.0e-6
      NORMAL_TOLERANCE = 1.0e-6
      VERTICAL_NORMAL_Z_MAX = 0.15
      HORIZONTAL_NORMAL_Z_MIN = 0.95

      SURFACE_ROLES = {
        'wall' => 'wall',
        'exterior_wall' => 'wall',
        'interior_wall' => 'wall',
        'floor' => 'floor',
        'ceiling' => 'ceiling',
        'roof' => 'roof',
        'opening' => 'opening'
      }.freeze
      COMPONENT_ROLES = {
        'door' => 'door',
        'window' => 'window',
        'opening' => 'opening',
        'furniture' => 'furniture',
        'fixture' => 'fixture'
      }.freeze
      ENTOURAGE_PATTERN = /(?:\bsree\b|\b(?:human|person|people|entourage|man|woman)\b)/i.freeze
      DECORATION_PATTERN = /\b(?:plant|tree|vegetation|decoration|decorative|ornament|presentation)\b/i.freeze

      class << self
        def compile(snapshot_document, progress: nil)
          new(snapshot_document, progress: progress).compile
        end
      end

      def initialize(snapshot_document, progress: nil)
        unless snapshot_document.is_a?(BOMEngine::SemanticV2::Snapshot::Document)
          raise ArgumentError, 'clean analysis compiler requires a neutral extraction snapshot'
        end

        @snapshot = snapshot_document
        @progress = progress
        @definitions = snapshot_document.definitions.each_with_object({}) do |definition, index|
          checkpoint('Compiling definition index')
          index[definition.source_uuid] = definition
        end
        @primitives = snapshot_document.primitives.each_with_object({}) do |primitive, index|
          checkpoint('Compiling primitive index')
          index[primitive.key] = primitive
        end
        @labels = Hash.new { |hash, key| hash[key] = [] }
        snapshot_document.evidence.each do |item|
          checkpoint('Compiling semantic evidence')
          next unless item.is_a?(BOMEngine::SemanticV2::Snapshot::LabelEvidence)

          @labels[[item.target_kind, item.target_key]] << item
        end
        @excluded_primitive_count = 0
      end

      def compile
        candidates = []
        components = []
        excluded_objects = []
        excluded_paths = []

        @snapshot.occurrences.sort_by { |occurrence| [occurrence.uuid_path.length, occurrence.uuid_path] }.each do |occurrence|
          checkpoint('Compiling model occurrences')
          next if path_below_any?(occurrence.uuid_path, excluded_paths)

          definition = @definitions.fetch(occurrence.definition_uuid)
          label = primary_label('occurrence', occurrence.uuid_path)
          category = occurrence_category(occurrence, definition, label)
          if %w[entourage decoration].include?(category)
            excluded_paths << occurrence.uuid_path
            @excluded_primitive_count += definition.primitive_keys.length
            excluded_objects << excluded_object(occurrence, label, category)
          elsif surface_category?(category) || category == 'container'
            definition.primitive_keys.each do |primitive_key|
              checkpoint('Compiling polygon candidates')
              candidates << surface_candidate(
                occurrence,
                @primitives.fetch(primitive_key),
                occurrence_category: category,
                occurrence_label: label
              )
            end
          else
            components << compact_component(occurrence, definition, label, category)
          end
        end

        contextualize_geometry_hints!(candidates)
        compiled_surfaces = merge_candidates(candidates)
        surfaces, invalid_surfaces = compiled_surfaces.partition do |surface|
          checkpoint('Validating compiled surfaces')
          SurfaceValidator.validate(surface).empty?
        end
        surfaces.sort_by! { |surface| surface.fetch('id') }
        fallback_geometry = invalid_surfaces.map do |surface|
          checkpoint('Recording unresolved surfaces')
          {
            'id' => stable_id('unresolved', surface.fetch('id')),
            'status' => 'unresolved',
            'reason' => 'invalid_surface',
            'source_count' => surface.fetch('source_count'),
            'area_m2' => surface.fetch('area_m2'),
            'validation_issues' => SurfaceValidator.validate(surface)
          }
        end.sort_by { |item| item.fetch('id') }
        components.sort_by! { |component| component.fetch('id') }
        excluded_objects.sort_by! { |item| item.fetch('id') }
        raw_vertices = surfaces.inject(0) do |total, surface|
          total + surface.fetch('outer').length + surface.fetch('holes').inject(0) { |sum, loop| sum + loop.length }
        end

        {
          'format' => {
            'identifier' => FORMAT_IDENTIFIER,
            'version' => FORMAT_VERSION
          },
          'units' => 'm',
          'coordinate_system' => {
            'handedness' => 'right',
            'up_axis' => '+Z',
            'true_north_xy' => @snapshot.model_context.true_north_xy.dup
          },
          'model' => {
            'bounds' => bounds(surfaces, components)
          },
          'surfaces' => surfaces,
          'components' => components,
          'excluded_objects' => excluded_objects,
          'fallback_geometry' => fallback_geometry,
          'diagnostics' => {
            'excluded' => {
              'analysis_irrelevant_objects' => excluded_objects.length,
              'source_polygon_fragments' => @excluded_primitive_count
            },
            'counts' => {
              'source_polygon_fragments' => candidates.length,
              'architectural_surface_count' => surfaces.length,
              'component_count' => components.length,
              'excluded_object_count' => excluded_objects.length,
              'fallback_geometry_count' => fallback_geometry.length,
              'unresolved_fragment_count' => fallback_geometry.inject(0) do |sum, item|
                sum + item.fetch('source_count')
              end,
              'omitted_component_source_fragments' => components.inject(0) do |sum, component|
                sum + component.fetch('geometry').fetch('source_count')
              end,
              'raw_vertices_serialized' => raw_vertices,
              'raw_triangle_indices_serialized' => 0
            },
            'area_m2' => {
              'source' => clean_number(candidates.inject(0.0) { |sum, item| sum + item.fetch(:area_m2) }),
              'resolved' => clean_number(surfaces.inject(0.0) { |sum, item| sum + item.fetch('area_m2') }),
              'unresolved' => clean_number(fallback_geometry.inject(0.0) { |sum, item| sum + item.fetch('area_m2') })
            }
          }
        }
      end

      private

      def primary_label(kind, key, occurrence_path = nil)
        values = scoped_labels(kind, key, occurrence_path)
        values.find(&:primary) || values.first
      end

      def role_for(kind, key, occurrence_path = nil)
        values = scoped_labels(kind, key, occurrence_path)
        evidence = values.find { |item| !item.role.nil? && !item.role.to_s.empty? }
        evidence && evidence.role
      end

      def scoped_labels(kind, key, occurrence_path)
        values = @labels.fetch([kind, key], [])
        return values if kind != 'primitive' || occurrence_path.nil?

        exact = values.select { |item| item.target_occurrence_uuid_path == occurrence_path }
        return exact unless exact.empty?

        values.select { |item| item.target_occurrence_uuid_path.nil? }
      end

      def occurrence_category(occurrence, definition, label)
        role = role_for('occurrence', occurrence.uuid_path)
        return SURFACE_ROLES.fetch(role) if SURFACE_ROLES.key?(role)
        return COMPONENT_ROLES.fetch(role) if COMPONENT_ROLES.key?(role)

        text = label && label.label.to_s
        return 'entourage' if text && ENTOURAGE_PATTERN.match?(text)
        return 'decoration' if text && DECORATION_PATTERN.match?(text)
        return 'container' if occurrence.uuid_path.empty? || %w[model group].include?(definition.kind)
        return 'container' if definition.primitive_keys.any? do |primitive_key|
          SURFACE_ROLES.key?(role_for('primitive', primitive_key, occurrence.uuid_path))
        end

        'unknown'
      end

      def surface_category?(category)
        %w[wall floor ceiling roof opening].include?(category)
      end

      def path_below_any?(path, prefixes)
        prefixes.any? do |prefix|
          path.length > prefix.length && path.first(prefix.length) == prefix
        end
      end

      def excluded_object(occurrence, label, category)
        {
          'id' => stable_id('excluded', occurrence.uuid_path),
          'name' => display_name(label, category),
          'category' => category,
          'reason' => 'analysis_irrelevant'
        }
      end

      def compact_component(occurrence, definition, label, category)
        {
          'id' => stable_id('component', occurrence.uuid_path),
          'name' => display_name(label, category),
          'category' => category,
          'transform' => occurrence.transform.map { |value| clean_number(value) },
          'geometry' => {
            'status' => 'omitted',
            'reason' => 'clean_analysis_profile',
            'source_count' => definition.primitive_keys.length
          }
        }
      end

      def display_name(label, category)
        value = label && label.label.to_s.strip
        value.nil? || value.empty? ? category.capitalize : value
      end

      def surface_candidate(occurrence, primitive, occurrence_category:, occurrence_label:)
        primitive_label = primary_label('primitive', primitive.key, occurrence.uuid_path)
        explicit_role = SURFACE_ROLES[role_for('primitive', primitive.key, occurrence.uuid_path)]
        inherited_role = surface_category?(occurrence_category) ? occurrence_category : nil
        type = explicit_role || inherited_role || geometric_surface_type(primitive.normal)
        label = primitive_label || (inherited_role && occurrence_label)
        world_loops = primitive.loops.map do |loop|
          [loop.kind, loop.vertices.map { |point| transform_point(occurrence.transform, point) }]
        end
        outer = world_loops.find { |kind, _points| kind == 'outer' }.last
        holes = world_loops.select { |kind, _points| kind == 'hole' }.map(&:last)
        normal = transform_normal(occurrence.transform, primitive.normal)
        semantic_role = explicit_role || inherited_role
        classification_method = if semantic_role && label
                                  label.explicit ? 'explicit_label' : 'semantic_label'
                                elsif semantic_role
                                  'semantic_role'
                                elsif label
                                  'label_hint'
                                else
                                  'geometry_hint'
                                end

        {
          occurrence_path: occurrence.uuid_path,
          primitive_key: primitive.key,
          adjacent_keys: primitive.loops.flat_map(&:adjacent_primitive_keys).uniq,
          type: type,
          outer: outer,
          holes: holes,
          normal: normal,
          area_m2: loop_area(outer) - holes.inject(0.0) { |sum, hole| sum + loop_area(hole) },
          front_material_uuid: primitive.front_material_uuid,
          back_material_uuid: primitive.back_material_uuid,
          source_count: 1,
          classification: {
            'method' => classification_method,
            'label' => label && label.label,
            'source' => label && label.source
          }.reject { |_key, value| value.nil? }
        }
      end

      def contextualize_geometry_hints!(candidates)
        geometric = candidates.select do |candidate|
          %w[geometry_hint label_hint].include?(
            candidate.fetch(:classification).fetch('method')
          )
        end
        return if geometric.empty?

        all_points = candidates.flat_map { |candidate| candidate.fetch(:outer) }
        minimum_z = all_points.map { |point| point[2] }.min
        maximum_z = all_points.map { |point| point[2] }.max
        model_height = maximum_z.to_f - minimum_z.to_f
        upward = geometric.select { |candidate| candidate.fetch(:type) == 'floor' }
        downward = geometric.select { |candidate| candidate.fetch(:type) == 'ceiling' }
        primary_floor_z = upward.map { |candidate| mean_z(candidate.fetch(:outer)) }.min
        primary_ceiling_z = downward.map { |candidate| mean_z(candidate.fetch(:outer)) }.max

        geometric.each do |candidate|
          type = candidate.fetch(:type)
          reason = nil
          case type
          when 'wall'
            height = z_span(candidate.fetch(:outer))
            fill_ratio = planar_fill_ratio(candidate)
            if model_height > POSITION_TOLERANCE_M &&
               height / model_height >= 0.5 && fill_ratio >= 0.5
              reason = 'full_height_vertical_region'
            else
              candidate[:type] = 'other_architectural_surface'
              reason = 'thin_or_fragmentary_vertical_region'
            end
          when 'floor'
            if primary_floor_z && (mean_z(candidate.fetch(:outer)) - primary_floor_z).abs <= POSITION_TOLERANCE_M
              reason = 'primary_lowest_upward_region'
            else
              candidate[:type] = 'other_architectural_surface'
              reason = 'secondary_upward_region'
            end
          when 'ceiling'
            if primary_ceiling_z && (mean_z(candidate.fetch(:outer)) - primary_ceiling_z).abs <= POSITION_TOLERANCE_M
              reason = 'primary_highest_downward_region'
            else
              candidate[:type] = 'other_architectural_surface'
              reason = 'secondary_downward_region'
            end
          else
            reason = 'sloped_geometry_region'
          end
          candidate.fetch(:classification)['reason'] = reason
        end
      end

      def z_span(points)
        values = points.map { |point| point[2] }
        values.max.to_f - values.min.to_f
      end

      def mean_z(points)
        points.inject(0.0) { |sum, point| sum + point[2].to_f } / points.length
      end

      def planar_fill_ratio(candidate)
        normal = candidate.fetch(:normal)
        omitted_axis = normal.each_index.max_by { |index| normal[index].abs }
        axes = [0, 1, 2] - [omitted_axis]
        points = candidate.fetch(:outer)
        bounding_area = axes.inject(1.0) do |product, axis|
          values = points.map { |point| point[axis] }
          product * (values.max.to_f - values.min.to_f)
        end
        return 0.0 if bounding_area <= POSITION_TOLERANCE_M**2

        candidate.fetch(:area_m2) / bounding_area
      end

      def geometric_surface_type(normal)
        z = normalize(normal)[2]
        return 'wall' if z.abs <= VERTICAL_NORMAL_Z_MAX
        return 'floor' if z >= HORIZONTAL_NORMAL_Z_MIN
        return 'ceiling' if z <= -HORIZONTAL_NORMAL_Z_MIN

        'roof'
      end

      def merge_candidates(candidates)
        candidates.group_by { |candidate| merge_group_key(candidate) }.values.flat_map do |group|
          checkpoint('Merging coplanar surfaces')
          connected_components(group).flat_map do |component|
            checkpoint('Merging connected surface regions')
            merged = merge_component(component)
            merged.nil? ? component.map { |candidate| surface_hash(candidate) } : [surface_hash(merged)]
          end
        end
      end

      def merge_group_key(candidate)
        normal = candidate.fetch(:normal)
        plane = dot(normal, candidate.fetch(:outer).first)
        [
          candidate.fetch(:occurrence_path),
          candidate.fetch(:type),
          candidate.fetch(:front_material_uuid),
          candidate.fetch(:back_material_uuid),
          candidate.fetch(:classification),
          normal.map { |value| quantize(value, NORMAL_TOLERANCE) },
          quantize(plane, POSITION_TOLERANCE_M)
        ]
      end

      def connected_components(group)
        by_key = group.each_with_object({}) { |candidate, index| index[candidate.fetch(:primitive_key)] = candidate }
        remaining = group.dup
        components = []
        until remaining.empty?
          seed = remaining.shift
          component = []
          pending = [seed]
          until pending.empty?
            current = pending.shift
            next if component.include?(current)

            component << current
            current.fetch(:adjacent_keys).each do |key|
              neighbor = by_key[key]
              if neighbor && !component.include?(neighbor)
                remaining.delete(neighbor)
                pending << neighbor
              end
            end
          end
          components << component
        end
        components
      end

      def merge_component(component)
        return component.first if component.length == 1

        boundary_loops = union_boundary_loops(component.map { |candidate| candidate.fetch(:outer) })
        return nil if boundary_loops.nil? || boundary_loops.empty?

        ordered = boundary_loops.sort_by { |loop| -loop_area(loop) }
        first = component.first
        return nil unless ordered.drop(1).all? do |loop|
          SurfaceValidator.loop_inside?(loop, ordered.first, first.fetch(:normal))
        end

        first.merge(
          primitive_key: component.map { |item| item.fetch(:primitive_key) }.sort,
          adjacent_keys: [],
          outer: ordered.first,
          holes: ordered.drop(1) + component.flat_map { |item| item.fetch(:holes) },
          area_m2: component.inject(0.0) { |sum, item| sum + item.fetch(:area_m2) },
          source_count: component.inject(0) { |sum, item| sum + item.fetch(:source_count) }
        )
      end

      def union_boundary_loops(loops)
        all_points = loops.flatten(1)
        segments = {}
        loops.each do |loop|
          loop.each_with_index do |start_point, index|
            end_point = loop[(index + 1) % loop.length]
            split_segment(start_point, end_point, all_points).each_cons(2) do |split_start, split_end|
              start_key = point_key(split_start)
              end_key = point_key(split_end)
              next if start_key == end_key

              undirected = [start_key, end_key].sort
              entry = segments[undirected]
              if entry
                return nil unless entry.fetch(:start_key) == end_key && entry.fetch(:end_key) == start_key

                segments.delete(undirected)
              else
                segments[undirected] = {
                  start_key: start_key,
                  end_key: end_key,
                  start_point: split_start,
                  end_point: split_end
                }
              end
            end
          end
        end

        outgoing = Hash.new { |hash, key| hash[key] = [] }
        segments.values.each { |segment| outgoing[segment.fetch(:start_key)] << segment }
        return nil if outgoing.values.any? { |values| values.length != 1 }

        remaining = segments.values.dup
        result = []
        until remaining.empty?
          first = remaining.min_by { |segment| segment.fetch(:start_key) }
          loop = []
          current = first
          start_key = first.fetch(:start_key)
          loop_guard = 0
          loop do
            loop << current.fetch(:start_point)
            remaining.delete(current)
            next_key = current.fetch(:end_key)
            break if next_key == start_key

            current = outgoing.fetch(next_key, []).first
            return nil if current.nil? || !remaining.include?(current)

            loop_guard += 1
            return nil if loop_guard > segments.length
          end
          simplified = simplify_loop(loop)
          return nil if simplified.length < 3

          result << normalize_loop_start(simplified)
        end
        result
      end

      def split_segment(start_point, end_point, candidates)
        direction = subtract(end_point, start_point)
        length_squared = dot(direction, direction)
        return [start_point, end_point] if length_squared <= POSITION_TOLERANCE_M**2

        points = candidates.each_with_object({}) do |point, index|
          offset = subtract(point, start_point)
          next if vector_length(cross(direction, offset)) > POSITION_TOLERANCE_M * Math.sqrt(length_squared)

          parameter = dot(offset, direction) / length_squared
          next if parameter < -POSITION_TOLERANCE_M || parameter > 1.0 + POSITION_TOLERANCE_M

          index[point_key(point)] = [parameter, point]
        end
        points.values.sort_by(&:first).map(&:last)
      end

      def simplify_loop(loop)
        points = loop.dup
        changed = true
        while changed && points.length > 3
          changed = false
          points.length.times do |index|
            previous = points[(index - 1) % points.length]
            current = points[index]
            following = points[(index + 1) % points.length]
            first = subtract(current, previous)
            second = subtract(following, current)
            next unless vector_length(cross(first, second)) <= POSITION_TOLERANCE_M && dot(first, second) > 0.0

            points.delete_at(index)
            changed = true
            break
          end
        end
        points
      end

      def normalize_loop_start(loop)
        start_index = loop.each_index.min_by { |index| point_key(loop[index]) }
        loop.rotate(start_index)
      end

      def surface_hash(candidate)
        primitive_keys = candidate.fetch(:primitive_key)
        primitive_keys = [primitive_keys] unless primitive_keys.first.is_a?(Array)
        outer = normalize_loop_start(candidate.fetch(:outer)).map { |point| clean_point(point) }
        holes = candidate.fetch(:holes).map { |hole| normalize_loop_start(hole).map { |point| clean_point(point) } }
        {
          'id' => stable_id(
            'surface',
            candidate.fetch(:occurrence_path) + primitive_keys.flatten.sort + [candidate.fetch(:type)]
          ),
          'type' => candidate.fetch(:type),
          'outer' => outer,
          'holes' => holes,
          'normal' => clean_point(candidate.fetch(:normal)),
          'area_m2' => clean_number(candidate.fetch(:area_m2)),
          'source_count' => candidate.fetch(:source_count),
          'orientation' => orientation(candidate.fetch(:normal)),
          'classification' => candidate.fetch(:classification)
        }
      end

      def orientation(normal)
        vector = normalize(normal)
        if vector[2].abs >= HORIZONTAL_NORMAL_Z_MIN
          { 'kind' => vector[2].positive? ? 'up' : 'down' }
        else
          north = @snapshot.model_context.true_north_xy
          world_azimuth = Math.atan2(vector[0], vector[1]) * 180.0 / Math::PI
          north_azimuth = Math.atan2(north[0], north[1]) * 180.0 / Math::PI
          {
            'kind' => vector[2].abs <= VERTICAL_NORMAL_Z_MAX ? 'vertical' : 'sloped',
            'azimuth_deg' => clean_number((world_azimuth - north_azimuth) % 360.0)
          }
        end
      end

      def bounds(surfaces, components)
        points = surfaces.flat_map do |surface|
          surface.fetch('outer') + surface.fetch('holes').flatten(1)
        end
        points.concat(components.map do |component|
          transform = component.fetch('transform')
          [transform[12], transform[13], transform[14]]
        end)
        return { 'min' => [0.0, 0.0, 0.0], 'max' => [0.0, 0.0, 0.0] } if points.empty?

        {
          'min' => 3.times.map { |axis| clean_number(points.map { |point| point[axis] }.min) },
          'max' => 3.times.map { |axis| clean_number(points.map { |point| point[axis] }.max) }
        }
      end

      def stable_id(prefix, values)
        bytes = Array(values).flatten.map(&:to_s).join('|')
        "#{prefix}-#{Digest::SHA256.hexdigest(bytes)[0, 16]}"
      end

      def transform_point(matrix, point)
        [
          matrix[0] * point[0] + matrix[4] * point[1] + matrix[8] * point[2] + matrix[12],
          matrix[1] * point[0] + matrix[5] * point[1] + matrix[9] * point[2] + matrix[13],
          matrix[2] * point[0] + matrix[6] * point[1] + matrix[10] * point[2] + matrix[14]
        ]
      end

      def transform_normal(matrix, normal)
        normalize([
          matrix[0] * normal[0] + matrix[4] * normal[1] + matrix[8] * normal[2],
          matrix[1] * normal[0] + matrix[5] * normal[1] + matrix[9] * normal[2],
          matrix[2] * normal[0] + matrix[6] * normal[1] + matrix[10] * normal[2]
        ])
      end

      def loop_area(loop)
        return 0.0 if loop.length < 3

        sum = [0.0, 0.0, 0.0]
        loop.each_with_index do |point, index|
          following = loop[(index + 1) % loop.length]
          edge_cross = cross(point, following)
          3.times { |axis| sum[axis] += edge_cross[axis] }
        end
        vector_length(sum) / 2.0
      end

      def normalize(vector)
        length = vector_length(vector)
        return [0.0, 0.0, 0.0] if length <= NORMAL_TOLERANCE

        vector.map { |value| value.to_f / length }
      end

      def vector_length(vector)
        Math.sqrt(vector.inject(0.0) { |sum, value| sum + value.to_f**2 })
      end

      def subtract(left, right)
        3.times.map { |axis| left[axis] - right[axis] }
      end

      def cross(left, right)
        [
          left[1] * right[2] - left[2] * right[1],
          left[2] * right[0] - left[0] * right[2],
          left[0] * right[1] - left[1] * right[0]
        ]
      end

      def dot(left, right)
        3.times.inject(0.0) { |sum, axis| sum + left[axis] * right[axis] }
      end

      def point_key(point)
        point.map { |value| quantize(value, POSITION_TOLERANCE_M) }.join(',')
      end

      def quantize(value, tolerance)
        (value.to_f / tolerance).round
      end

      def clean_point(point)
        point.map { |value| clean_number(value) }
      end

      def clean_number(value)
        rounded = value.to_f.round(9)
        rounded.zero? ? 0.0 : rounded
      end

      def checkpoint(stage)
        @progress.call(stage) if @progress
      end
    end
  end
end
