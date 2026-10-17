# frozen_string_literal: true

module BOMEngine
  module EvolutionCleanPKG
    class SectionWriter
      VALUE_CHUNK = 4096
      TYPE_INFO = {
        'float64' => ['E*', 8],
        'uint32' => ['L<*', 4],
        'int32' => ['l<*', 4]
      }.freeze

      attr_reader :padding_bytes, :bytesize

      def initialize(io: nil)
        @io = io
        @bytes = ''.b unless io
        @sections = {}
        @padding_bytes = 0
        @bytesize = 0
      end

      def add(name, values, component_type:, components:, count: nil)
        key = name.to_s
        raise ArgumentError, "duplicate binary section: #{key}" if @sections.key?(key)
        directive, width = TYPE_INFO.fetch(component_type.to_s) { raise ArgumentError, "unsupported component type: #{component_type}" }
        components = Integer(components)
        raise ArgumentError, 'section components must be positive' unless components.positive?
        align(width >= 8 ? 8 : 4)
        start = @bytesize
        scalar_count = 0
        values.each_slice(VALUE_CHUNK) do |chunk|
          scalar_count += chunk.length
          append(chunk.pack(directive))
        end
        raise ArgumentError, "section #{key} value count is not divisible by #{components}" unless (scalar_count % components).zero?
        derived_count = scalar_count / components
        if count && Integer(count) != derived_count
          raise ArgumentError, "section #{key} count mismatch: #{count} != #{derived_count}"
        end
        descriptor = {
          'byte_offset' => start,
          'byte_length' => @bytesize - start,
          'count' => count.nil? ? derived_count : Integer(count),
          'component_count' => components,
          'component_type' => component_type.to_s
        }
        @sections[key] = descriptor
        descriptor
      end

      def bytes
        raise IOError, 'section writer is file-backed' if @io
        @bytes.dup
      end

      def sections
        @sections.transform_values(&:dup)
      end

      private

      def align(boundary)
        padding = (boundary - (@bytesize % boundary)) % boundary
        return if padding.zero?
        append("\0" * padding)
        @padding_bytes += padding
      end

      def append(payload)
        bytes = payload.to_s.b
        @io ? @io.write(bytes) : @bytes << bytes
        @bytesize += bytes.bytesize
      end
    end
  end
end
