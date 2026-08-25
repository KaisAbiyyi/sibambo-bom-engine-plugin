# Adaptive per-mesh position quantization with a measured error budget.

module SibamboHistory
  module V20260825_02
  module Quantizer
    MAX_ERROR_M = 0.001
    UINT16_MAX = 65_535
    UINT32_MAX = 4_294_967_295

    def self.quantize_positions(positions, max_error_m: MAX_ERROR_M, progress: nil)
      raise 'Position buffer must contain XYZ triples.' unless (positions.length % 3).zero?

      work_count = 0
      checkpoint = lambda do |stage|
        work_count += 1
        progress.call(stage: stage, processed: work_count) if progress && (work_count % 2048).zero?
      end
      minimum = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
      maximum = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
      positions.each_with_index do |raw_value, index|
        checkpoint.call('Measuring mesh bounds')
        axis = index % 3
        value = raw_value.to_f
        minimum[axis] = value if value < minimum[axis]
        maximum[axis] = value if value > maximum[axis]
      end
      if positions.empty?
        minimum = [0.0, 0.0, 0.0]
        maximum = [0.0, 0.0, 0.0]
      end
      spans = 3.times.map { |axis| maximum[axis] - minimum[axis] }
      uint16_scale = spans.map { |span| span.zero? ? 0.0 : span / UINT16_MAX }
      uint16_bound = Math.sqrt(uint16_scale.sum { |scale| (scale * 0.5)**2 })
      component_type = uint16_bound <= max_error_m ? 'uint16' : 'uint32'
      maximum_integer = component_type == 'uint16' ? UINT16_MAX : UINT32_MAX
      scale = spans.map { |span| span.zero? ? 0.0 : span / maximum_integer }
      values = Array.new(positions.length)
      positions.each_with_index do |raw_value, index|
        checkpoint.call('Quantizing mesh positions')
        axis = index % 3
        values[index] = scale[axis].zero? ? 0 : ((raw_value.to_f - minimum[axis]) / scale[axis]).round
      end

      result = {
        component_type: component_type,
        values: values,
        minimum_m: minimum.map { |value| value.round(12) },
        maximum_m: maximum.map { |value| value.round(12) },
        scale_m: scale.map { |value| value.round(15) },
        measured_max_error_m: 0.0,
        error_budget_m: max_error_m
      }
      encoded_minimum = result[:minimum_m]
      encoded_scale = result[:scale_m]
      measured = 0.0
      positions.each_slice(3).with_index do |point, point_index|
        checkpoint.call('Checking quantization error')
        offset = point_index * 3
        error_squared = 0.0
        3.times do |axis|
          decoded = encoded_minimum[axis].to_f + values[offset + axis].to_f * encoded_scale[axis].to_f
          delta = point[axis].to_f - decoded
          error_squared += delta * delta
        end
        error = Math.sqrt(error_squared)
        measured = error if error > measured
      end
      result[:measured_max_error_m] = measured.round(12)
      raise "Quantization error #{measured}m exceeds #{max_error_m}m." if measured > max_error_m + 1.0e-12

      result
    end

    def self.dequantize_positions(quantized)
      minimum = quantized[:minimum_m]
      scale = quantized[:scale_m]
      quantized[:values].each_slice(3).flat_map do |point|
        3.times.map { |axis| minimum[axis].to_f + point[axis].to_f * scale[axis].to_f }
      end
    end

    def self.pack_values(quantized)
      quantized[:values].pack(quantized[:component_type] == 'uint16' ? 'S<*' : 'V*')
    end
  end
end

end # SibamboHistory
