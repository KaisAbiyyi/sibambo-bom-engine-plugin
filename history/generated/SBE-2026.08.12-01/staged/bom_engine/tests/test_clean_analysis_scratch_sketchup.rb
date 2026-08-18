# frozen_string_literal: true

# Automated SketchUp-host acceptance harness. Set these before launching
# SketchUp with the scratch model:
#   BOM_ENGINE_CLEAN_PLUGIN_ROOT
#   BOM_ENGINE_CLEAN_SCRATCH_MODEL
#   BOM_ENGINE_CLEAN_SCRATCH_OUTPUT
#   BOM_ENGINE_CLEAN_SCRATCH_MARKER

require 'json'

plugin_root = ENV.fetch('BOM_ENGINE_CLEAN_PLUGIN_ROOT')
require File.join(plugin_root, 'bom_engine_clean', 'clean_analysis')

module SibamboHistory
  module V20260812_01
  module Tests
    module CleanAnalysisScratchSketchupTest
      module_function

      def run
        model_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_SCRATCH_MODEL'))
        output_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_SCRATCH_OUTPUT'))
        marker_path = File.expand_path(ENV.fetch('BOM_ENGINE_CLEAN_SCRATCH_MARKER'))
        model = Sketchup.active_model
        unless File.expand_path(model.path.to_s).casecmp?(model_path)
          raise "wrong active model: #{model.path.inspect}"
        end

        result = SibamboHistory::V20260812_01::CleanAnalysis::SketchupExtension.export_model(
          model,
          output_path: output_path
        )
        payload = result.fetch(:document)
        sree = payload.fetch('excluded_objects').find do |item|
          item.fetch('name').to_s.casecmp?('Sree')
        end
        raise 'Sree was not excluded' if sree.nil?
        unless payload.dig('diagnostics', 'counts', 'raw_triangle_indices_serialized') == 0
          raise 'clean JSON serialized triangle indices'
        end
        validate_surface_contract!(payload)
        validate_clean_payload!(payload, sree)

        rows = payload.fetch('surfaces').sort_by { |surface| surface.fetch('id') }.map do |surface|
          [
            surface.fetch('type'),
            surface.fetch('outer').length,
            surface.fetch('area_m2'),
            surface.fetch('normal'),
            surface.fetch('source_count')
          ]
        end
        puts 'type | vertex_count | area_m2 | normal | source_count'
        rows.each { |row| puts row.map(&:inspect).join(' | ') }

        write_marker(
          marker_path,
          status: 'passed',
          output_path: result.fetch(:path),
          bytes: result.fetch(:bytes),
          counts: result.fetch(:counts),
          surface_types: payload.fetch('surfaces').group_by { |surface| surface.fetch('type') }
                                .transform_values(&:length),
          diagnostic_table: {
            header: 'type | vertex_count | area_m2 | normal | source_count',
            rows: rows
          },
          invalid_surface_count: 0,
          unresolved_fragment_count: payload.dig('diagnostics', 'counts', 'unresolved_fragment_count'),
          area_m2: payload.dig('diagnostics', 'area_m2'),
          valid_wall_excerpt: payload.fetch('surfaces').find { |surface| surface.fetch('type') == 'wall' },
          sree: sree
        )
      rescue StandardError => error
        marker_path ||= ENV['BOM_ENGINE_CLEAN_SCRATCH_MARKER']
        write_marker(
          marker_path,
          status: 'failed',
          error_class: error.class.name,
          error: error.message,
          backtrace: error.backtrace.first(12)
        ) if marker_path
      ensure
        UI.start_timer(0.5, false) { Sketchup.quit } if Sketchup.respond_to?(:quit)
      end

      def write_marker(path, values)
        File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(values) + "\n") }
      end
      private_class_method :write_marker

      def validate_surface_contract!(payload)
        payload.fetch('surfaces').each do |surface|
          issues = SibamboHistory::V20260812_01::CleanAnalysis::SurfaceValidator.validate(surface)
          raise "invalid surface #{surface.fetch('id')}: #{issues.join('; ')}" unless issues.empty?

          outer = surface.fetch('outer')
          raise "surface #{surface.fetch('id')} has fewer than three vertices" if outer.length < 3
          distinct = outer.map { |point| point.map { |value| value.round(6) } }.uniq
          raise "surface #{surface.fetch('id')} has fewer than three distinct vertices" if distinct.length < 3
          outer.each_with_index do |point, index|
            following = outer[(index + 1) % outer.length]
            raise "surface #{surface.fetch('id')} has a zero-length edge" if distance(point, following) <= 1.0e-6
          end

          normal = surface.fetch('normal')
          raise "surface #{surface.fetch('id')} normal is not finite" unless normal.all? { |value| finite?(value) }
          raise "surface #{surface.fetch('id')} normal is not normalized" if (length(normal) - 1.0).abs > 1.0e-6
          origin = outer.first
          (outer + surface.fetch('holes').flatten(1)).each do |point|
            raise "surface #{surface.fetch('id')} contains a non-finite point" unless point.all? { |value| finite?(value) }
            if dot(normal, subtract(point, origin)).abs > 1.0e-6
              raise "surface #{surface.fetch('id')} is not coplanar"
            end
          end

          outer_normal, outer_area = normal_and_area(outer)
          raise "surface #{surface.fetch('id')} has non-positive area" if outer_area <= 1.0e-12
          raise "surface #{surface.fetch('id')} normal/winding mismatch" if dot(normal, outer_normal) < 1.0 - 1.0e-6
          hole_area = surface.fetch('holes').inject(0.0) { |sum, hole| sum + normal_and_area(hole).last }
          calculated_area = outer_area - hole_area
          tolerance = [1.0e-6, calculated_area * 1.0e-6].max
          if (surface.fetch('area_m2') - calculated_area).abs > tolerance
            raise "surface #{surface.fetch('id')} area mismatch"
          end
        end
      end
      private_class_method :validate_surface_contract!

      def validate_clean_payload!(payload, sree)
        architectural_payload = payload.reject { |key, _value| key == 'excluded_objects' }
        if JSON.generate(architectural_payload).match?(/sree/i)
          raise 'Sree data leaked into retained clean geometry'
        end

        forbidden_identity_keys = %w[source_uuid semantic_uuid definition_uuid primitive_key persistent_id entity_id]
        found = deep_key(payload, forbidden_identity_keys)
        raise "clean payload leaked source identity key #{found}" if found
        raise 'clean payload includes triangle arrays' if deep_key(payload, %w[triangles triangle_indices faces positions loops])

        signatures = payload.fetch('surfaces').map do |surface|
          surface.fetch('outer').map { |point| point.map { |value| value.round(6) }.join(',') }.sort.join('|')
        end
        raise 'clean payload contains duplicate surfaces' unless signatures.uniq.length == signatures.length

        counts = payload.fetch('diagnostics').fetch('counts')
        accounted_fragments = payload.fetch('surfaces').inject(0) { |sum, surface| sum + surface.fetch('source_count') } +
                              counts.fetch('unresolved_fragment_count')
        unless counts.fetch('source_polygon_fragments') == accounted_fragments
          raise 'source fragment accounting mismatch'
        end
        areas = payload.fetch('diagnostics').fetch('area_m2')
        unless (areas.fetch('source') - areas.fetch('resolved') - areas.fetch('unresolved')).abs <= 1.0e-6
          raise 'source area accounting mismatch'
        end
        payload.fetch('components').each do |component|
          geometry = component['geometry']
          unless geometry && geometry['status'] == 'omitted' && geometry['reason'] && geometry['source_count'].is_a?(Integer)
            raise "component #{component.fetch('id')} silently omits nested geometry"
          end
        end
        raise 'Sree exclusion record is not analysis-irrelevant' unless sree.fetch('reason') == 'analysis_irrelevant'
      end
      private_class_method :validate_clean_payload!

      def deep_key(value, keys)
        case value
        when Hash
          value.each do |key, child|
            return key if keys.include?(key.to_s)
            found = deep_key(child, keys)
            return found if found
          end
        when Array
          value.each do |child|
            found = deep_key(child, keys)
            return found if found
          end
        end
        nil
      end
      private_class_method :deep_key

      def normal_and_area(points)
        sum = [0.0, 0.0, 0.0]
        points.each_with_index do |point, index|
          following = points[(index + 1) % points.length]
          vector = cross(point, following)
          3.times { |axis| sum[axis] += vector[axis] }
        end
        magnitude = length(sum)
        [sum.map { |value| value / magnitude }, magnitude / 2.0]
      end
      private_class_method :normal_and_area

      def distance(left, right)
        length(subtract(left, right))
      end
      private_class_method :distance

      def subtract(left, right)
        3.times.map { |axis| left[axis] - right[axis] }
      end
      private_class_method :subtract

      def cross(left, right)
        [
          left[1] * right[2] - left[2] * right[1],
          left[2] * right[0] - left[0] * right[2],
          left[0] * right[1] - left[1] * right[0]
        ]
      end
      private_class_method :cross

      def dot(left, right)
        3.times.inject(0.0) { |sum, axis| sum + left[axis] * right[axis] }
      end
      private_class_method :dot

      def length(vector)
        Math.sqrt(vector.inject(0.0) { |sum, value| sum + value**2 })
      end
      private_class_method :length

      def finite?(value)
        value.is_a?(Numeric) && value.to_f.finite?
      end
      private_class_method :finite?
    end
  end
end

UI.start_timer(2.0, false) { SibamboHistory::V20260812_01::Tests::CleanAnalysisScratchSketchupTest.run }

end # SibamboHistory
