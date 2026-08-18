# frozen_string_literal: true

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    module Binary
      class SectionWriter
        TYPE_INFO = {
          'float32' => ['e*', 4],
          'float64' => ['E*', 8],
          'uint16' => ['S<*', 2],
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

          directive, width = TYPE_INFO.fetch(component_type.to_s) do
            raise ArgumentError, "unsupported component type: #{component_type}"
          end
          component_count = Integer(components)
          raise ArgumentError, 'section components must be positive' unless component_count.positive?

          align(width >= 8 ? 8 : 4)
          payload = Array(values).pack(directive)
          descriptor = {
            'byte_offset' => @bytes.bytesize,
            'byte_length' => payload.bytesize,
            'count' => count.nil? ? Array(values).length / component_count : Integer(count),
            'component_count' => component_count,
            'component_type' => component_type.to_s
          }
          @bytes << payload
          @sections[key] = descriptor.freeze
          descriptor
        end

        def bytes
          @bytes.dup
        end

        def sections
          @sections.each_with_object({}) { |(key, value), result| result[key] = value.dup }
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
end

end # SibamboHistory
