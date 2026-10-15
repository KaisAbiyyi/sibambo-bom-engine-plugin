# frozen_string_literal: true

module BOMEngine
  module EvolutionCleanPKG
    class SectionWriter
      TYPE_INFO = {
        'float64' => ['E*', 8],
        'uint32' => ['L<*', 4],
        'int32' => ['l<*', 4]
      }.freeze

      attr_reader :padding_bytes

      def initialize
        @bytes = ''.b
        @sections = {}
        @padding_bytes = 0
      end

      def add(name, values, component_type:, components:, count: nil)
        key = name.to_s
        raise ArgumentError, "duplicate binary section: #{key}" if @sections.key?(key)
        directive, width = TYPE_INFO.fetch(component_type.to_s) { raise ArgumentError, "unsupported component type: #{component_type}" }
        components = Integer(components)
        raise ArgumentError, 'section components must be positive' unless components.positive?
        align(width >= 8 ? 8 : 4)
        values = Array(values)
        payload = values.pack(directive)
        descriptor = {
          'byte_offset' => @bytes.bytesize,
          'byte_length' => payload.bytesize,
          'count' => count.nil? ? values.length / components : Integer(count),
          'component_count' => components,
          'component_type' => component_type.to_s
        }
        @bytes << payload
        @sections[key] = descriptor
        descriptor
      end

      def bytes
        @bytes.dup
      end

      def sections
        @sections.transform_values(&:dup)
      end

      private

      def align(boundary)
        padding = (boundary - (@bytes.bytesize % boundary)) % boundary
        return if padding.zero?
        @bytes << ("\0" * padding)
        @padding_bytes += padding
      end
    end
  end
end
