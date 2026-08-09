# frozen_string_literal: true

module BOMEngine
  module CleanAnalysis
    module SurfaceValidator
      POSITION_TOLERANCE_M = 1.0e-6
      NORMAL_TOLERANCE = 1.0e-6
      AREA_RELATIVE_TOLERANCE = 1.0e-6

      module_function

      def validate(surface)
        issues = []
        unless surface.is_a?(Hash)
          return ['surface must be an object']
        end

        normal = surface['normal']
        normal_valid = valid_point?(normal)
        if !normal_valid
          issues << 'normal must contain three finite coordinates'
        else
          length = vector_length(normal)
          issues << 'normal must be normalized' if (length - 1.0).abs > NORMAL_TOLERANCE
        end

        outer = surface['outer']
        outer_result = validate_loop(outer, 'outer')
        issues.concat(outer_result.fetch(:issues))
        plane_origin = outer_result.fetch(:points).first
        if normal_valid && plane_origin
          issues.concat(plane_issues(outer_result.fetch(:points), normal, plane_origin, 'outer'))
          derived_normal = outer_result.fetch(:normal)
          if derived_normal && dot(derived_normal, normal) < 1.0 - NORMAL_TOLERANCE
            issues << 'normal does not match outer polygon winding/plane'
          end
        end

        holes = surface['holes']
        if !holes.is_a?(Array)
          issues << 'holes must be an array'
          holes = []
        end
        hole_results = holes.each_with_index.map do |hole, index|
          result = validate_loop(hole, "hole[#{index}]")
          issues.concat(result.fetch(:issues))
          if normal_valid && plane_origin
            issues.concat(plane_issues(result.fetch(:points), normal, plane_origin, "hole[#{index}]"))
          end
          result
        end

        if normal_valid && outer_result.fetch(:points).length >= 3
          holes.each_with_index do |hole, index|
            next unless hole.is_a?(Array) && hole.all? { |point| valid_point?(point) }
            next if hole.empty?

            unless loop_inside?(hole, outer, normal)
              issues << "hole[#{index}] must lie strictly inside outer polygon"
            end
          end
        end

        stored_area = surface['area_m2']
        unless finite_number?(stored_area) && stored_area.to_f.positive?
          issues << 'area_m2 must be finite and greater than zero'
        end
        derived_area = outer_result.fetch(:area) - hole_results.inject(0.0) do |sum, result|
          sum + result.fetch(:area)
        end
        if derived_area <= POSITION_TOLERANCE_M**2
          issues << 'polygon-derived area must be greater than zero'
        elsif finite_number?(stored_area)
          tolerance = [POSITION_TOLERANCE_M, derived_area * AREA_RELATIVE_TOLERANCE].max
          if (stored_area.to_f - derived_area).abs > tolerance
            issues << 'area_m2 does not match polygon-derived area'
          end
        end

        issues.uniq
      end

      def validate!(surface)
        issues = validate(surface)
        return surface if issues.empty?

        identifier = surface.is_a?(Hash) ? surface['id'].to_s : ''
        raise ArgumentError, "invalid surface #{identifier}: #{issues.join('; ')}"
      end

      def loop_inside?(inner, outer, normal)
        return false unless inner.is_a?(Array) && outer.is_a?(Array)
        return false if inner.empty? || outer.length < 3

        axis = dominant_axis(normal)
        outer_2d = outer.map { |point| project(point, axis) }
        inner.all? do |point|
          projected = project(point, axis)
          point_in_polygon?(projected, outer_2d) &&
            outer_2d.each_with_index.none? do |start_point, index|
              point_on_segment_2d?(projected, start_point, outer_2d[(index + 1) % outer_2d.length])
            end
        end
      end

      def polygon_area(points)
        polygon_normal_and_area(points).last
      end

      def polygon_normal(points)
        polygon_normal_and_area(points).first
      end

      def valid_point?(point)
        point.is_a?(Array) && point.length == 3 && point.all? { |value| finite_number?(value) }
      end

      def finite_number?(value)
        value.is_a?(Numeric) && value.to_f.finite?
      end

      def validate_loop(loop, name)
        issues = []
        unless loop.is_a?(Array)
          return { issues: ["#{name} must be an array"], points: [], area: 0.0, normal: nil }
        end
        issues << "#{name} must contain at least three vertices" if loop.length < 3
        valid_points = loop.select { |point| valid_point?(point) }
        issues << "#{name} vertices must contain finite coordinates" if valid_points.length != loop.length
        if valid_points.length == loop.length
          distinct = loop.map { |point| point_key(point) }.uniq.length
          issues << "#{name} must contain at least three distinct vertices" if distinct < 3
          loop.each_with_index do |point, index|
            following = loop[(index + 1) % loop.length]
            if distance(point, following) <= POSITION_TOLERANCE_M
              issues << "#{name} contains duplicate consecutive points or a zero-length edge"
              break
            end
          end
          issues << "#{name} self-intersects" if loop.length >= 4 && self_intersecting?(loop)
        end
        normal, area = polygon_normal_and_area(valid_points)
        issues << "#{name} has zero polygon area" if loop.length >= 3 && area <= POSITION_TOLERANCE_M**2
        { issues: issues, points: valid_points, area: area, normal: normal }
      end
      private_class_method :validate_loop

      def plane_issues(points, normal, origin, name)
        points.each_with_index.each_with_object([]) do |(point, index), issues|
          distance_from_plane = dot(normal, subtract(point, origin)).abs
          if distance_from_plane > POSITION_TOLERANCE_M
            issues << "#{name}[#{index}] lies off the declared surface plane"
          end
        end
      end
      private_class_method :plane_issues

      def polygon_normal_and_area(points)
        return [nil, 0.0] if points.length < 3

        sum = [0.0, 0.0, 0.0]
        points.each_with_index do |point, index|
          following = points[(index + 1) % points.length]
          sum[0] += point[1] * following[2] - point[2] * following[1]
          sum[1] += point[2] * following[0] - point[0] * following[2]
          sum[2] += point[0] * following[1] - point[1] * following[0]
        end
        length = vector_length(sum)
        return [nil, 0.0] if length <= POSITION_TOLERANCE_M**2

        [sum.map { |value| value / length }, length / 2.0]
      end
      private_class_method :polygon_normal_and_area

      def self_intersecting?(loop)
        normal = polygon_normal(loop)
        return false if normal.nil?

        axis = dominant_axis(normal)
        points = loop.map { |point| project(point, axis) }
        points.length.times.any? do |first_index|
          first_next = (first_index + 1) % points.length
          points.length.times.any? do |second_index|
            second_next = (second_index + 1) % points.length
            next false if first_index == second_index || first_next == second_index || second_next == first_index

            segments_intersect_2d?(
              points[first_index], points[first_next],
              points[second_index], points[second_next]
            )
          end
        end
      end
      private_class_method :self_intersecting?

      def segments_intersect_2d?(a, b, c, d)
        o1 = orientation_2d(a, b, c)
        o2 = orientation_2d(a, b, d)
        o3 = orientation_2d(c, d, a)
        o4 = orientation_2d(c, d, b)
        return true if o1 * o2 < 0.0 && o3 * o4 < 0.0

        (o1.abs <= POSITION_TOLERANCE_M && point_on_segment_2d?(c, a, b)) ||
          (o2.abs <= POSITION_TOLERANCE_M && point_on_segment_2d?(d, a, b)) ||
          (o3.abs <= POSITION_TOLERANCE_M && point_on_segment_2d?(a, c, d)) ||
          (o4.abs <= POSITION_TOLERANCE_M && point_on_segment_2d?(b, c, d))
      end
      private_class_method :segments_intersect_2d?

      def orientation_2d(a, b, c)
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
      end
      private_class_method :orientation_2d

      def point_on_segment_2d?(point, start_point, end_point)
        return false if orientation_2d(start_point, end_point, point).abs > POSITION_TOLERANCE_M

        point[0] >= [start_point[0], end_point[0]].min - POSITION_TOLERANCE_M &&
          point[0] <= [start_point[0], end_point[0]].max + POSITION_TOLERANCE_M &&
          point[1] >= [start_point[1], end_point[1]].min - POSITION_TOLERANCE_M &&
          point[1] <= [start_point[1], end_point[1]].max + POSITION_TOLERANCE_M
      end
      private_class_method :point_on_segment_2d?

      def point_in_polygon?(point, polygon)
        inside = false
        previous = polygon.length - 1
        polygon.each_index do |index|
          current = polygon[index]
          prior = polygon[previous]
          crosses = (current[1] > point[1]) != (prior[1] > point[1])
          if crosses
            x_at_y = (prior[0] - current[0]) * (point[1] - current[1]) /
                     (prior[1] - current[1]).to_f + current[0]
            inside = !inside if point[0] < x_at_y
          end
          previous = index
        end
        inside
      end
      private_class_method :point_in_polygon?

      def dominant_axis(normal)
        normal.each_index.max_by { |index| normal[index].abs }
      end
      private_class_method :dominant_axis

      def project(point, axis)
        point.each_with_index.reject { |_value, index| index == axis }.map(&:first)
      end
      private_class_method :project

      def point_key(point)
        point.map { |value| (value.to_f / POSITION_TOLERANCE_M).round }.join(',')
      end
      private_class_method :point_key

      def distance(left, right)
        vector_length(subtract(left, right))
      end
      private_class_method :distance

      def subtract(left, right)
        3.times.map { |axis| left[axis].to_f - right[axis].to_f }
      end
      private_class_method :subtract

      def dot(left, right)
        3.times.inject(0.0) { |sum, axis| sum + left[axis].to_f * right[axis].to_f }
      end
      private_class_method :dot

      def vector_length(vector)
        Math.sqrt(vector.inject(0.0) { |sum, value| sum + value.to_f**2 })
      end
      private_class_method :vector_length
    end
  end
end
