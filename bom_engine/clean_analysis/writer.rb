# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'stringio'

module BOMEngine
  module CleanAnalysis
    module Writer
      FORBIDDEN_GEOMETRY_KEYS = %w[triangles faces positions loops].freeze
      MATERIAL_REFERENCE_KEYS = %w[
        material_id front_material_id back_material_id inherited_material_id
      ].freeze
      MATERIAL_ID_PATTERN = /\Amat-[0-9a-f]{16}\z/.freeze

      module_function

      class ByteCounter
        attr_reader :bytesize

        def initialize
          @bytesize = 0
        end

        def write(value)
          size = value.to_s.bytesize
          @bytesize += size
          size
        end
      end

      def measure(document, progress: nil, pretty_print: false)
        validate_document!(document, progress)
        output = ByteCounter.new
        write_json(output, document, 0, progress, pretty_print)
        output.write("\n") if pretty_print
        output.bytesize
      end

      def generate(document, progress: nil, pretty_print: false)
        validate_document!(document, progress)
        output = StringIO.new
        write_json(output, document, 0, progress, pretty_print)
        output.write("\n") if pretty_print
        output.string
      end

      def write(path, document, progress: nil, pretty_print: false)
        output_path = File.expand_path(path.to_s)
        raise ArgumentError, 'clean analysis output path is required' if path.to_s.strip.empty?

        validate_document!(document, progress)
        FileUtils.mkdir_p(File.dirname(output_path))
        bytes = File.open(output_path, 'wb') do |file|
          write_json(file, document, 0, progress, pretty_print)
          file.write("\n") if pretty_print
          file.pos
        end
        {
          path: output_path,
          bytes: bytes,
          counts: document.fetch('diagnostics').fetch('counts').dup
        }
      end

      def validate_document!(document, progress)
        unless document.is_a?(Hash) && document.dig('format', 'identifier') == Compiler::FORMAT_IDENTIFIER
          raise ArgumentError, 'clean analysis document has the wrong format identifier'
        end

        forbidden = find_forbidden_key(document, progress)
        raise ArgumentError, "redundant geometry key: #{forbidden}" if forbidden

        material_ids = validate_materials!(document.fetch('materials', []), progress)
        validate_material_references!(document, material_ids, progress)

        document.fetch('surfaces', []).each do |surface|
          report_progress(progress)
          SurfaceValidator.validate!(surface)
        end
        document.fetch('definitions', []).each do |definition|
          geometry = definition.fetch('geometry')
          vertices = geometry['vertices']
          validate_vertex_pool!(vertices) unless vertices.nil?
          geometry.fetch('surfaces').each do |surface|
            report_progress(progress)
            candidate = vertices.nil? ? surface : resolve_indexed_surface(surface, vertices)
            if definition.fetch('retention') == 'visual_architectural_detail' &&
               (candidate['normal'].nil? || candidate['area_m2'].nil?)
              candidate = visual_surface_validation_candidate(candidate)
            end
            SurfaceValidator.validate!(candidate)
          end
        end
      end
      private_class_method :validate_document!

      def validate_materials!(materials, progress)
        raise ArgumentError, 'materials must be an array' unless materials.is_a?(Array)

        ids = {}
        materials.each do |material|
          report_progress(progress)
          raise ArgumentError, 'material must be an object' unless material.is_a?(Hash)

          id = material['id']
          unless id.is_a?(String) && MATERIAL_ID_PATTERN.match?(id)
            raise ArgumentError, 'material id must use deterministic mat-<16 lowercase hex> format'
          end
          raise ArgumentError, "duplicate material id: #{id}" if ids.key?(id)

          rgba = material['base_color_rgba']
          unless rgba.is_a?(Array) && rgba.length == 4 && rgba.all? { |value| unit_number?(value) }
            raise ArgumentError, "material #{id} base_color_rgba must contain four finite 0..1 values"
          end
          unless unit_number?(material['opacity'])
            raise ArgumentError, "material #{id} opacity must be a finite 0..1 value"
          end
          unless material['opacity'] == rgba[3]
            raise ArgumentError, "material #{id} opacity must match base_color_rgba alpha"
          end
          unless material['color_space'] == 'srgb'
            raise ArgumentError, "material #{id} color_space must be srgb"
          end
          validate_texture!(material['texture'], id)
          ids[id] = true
        end
        ids
      end
      private_class_method :validate_materials!

      def validate_texture!(texture, material_id)
        return if texture.nil?
        raise ArgumentError, "material #{material_id} texture must be an object or null" unless texture.is_a?(Hash)

        %w[width_m height_m].each do |key|
          next unless texture.key?(key)

          value = texture[key]
          unless value.is_a?(Numeric) && value.finite? && value >= 0.0
            raise ArgumentError, "material #{material_id} texture #{key} must be finite and non-negative"
          end
        end
      end
      private_class_method :validate_texture!

      def validate_material_references!(value, material_ids, progress)
        report_progress(progress)
        case value
        when Hash
          value.each do |key, child|
            if MATERIAL_REFERENCE_KEYS.include?(key.to_s) && !material_ids.key?(child)
              raise ArgumentError, "unknown material reference: #{child.inspect}"
            end
            validate_material_references!(child, material_ids, progress)
          end
        when Array
          value.each { |child| validate_material_references!(child, material_ids, progress) }
        end
      end
      private_class_method :validate_material_references!

      def unit_number?(value)
        value.is_a?(Numeric) && value.finite? && value.between?(0.0, 1.0)
      end
      private_class_method :unit_number?

      def visual_surface_validation_candidate(surface)
        outer = surface.fetch('outer')
        holes = surface.fetch('holes')
        area = SurfaceValidator.polygon_area(outer) - holes.inject(0.0) do |sum, hole|
          sum + SurfaceValidator.polygon_area(hole)
        end
        surface.merge(
          'normal' => SurfaceValidator.polygon_normal(outer),
          'area_m2' => area,
          'source_count' => 1
        )
      end
      private_class_method :visual_surface_validation_candidate

      def validate_vertex_pool!(vertices)
        unless vertices.is_a?(Array) && vertices.all? { |point| SurfaceValidator.valid_point?(point) }
          raise ArgumentError, 'definition vertex pool must contain finite XYZ coordinates'
        end
      end
      private_class_method :validate_vertex_pool!

      def resolve_indexed_surface(surface, vertices)
        surface.merge(
          'outer' => resolve_index_loop(surface.fetch('outer'), vertices),
          'holes' => surface.fetch('holes').map { |loop| resolve_index_loop(loop, vertices) }
        )
      end
      private_class_method :resolve_indexed_surface

      def resolve_index_loop(indices, vertices)
        unless indices.is_a?(Array) && indices.all? { |index| index.is_a?(Integer) && index >= 0 }
          raise ArgumentError, 'definition polygon loops must contain non-negative vertex indices'
        end

        indices.map { |index| vertices.fetch(index) }
      rescue IndexError
        raise ArgumentError, 'definition polygon vertex index is out of range'
      end
      private_class_method :resolve_index_loop

      def find_forbidden_key(value, progress)
        report_progress(progress)
        case value
        when Hash
          value.each do |key, child|
            return key if FORBIDDEN_GEOMETRY_KEYS.include?(key.to_s)

            nested = find_forbidden_key(child, progress)
            return nested if nested
          end
        when Array
          value.each do |child|
            nested = find_forbidden_key(child, progress)
            return nested if nested
          end
        end
        nil
      end
      private_class_method :find_forbidden_key

      def write_json(output, value, depth, progress, pretty_print)
        report_progress(progress)
        case value
        when Hash
          write_object(output, value, depth, progress, pretty_print)
        when Array
          write_array(output, value, depth, progress, pretty_print)
        else
          output.write(JSON.generate(value))
        end
      end
      private_class_method :write_json

      def write_object(output, value, depth, progress, pretty_print)
        return write_compact_object(output, value, depth, progress) unless pretty_print

        output.write("{\n")
        unless value.empty?
          value.each_with_index do |(key, child), index|
            output.write(' ' * (depth + 2))
            output.write(JSON.generate(key.to_s))
            output.write(': ')
            write_json(output, child, depth + 2, progress, true)
            output.write(',') if index + 1 < value.length
            output.write("\n")
          end
        end
        output.write(' ' * depth)
        output.write('}')
      end
      private_class_method :write_object

      def write_array(output, value, depth, progress, pretty_print)
        return write_compact_array(output, value, depth, progress) unless pretty_print

        output.write("[\n")
        if value.empty?
          output.write("\n")
        else
          value.each_with_index do |child, index|
            output.write(' ' * (depth + 2))
            write_json(output, child, depth + 2, progress, true)
            output.write(',') if index + 1 < value.length
            output.write("\n")
          end
        end
        output.write(' ' * depth)
        output.write(']')
      end
      private_class_method :write_array

      def write_compact_object(output, value, depth, progress)
        output.write('{')
        value.each_with_index do |(key, child), index|
          output.write(',') if index.positive?
          output.write(JSON.generate(key.to_s))
          output.write(':')
          write_json(output, child, depth, progress, false)
        end
        output.write('}')
      end
      private_class_method :write_compact_object

      def write_compact_array(output, value, depth, progress)
        output.write('[')
        value.each_with_index do |child, index|
          output.write(',') if index.positive?
          write_json(output, child, depth, progress, false)
        end
        output.write(']')
      end
      private_class_method :write_compact_array

      def report_progress(progress)
        progress.call('Writing clean JSON') if progress
      end
      private_class_method :report_progress
    end
  end
end
