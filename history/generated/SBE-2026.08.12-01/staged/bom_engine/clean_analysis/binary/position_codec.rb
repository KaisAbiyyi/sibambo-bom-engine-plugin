# frozen_string_literal: true

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    module Binary
      module PositionCodec
        INT32_MIN = -2_147_483_648
        INT32_MAX = 2_147_483_647
        DEFAULT_SCALE = 1.0e-6

        module_function

        def encode(points, tolerance: DEFAULT_SCALE)
          candidates = candidate_values(points, tolerance)
          chosen = if candidates.fetch(:int32_relative).fetch(:valid) &&
                      candidates.dig(:int32_relative, :metrics, :max_error) <= tolerance
                     :int32_relative
                   elsif candidates.dig(:float32_relative, :metrics, :max_error) <= tolerance
                     :float32_relative
                   else
                     :float64
                   end
          value = candidates.fetch(chosen)
          {
            component_type: value.fetch(:component_type),
            values: value.fetch(:values).freeze,
            origin: value[:origin]&.freeze,
            scale: value[:scale],
            count: Array(points).length,
            metrics: value.fetch(:metrics).freeze,
            benchmark: candidates.each_with_object({}) do |(name, item), result|
              result[name] = item.fetch(:metrics).dup.freeze
            end.freeze
          }.freeze
        end

        def benchmark(points, tolerance: DEFAULT_SCALE)
          candidate_values(points, tolerance).each_with_object({}) do |(name, item), result|
            result[name] = item.fetch(:metrics).dup
          end
        end

        def decode(encoded)
          values = encoded.fetch(:values)
          case encoded.fetch(:component_type)
          when 'int32'
            origin = encoded.fetch(:origin)
            scale = encoded.fetch(:scale)
            values.each_slice(3).map do |triple|
              3.times.map { |axis| origin.fetch(axis) + triple.fetch(axis) * scale }
            end
          when 'float32'
            origin = encoded.fetch(:origin)
            values.each_slice(3).map do |triple|
              3.times.map { |axis| origin.fetch(axis) + triple.fetch(axis) }
            end
          when 'float64'
            values.each_slice(3).map(&:dup)
          else
            raise ArgumentError, "unsupported position component type: #{encoded.fetch(:component_type)}"
          end
        end

        def candidate_values(points, tolerance)
          source = Array(points).map { |point| Array(point).map(&:to_f) }
          return empty_candidates if source.empty?

          origin = 3.times.map { |axis| source.map { |point| point.fetch(axis) }.min }
          relative = source.flat_map do |point|
            3.times.map { |axis| point.fetch(axis) - origin.fetch(axis) }
          end
          float32_values = relative.pack('e*').unpack('e*')
          float32_roundtrip = float32_values.each_slice(3).map do |triple|
            3.times.map { |axis| origin.fetch(axis) + triple.fetch(axis) }
          end
          scale = [tolerance.to_f, DEFAULT_SCALE].min
          quantized = relative.map { |value| (value / scale).round }
          int32_valid = quantized.all? { |value| value.between?(INT32_MIN, INT32_MAX) }
          int32_roundtrip = if int32_valid
                              quantized.each_slice(3).map do |triple|
                                3.times.map { |axis| origin.fetch(axis) + triple.fetch(axis) * scale }
                              end
                            else
                              []
                            end
          {
            float64: {
              component_type: 'float64', values: source.flatten, origin: nil, scale: nil,
              valid: true, metrics: error_metrics(source, source)
            },
            float32_relative: {
              component_type: 'float32', values: float32_values, origin: origin, scale: nil,
              valid: true, metrics: error_metrics(source, float32_roundtrip)
            },
            int32_relative: {
              component_type: 'int32', values: quantized, origin: origin, scale: scale,
              valid: int32_valid,
              metrics: int32_valid ? error_metrics(source, int32_roundtrip) : infinite_metrics
            }
          }
        end
        private_class_method :candidate_values

        def error_metrics(source, decoded)
          errors = source.flatten.zip(decoded.flatten).map { |left, right| (left - right).abs }.sort
          return { max_error: 0.0, p95_error: 0.0, rms_error: 0.0 } if errors.empty?

          p95_index = ((errors.length - 1) * 0.95).ceil
          {
            max_error: errors.last,
            p95_error: errors.fetch(p95_index),
            rms_error: Math.sqrt(errors.inject(0.0) { |sum, value| sum + value * value } / errors.length)
          }
        end
        private_class_method :error_metrics

        def infinite_metrics
          { max_error: Float::INFINITY, p95_error: Float::INFINITY, rms_error: Float::INFINITY }
        end
        private_class_method :infinite_metrics

        def empty_candidates
          metrics = { max_error: 0.0, p95_error: 0.0, rms_error: 0.0 }
          {
            float64: { component_type: 'float64', values: [], origin: nil, scale: nil, valid: true, metrics: metrics },
            float32_relative: { component_type: 'float32', values: [], origin: [0.0, 0.0, 0.0], scale: nil, valid: true, metrics: metrics },
            int32_relative: { component_type: 'int32', values: [], origin: [0.0, 0.0, 0.0], scale: DEFAULT_SCALE, valid: true, metrics: metrics }
          }
        end
        private_class_method :empty_candidates
      end
    end
  end
end

end # SibamboHistory
