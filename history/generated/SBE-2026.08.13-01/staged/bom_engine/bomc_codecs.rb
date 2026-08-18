# Error-gated structural codecs used by BOMC.

require 'zlib'
require_relative 'bomc_format'

module SibamboHistory
  module V20260813_01
  module BOMC
    module CodecMath
      module_function

      def error_summary(errors)
        values = Array(errors).map(&:to_f).sort
        return { max: 0.0, p95: 0.0, rms: 0.0 } if values.empty?

        p95_index = [(values.length * 0.95).ceil - 1, 0].max
        rms = Math.sqrt(values.map { |value| value * value }.inject(0.0, :+) / values.length)
        { max: values[-1], p95: values[p95_index], rms: rms }
      end

      def vector_length(vector)
        Math.sqrt(vector.map { |value| value.to_f * value.to_f }.inject(0.0, :+))
      end

      def normalize(vector)
        length = vector_length(vector)
        return nil if length.zero? || !length.finite?

        vector.map { |value| value.to_f / length }
      end

      def dot(left, right)
        left.each_with_index.map { |value, index| value.to_f * right[index].to_f }.inject(0.0, :+)
      end

      def cross(left, right)
        [
          left[1] * right[2] - left[2] * right[1],
          left[2] * right[0] - left[0] * right[2],
          left[0] * right[1] - left[1] * right[0]
        ]
      end

      def finite_values!(values, label)
        Array(values).each do |value|
          raise ArgumentError, "#{label} contains a non-finite value." unless value.to_f.finite?
        end
      end

      def compressed_size(bytes)
        Zlib::Deflate.deflate(bytes, Zlib::BEST_COMPRESSION).bytesize
      end
    end

    module PositionCodec
      FLOAT64_ABSOLUTE = 1
      FLOAT32_LOCAL = 2
      INT32_QUANTIZED = 3
      INT16_QUANTIZED = 4
      DELTA_VARINT = 5
      MAX_ERROR_M = 0.001
      AREA_RELATIVE_ERROR = 0.001
      AREA_ABSOLUTE_ERROR_M2 = 1.0e-6

      module_function

      def encode(values, loops: [], max_error_m: MAX_ERROR_M)
        source = Array(values).map(&:to_f)
        raise ArgumentError, 'Position buffer must contain XYZ triples.' unless (source.length % 3).zero?
        CodecMath.finite_values!(source, 'Position buffer')

        minimum, maximum = bounds(source, 3)
        center = 3.times.map { |axis| (minimum[axis] + maximum[axis]) * 0.5 }

        candidates = []
        candidates << candidate(
          'float64_absolute', FLOAT64_ABSOLUTE, source.pack('E*'), [0.0, 0.0, 0.0], [0.0, 0.0, 0.0],
          source, source, loops, max_error_m, 0
        )

        local_values = source.each_with_index.map { |value, index| value - minimum[index % 3] }
        float32_bytes = local_values.pack('e*')
        float32_decoded = float32_bytes.unpack('e*').each_with_index.map { |value, index| value + minimum[index % 3] }
        candidates << candidate(
          'float32_local', FLOAT32_LOCAL, float32_bytes, minimum, [0.0, 0.0, 0.0],
          source, float32_decoded, loops, max_error_m, 1
        )

        int32 = quantized_candidate(source, center, 2_147_483_647, 'l<*')
        candidates << candidate(
          'int32_quantized', INT32_QUANTIZED, int32[:bytes], center, int32[:scale],
          source, int32[:decoded], loops, max_error_m, 3
        ).merge(integers: int32[:integers], integer_bits: 32)

        int16 = quantized_candidate(source, center, 32_767, 's<*')
        candidates << candidate(
          'int16_quantized', INT16_QUANTIZED, int16[:bytes], center, int16[:scale],
          source, int16[:decoded], loops, max_error_m, 2
        ).merge(integers: int16[:integers], integer_bits: 16)

        delta_source = candidates[-1][:passed] ? int16 : int32
        previous = 0
        delta_bytes = delta_source[:integers].map do |integer|
          delta = integer - previous
          previous = integer
          Binary.write_zigzag(delta)
        end.join.b
        delta = candidate(
          'delta_varint', DELTA_VARINT, delta_bytes, center, delta_source[:scale],
          source, delta_source[:decoded], loops, max_error_m, 4
        )
        delta[:integer_bits] = delta_source.equal?(int16) ? 16 : 32
        candidates << delta

        selected = select_candidate(candidates)
        selected.merge(candidates: candidate_reports(candidates), count: source.length / 3)
      end

      def decode(block)
        count = Integer(block[:count]) * 3
        origin = Array(block[:origin]).map(&:to_f)
        scale = Array(block[:scale]).map(&:to_f)
        values = case block[:codec]
                 when FLOAT64_ABSOLUTE
                   block[:bytes].unpack('E*')
                 when FLOAT32_LOCAL
                   block[:bytes].unpack('e*').each_with_index.map { |value, index| value + origin[index % 3] }
                 when INT32_QUANTIZED
                   dequantize(block[:bytes].unpack('l<*'), origin, scale)
                 when INT16_QUANTIZED
                   dequantize(block[:bytes].unpack('s<*'), origin, scale)
                 when DELTA_VARINT
                   integers = []
                   cursor = 0
                   previous = 0
                   count.times do
                     delta, cursor = Binary.read_zigzag(block[:bytes], cursor)
                     previous += delta
                     integers << previous
                   end
                   raise 'BOMC invalid: trailing position delta bytes.' unless cursor == block[:bytes].bytesize
                   dequantize(integers, origin, scale)
                 else
                   raise "BOMC invalid: unsupported position codec #{block[:codec]}."
                 end
        raise 'BOMC invalid: position value count mismatch.' unless values.length == count

        values
      end

      def candidate(name, codec, bytes, origin, scale, source, decoded, loops, max_error_m, complexity)
        point_errors = source.each_slice(3).with_index.map do |point, point_index|
          offset = point_index * 3
          Math.sqrt(3.times.map { |axis| (point[axis] - decoded[offset + axis])**2 }.inject(0.0, :+))
        end
        errors = CodecMath.error_summary(point_errors)
        area_error, area_passed = area_gate(source, decoded, loops)
        {
          name: name,
          codec: codec,
          bytes: bytes,
          origin: origin,
          scale: scale,
          errors: errors,
          area_max_error_m2: area_error,
          passed: errors[:max] <= max_error_m + 1.0e-12 && area_passed,
          raw_bytes: bytes.bytesize,
          deflate_bytes: CodecMath.compressed_size(bytes),
          complexity: complexity
        }
      end
      private_class_method :candidate

      def quantized_candidate(source, center, maximum_integer, pack_directive)
        minimum, maximum = bounds(source, 3)
        scale = 3.times.map do |axis|
          span = maximum[axis] - minimum[axis]
          span.zero? ? 0.0 : span / (maximum_integer * 2.0)
        end
        integers = source.each_with_index.map do |value, index|
          axis = index % 3
          scale[axis].zero? ? 0 : ((value - center[axis]) / scale[axis]).round
        end
        decoded = dequantize(integers, center, scale)
        { integers: integers, decoded: decoded, scale: scale, bytes: integers.pack(pack_directive) }
      end
      private_class_method :quantized_candidate

      def dequantize(integers, origin, scale)
        integers.each_with_index.map { |integer, index| origin[index % 3] + integer * scale[index % 3] }
      end
      private_class_method :dequantize

      def bounds(values, dimensions)
        minimum = Array.new(dimensions, Float::INFINITY)
        maximum = Array.new(dimensions, -Float::INFINITY)
        values.each_with_index do |value, index|
          axis = index % dimensions
          minimum[axis] = value if value < minimum[axis]
          maximum[axis] = value if value > maximum[axis]
        end
        if values.empty?
          minimum = Array.new(dimensions, 0.0)
          maximum = Array.new(dimensions, 0.0)
        end
        [minimum, maximum]
      end
      private_class_method :bounds

      def area_gate(source, decoded, loops)
        maximum_error = 0.0
        passed = true
        Array(loops).each do |loop_indices|
          next if Array(loop_indices).length < 3

          source_vector = newell_vector(source, loop_indices)
          decoded_vector = newell_vector(decoded, loop_indices)
          source_area = CodecMath.vector_length(source_vector) * 0.5
          decoded_area = CodecMath.vector_length(decoded_vector) * 0.5
          error = (source_area - decoded_area).abs
          maximum_error = error if error > maximum_error
          tolerance = [AREA_ABSOLUTE_ERROR_M2, source_area * AREA_RELATIVE_ERROR].max
          passed = false if error > tolerance + 1.0e-12
          passed = false if source_area > AREA_ABSOLUTE_ERROR_M2 && CodecMath.dot(source_vector, decoded_vector) <= 0.0
        end
        [maximum_error, passed]
      end
      private_class_method :area_gate

      def newell_vector(values, indices)
        vector = [0.0, 0.0, 0.0]
        indices.each_with_index do |index, cursor|
          following = indices[(cursor + 1) % indices.length]
          current_offset = index.to_i * 3
          next_offset = following.to_i * 3
          current = values[current_offset, 3]
          after = values[next_offset, 3]
          raise ArgumentError, 'Position loop index is outside the vertex buffer.' if current.nil? || after.nil? || current.length < 3 || after.length < 3

          vector[0] += (current[1] - after[1]) * (current[2] + after[2])
          vector[1] += (current[2] - after[2]) * (current[0] + after[0])
          vector[2] += (current[0] - after[0]) * (current[1] + after[1])
        end
        vector
      end
      private_class_method :newell_vector

      def select_candidate(candidates)
        passing = candidates.select { |item| item[:passed] }
        raise 'No position codec passed the error gate.' if passing.empty?

        selected = passing.min_by { |item| [item[:deflate_bytes], item[:complexity]] }
        selected.reject { |key, _value| [:name, :passed, :raw_bytes, :deflate_bytes, :complexity, :integers, :integer_bits].include?(key) }
      end
      private_class_method :select_candidate

      def candidate_reports(candidates)
        candidates.map do |item|
          item.reject { |key, _value| [:bytes, :origin, :scale, :integers, :complexity].include?(key) }
        end
      end
      private_class_method :candidate_reports
    end

    module NormalCodec
      FLOAT32 = 1
      OCT16 = 2
      MAX_ANGULAR_ERROR_DEG = 0.1

      module_function

      def encode(values)
        source = Array(values).map(&:to_f)
        raise ArgumentError, 'Normal buffer must contain XYZ triples.' unless (source.length % 3).zero?
        CodecMath.finite_values!(source, 'Normal buffer')

        float_bytes = source.pack('e*')
        float_decoded = float_bytes.unpack('e*')
        float_errors = angular_errors(source, float_decoded)

        oct_values = []
        source.each_slice(3) do |normal|
          unit = CodecMath.normalize(normal)
          if unit.nil?
            # -32768 is outside the valid octahedral quantization range
            # (-32767..32767), so this pair losslessly represents a zero normal.
            oct_values.concat([-32_768, -32_768])
          else
            x, y = oct_project(unit)
            oct_values << (x * 32_767.0).round
            oct_values << (y * 32_767.0).round
          end
        end
        oct_bytes = oct_values.pack('s<*')
        oct_block = { codec: OCT16, bytes: oct_bytes, count: source.length / 3 }
        oct_decoded = decode(oct_block)
        oct_errors = angular_errors(source, oct_decoded)
        oct_summary = CodecMath.error_summary(oct_errors)
        float_summary = CodecMath.error_summary(float_errors)
        use_oct = oct_summary[:max] <= MAX_ANGULAR_ERROR_DEG + 1.0e-12
        selected_codec = use_oct ? OCT16 : FLOAT32
        selected_bytes = use_oct ? oct_bytes : float_bytes
        selected_errors = use_oct ? oct_summary : float_summary

        {
          codec: selected_codec,
          bytes: selected_bytes,
          count: source.length / 3,
          errors: selected_errors,
          candidates: [
            { name: 'float32x3', raw_bytes: float_bytes.bytesize, deflate_bytes: CodecMath.compressed_size(float_bytes), errors: float_summary, passed: float_summary[:max] <= MAX_ANGULAR_ERROR_DEG },
            { name: 'oct16x2', raw_bytes: oct_bytes.bytesize, deflate_bytes: CodecMath.compressed_size(oct_bytes), errors: oct_summary, passed: use_oct }
          ]
        }
      end

      def decode(block)
        count = Integer(block[:count])
        case block[:codec]
        when FLOAT32
          values = block[:bytes].unpack('e*')
          raise 'BOMC invalid: normal float count mismatch.' unless values.length == count * 3
          values
        when OCT16
          integers = block[:bytes].unpack('s<*')
          raise 'BOMC invalid: octahedral normal count mismatch.' unless integers.length == count * 2
          integers.each_slice(2).flat_map do |pair|
            if pair[0] == -32_768 && pair[1] == -32_768
              [0.0, 0.0, 0.0]
            else
              oct_unproject(pair[0] / 32_767.0, pair[1] / 32_767.0)
            end
          end
        else
          raise "BOMC invalid: unsupported normal codec #{block[:codec]}."
        end
      end

      def oct_project(unit)
        denominator = unit.map(&:abs).inject(0.0, :+)
        x = unit[0] / denominator
        y = unit[1] / denominator
        if unit[2] < 0.0
          old_x = x
          x = (1.0 - y.abs) * sign(old_x)
          y = (1.0 - old_x.abs) * sign(y)
        end
        [x, y]
      end
      private_class_method :oct_project

      def oct_unproject(x, y)
        z = 1.0 - x.abs - y.abs
        if z < 0.0
          old_x = x
          x = (1.0 - y.abs) * sign(old_x)
          y = (1.0 - old_x.abs) * sign(y)
        end
        CodecMath.normalize([x, y, z]) || [0.0, 0.0, 0.0]
      end
      private_class_method :oct_unproject

      def sign(value)
        value < 0.0 ? -1.0 : 1.0
      end
      private_class_method :sign

      def angular_errors(source, decoded)
        source.each_slice(3).with_index.map do |normal, index|
          left = CodecMath.normalize(normal)
          right = CodecMath.normalize(decoded[index * 3, 3])
          next 0.0 if left.nil? && right.nil?
          next 180.0 if left.nil? || right.nil?

          dot = [[CodecMath.dot(left, right), -1.0].max, 1.0].min
          Math.acos(dot) * 180.0 / Math::PI
        end
      end
      private_class_method :angular_errors
    end

    module UVCodec
      FLOAT32 = 1
      FLOAT16 = 2
      INT16_QUANTIZED = 3
      DELTA_VARINT = 4
      FLOAT64 = 5
      MAX_ERROR = 1.0e-4

      module_function

      def encode(values, max_error: MAX_ERROR)
        source = Array(values).map(&:to_f)
        raise ArgumentError, 'UV buffer must contain pairs.' unless (source.length % 2).zero?
        CodecMath.finite_values!(source, 'UV buffer')

        candidates = []
        float32_bytes = source.pack('e*')
        candidates << uv_candidate('float32', FLOAT32, float32_bytes, [0.0, 0.0], [0.0, 0.0], source, float32_bytes.unpack('e*'), max_error, 0)

        half_values = source.map { |value| float_to_half(value) }
        half_bytes = half_values.pack('S<*')
        half_decoded = half_values.map { |value| half_to_float(value) }
        candidates << uv_candidate('float16', FLOAT16, half_bytes, [0.0, 0.0], [0.0, 0.0], source, half_decoded, max_error, 2)

        minimum, maximum = uv_bounds(source)
        center = 2.times.map { |axis| (minimum[axis] + maximum[axis]) * 0.5 }
        scale = 2.times.map do |axis|
          span = maximum[axis] - minimum[axis]
          span.zero? ? 0.0 : span / 65_534.0
        end
        integers = source.each_with_index.map do |value, index|
          axis = index % 2
          scale[axis].zero? ? 0 : ((value - center[axis]) / scale[axis]).round
        end
        quantized_bytes = integers.pack('s<*')
        quantized_decoded = uv_dequantize(integers, center, scale)
        candidates << uv_candidate('int16_quantized', INT16_QUANTIZED, quantized_bytes, center, scale, source, quantized_decoded, max_error, 1)

        previous = 0
        delta_bytes = integers.map do |integer|
          delta = integer - previous
          previous = integer
          Binary.write_zigzag(delta)
        end.join.b
        candidates << uv_candidate('delta_varint', DELTA_VARINT, delta_bytes, center, scale, source, quantized_decoded, max_error, 3)

        float64_bytes = source.pack('E*')
        candidates << uv_candidate('float64', FLOAT64, float64_bytes, [0.0, 0.0], [0.0, 0.0], source, source, max_error, 4)

        passing = candidates.select { |item| item[:passed] }
        raise 'No UV codec passed the error gate.' if passing.empty?
        selected = passing.min_by { |item| [item[:deflate_bytes], item[:complexity]] }
        result = selected.reject { |key, _value| [:name, :passed, :raw_bytes, :deflate_bytes, :complexity].include?(key) }
        result[:count] = source.length / 2
        result[:candidates] = candidates.map do |item|
          item.reject { |key, _value| [:bytes, :origin, :scale, :complexity].include?(key) }
        end
        result
      end

      def decode(block)
        count = Integer(block[:count]) * 2
        origin = Array(block[:origin]).map(&:to_f)
        scale = Array(block[:scale]).map(&:to_f)
        values = case block[:codec]
                 when FLOAT32 then block[:bytes].unpack('e*')
                 when FLOAT16 then block[:bytes].unpack('S<*').map { |value| half_to_float(value) }
                 when INT16_QUANTIZED then uv_dequantize(block[:bytes].unpack('s<*'), origin, scale)
                 when DELTA_VARINT
                   integers = []
                   previous = 0
                   cursor = 0
                   count.times do
                     delta, cursor = Binary.read_zigzag(block[:bytes], cursor)
                     previous += delta
                     integers << previous
                   end
                   raise 'BOMC invalid: trailing UV delta bytes.' unless cursor == block[:bytes].bytesize
                   uv_dequantize(integers, origin, scale)
                 when FLOAT64 then block[:bytes].unpack('E*')
                 else raise "BOMC invalid: unsupported UV codec #{block[:codec]}."
                 end
        raise 'BOMC invalid: UV value count mismatch.' unless values.length == count
        values
      end

      def uv_candidate(name, codec, bytes, origin, scale, source, decoded, max_error, complexity)
        errors = source.each_slice(2).with_index.map do |pair, index|
          offset = index * 2
          Math.sqrt(2.times.map { |axis| (pair[axis] - decoded[offset + axis])**2 }.inject(0.0, :+))
        end
        summary = CodecMath.error_summary(errors)
        {
          name: name, codec: codec, bytes: bytes, origin: origin, scale: scale,
          errors: summary, passed: summary[:max] <= max_error + 1.0e-12,
          raw_bytes: bytes.bytesize, deflate_bytes: CodecMath.compressed_size(bytes), complexity: complexity
        }
      end
      private_class_method :uv_candidate

      def uv_bounds(values)
        minimum = [Float::INFINITY, Float::INFINITY]
        maximum = [-Float::INFINITY, -Float::INFINITY]
        values.each_with_index do |value, index|
          axis = index % 2
          minimum[axis] = value if value < minimum[axis]
          maximum[axis] = value if value > maximum[axis]
        end
        return [[0.0, 0.0], [0.0, 0.0]] if values.empty?
        [minimum, maximum]
      end
      private_class_method :uv_bounds

      def uv_dequantize(integers, origin, scale)
        integers.each_with_index.map { |integer, index| origin[index % 2] + integer * scale[index % 2] }
      end
      private_class_method :uv_dequantize

      def float_to_half(value)
        bits = [value.to_f].pack('g').unpack('L>')[0]
        sign = (bits >> 16) & 0x8000
        exponent = ((bits >> 23) & 0xff) - 127 + 15
        mantissa = bits & 0x7f_ffff
        if exponent <= 0
          return sign if exponent < -10
          mantissa = (mantissa | 0x80_0000) >> (1 - exponent)
          return sign | ((mantissa + 0x1000) >> 13)
        end
        return sign | 0x7c00 if exponent >= 31

        rounded = mantissa + 0x1000
        if (rounded & 0x80_0000) != 0
          rounded = 0
          exponent += 1
          return sign | 0x7c00 if exponent >= 31
        end
        sign | (exponent << 10) | (rounded >> 13)
      end
      private_class_method :float_to_half

      def half_to_float(value)
        sign = (value & 0x8000) << 16
        exponent = (value >> 10) & 0x1f
        mantissa = value & 0x03ff
        bits = if exponent.zero?
                 if mantissa.zero?
                   sign
                 else
                   exponent = 1
                   while (mantissa & 0x0400).zero?
                     mantissa <<= 1
                     exponent -= 1
                   end
                   mantissa &= 0x03ff
                   sign | ((exponent + 127 - 15) << 23) | (mantissa << 13)
                 end
               elsif exponent == 31
                 sign | 0x7f80_0000 | (mantissa << 13)
               else
                 sign | ((exponent + 127 - 15) << 23) | (mantissa << 13)
               end
        [bits].pack('L>').unpack('g')[0]
      end
      private_class_method :half_to_float
    end

    module TransformCodec
      FLOAT64_3X4 = 1
      FLOAT32_3X4 = 2
      DECOMPOSED_FLOAT32 = 3
      DECOMPOSED_QUANTIZED = 4
      HYBRID = 5
      MAX_ERROR = 1.0e-5
      AFFINE_INDICES = [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14].freeze

      module_function

      def encode(values, max_error: MAX_ERROR)
        transforms = normalize_transforms(values)
        CodecMath.finite_values!(transforms.flatten, 'Transform buffer')
        candidates = []

        float64_bytes = transforms.map { |matrix| affine(matrix).pack('E*') }.join.b
        candidates << transform_candidate('float64_3x4', FLOAT64_3X4, float64_bytes, transforms, decode_mode(FLOAT64_3X4, float64_bytes, transforms.length), max_error, 0)

        float32_bytes = transforms.map { |matrix| affine(matrix).pack('e*') }.join.b
        candidates << transform_candidate('float32_3x4', FLOAT32_3X4, float32_bytes, transforms, decode_mode(FLOAT32_3X4, float32_bytes, transforms.length), max_error, 1)

        decomposed = transforms.map { |matrix| decompose(matrix) }
        if decomposed.all?
          decomposed_float_bytes = decomposed.map { |parts| (parts[:translation] + parts[:quaternion] + parts[:scale]).pack('e*') }.join.b
          decomposed_float_decoded = decode_mode(DECOMPOSED_FLOAT32, decomposed_float_bytes, transforms.length)
          candidates << transform_candidate('decomposed_float32', DECOMPOSED_FLOAT32, decomposed_float_bytes, transforms, decomposed_float_decoded, max_error, 3)

          quantized_bytes = decomposed.map { |parts| pack_quantized_parts(parts) }.join.b
          quantized_decoded = decode_mode(DECOMPOSED_QUANTIZED, quantized_bytes, transforms.length)
          candidates << transform_candidate('decomposed_quantized', DECOMPOSED_QUANTIZED, quantized_bytes, transforms, quantized_decoded, max_error, 2)
        else
          candidates << failed_transform_candidate('decomposed_float32', DECOMPOSED_FLOAT32)
          candidates << failed_transform_candidate('decomposed_quantized', DECOMPOSED_QUANTIZED)
        end

        hybrid_bytes = +''.b
        transforms.each do |matrix|
          if identity?(matrix)
            hybrid_bytes << 0
            next
          end
          parts = decompose(matrix)
          if parts
            quantized = pack_quantized_parts(parts)
            decoded = decode_mode(DECOMPOSED_QUANTIZED, quantized, 1)[0]
            if matrix_error(matrix, decoded) <= max_error
              hybrid_bytes << DECOMPOSED_QUANTIZED
              hybrid_bytes << quantized
              next
            end
          end
          packed_float = affine(matrix).pack('e*')
          decoded_float = decode_mode(FLOAT32_3X4, packed_float, 1)[0]
          if matrix_error(matrix, decoded_float) <= max_error
            hybrid_bytes << FLOAT32_3X4
            hybrid_bytes << packed_float
          else
            hybrid_bytes << FLOAT64_3X4
            hybrid_bytes << affine(matrix).pack('E*')
          end
        end
        hybrid_decoded = decode_mode(HYBRID, hybrid_bytes, transforms.length)
        candidates << transform_candidate('hybrid', HYBRID, hybrid_bytes, transforms, hybrid_decoded, max_error, 4)

        passing = candidates.select { |item| item[:passed] }
        raise 'No transform codec passed the error gate.' if passing.empty?
        selected = passing.min_by { |item| [item[:deflate_bytes], item[:complexity]] }
        result = selected.reject { |key, _value| [:name, :passed, :raw_bytes, :deflate_bytes, :complexity].include?(key) }
        result[:count] = transforms.length
        result[:candidates] = candidates.map do |item|
          item.reject { |key, _value| [:bytes, :complexity].include?(key) }
        end
        result
      end

      def decode(block)
        decode_mode(Integer(block[:codec]), block[:bytes], Integer(block[:count]))
      end

      def normalize_transforms(values)
        source = Array(values)
        if source.empty?
          []
        elsif source[0].is_a?(Array)
          source.map do |matrix|
            raise ArgumentError, 'Each transform must contain 16 values.' unless matrix.length == 16
            matrix.map(&:to_f)
          end
        else
          raise ArgumentError, 'Transform buffer must contain 16-value matrices.' unless (source.length % 16).zero?
          source.each_slice(16).map { |matrix| matrix.map(&:to_f) }
        end
      end
      private_class_method :normalize_transforms

      def affine(matrix)
        AFFINE_INDICES.map { |index| matrix[index].to_f }
      end
      private_class_method :affine

      def restore_affine(values)
        matrix = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
        AFFINE_INDICES.each_with_index { |matrix_index, index| matrix[matrix_index] = values[index].to_f }
        matrix
      end
      private_class_method :restore_affine

      def decode_mode(mode, bytes, count)
        case mode
        when FLOAT64_3X4
          values = bytes.unpack('E*')
          raise 'BOMC invalid: Float64 transform count mismatch.' unless values.length == count * 12
          values.each_slice(12).map { |affine_values| restore_affine(affine_values) }
        when FLOAT32_3X4
          values = bytes.unpack('e*')
          raise 'BOMC invalid: Float32 transform count mismatch.' unless values.length == count * 12
          values.each_slice(12).map { |affine_values| restore_affine(affine_values) }
        when DECOMPOSED_FLOAT32
          values = bytes.unpack('e*')
          raise 'BOMC invalid: decomposed transform count mismatch.' unless values.length == count * 10
          values.each_slice(10).map do |parts|
            compose(parts[0, 3], parts[3, 4], parts[7, 3])
          end
        when DECOMPOSED_QUANTIZED
          raise 'BOMC invalid: quantized transform count mismatch.' unless bytes.bytesize == count * 32
          count.times.map { |index| unpack_quantized_parts(bytes.byteslice(index * 32, 32)) }
        when HYBRID
          cursor = 0
          transforms = count.times.map do
            raise 'BOMC invalid: truncated hybrid transform.' if cursor >= bytes.bytesize
            subtype = bytes.getbyte(cursor)
            cursor += 1
            case subtype
            when 0
              restore_affine([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
            when FLOAT64_3X4
              payload = bytes.byteslice(cursor, 96)
              raise 'BOMC invalid: truncated hybrid Float64 transform.' unless payload && payload.bytesize == 96
              cursor += 96
              decode_mode(FLOAT64_3X4, payload, 1)[0]
            when FLOAT32_3X4
              payload = bytes.byteslice(cursor, 48)
              raise 'BOMC invalid: truncated hybrid Float32 transform.' unless payload && payload.bytesize == 48
              cursor += 48
              decode_mode(FLOAT32_3X4, payload, 1)[0]
            when DECOMPOSED_QUANTIZED
              payload = bytes.byteslice(cursor, 32)
              raise 'BOMC invalid: truncated hybrid decomposed transform.' unless payload && payload.bytesize == 32
              cursor += 32
              unpack_quantized_parts(payload)
            else
              raise "BOMC invalid: hybrid transform subtype #{subtype}."
            end
          end
          raise 'BOMC invalid: trailing hybrid transform bytes.' unless cursor == bytes.bytesize
          transforms
        else
          raise "BOMC invalid: unsupported transform codec #{mode}."
        end
      end
      private_class_method :decode_mode

      def decompose(matrix)
        x = [matrix[0], matrix[1], matrix[2]].map(&:to_f)
        y = [matrix[4], matrix[5], matrix[6]].map(&:to_f)
        z = [matrix[8], matrix[9], matrix[10]].map(&:to_f)
        scales = [CodecMath.vector_length(x), CodecMath.vector_length(y), CodecMath.vector_length(z)]
        return nil if scales.any? { |scale| scale <= 1.0e-15 }

        axes = [x, y, z].each_with_index.map { |axis, index| axis.map { |value| value / scales[index] } }
        return nil if CodecMath.dot(axes[0], axes[1]).abs > 1.0e-6
        return nil if CodecMath.dot(axes[0], axes[2]).abs > 1.0e-6
        return nil if CodecMath.dot(axes[1], axes[2]).abs > 1.0e-6

        determinant = CodecMath.dot(axes[0], CodecMath.cross(axes[1], axes[2]))
        return nil if (determinant.abs - 1.0).abs > 1.0e-6
        if determinant < 0.0
          scales[0] = -scales[0]
          axes[0] = axes[0].map { |value| -value }
        end
        quaternion = matrix_to_quaternion(axes)
        {
          translation: [matrix[12], matrix[13], matrix[14]].map(&:to_f),
          quaternion: quaternion,
          scale: scales
        }
      end
      private_class_method :decompose

      def matrix_to_quaternion(axes)
        r00, r10, r20 = axes[0]
        r01, r11, r21 = axes[1]
        r02, r12, r22 = axes[2]
        trace = r00 + r11 + r22
        if trace > 0.0
          s = Math.sqrt(trace + 1.0) * 2.0
          quaternion = [(r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, 0.25 * s]
        elsif r00 > r11 && r00 > r22
          s = Math.sqrt(1.0 + r00 - r11 - r22) * 2.0
          quaternion = [0.25 * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s]
        elsif r11 > r22
          s = Math.sqrt(1.0 + r11 - r00 - r22) * 2.0
          quaternion = [(r01 + r10) / s, 0.25 * s, (r12 + r21) / s, (r02 - r20) / s]
        else
          s = Math.sqrt(1.0 + r22 - r00 - r11) * 2.0
          quaternion = [(r02 + r20) / s, (r12 + r21) / s, 0.25 * s, (r10 - r01) / s]
        end
        quaternion = CodecMath.normalize(quaternion)
        quaternion = quaternion.map { |value| -value } if quaternion[3] < 0.0
        quaternion
      end
      private_class_method :matrix_to_quaternion

      def compose(translation, quaternion, scale)
        x, y, z, w = CodecMath.normalize(quaternion) || [0.0, 0.0, 0.0, 1.0]
        xx = x * x
        yy = y * y
        zz = z * z
        xy = x * y
        xz = x * z
        yz = y * z
        wx = w * x
        wy = w * y
        wz = w * z
        columns = [
          [1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz), 2.0 * (xz - wy)],
          [2.0 * (xy - wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx)],
          [2.0 * (xz + wy), 2.0 * (yz - wx), 1.0 - 2.0 * (xx + yy)]
        ]
        columns.each_with_index do |column, index|
          columns[index] = column.map { |value| value * scale[index].to_f }
        end
        restore_affine(columns.flatten + translation.map(&:to_f))
      end
      private_class_method :compose

      def pack_quantized_parts(parts)
        quaternion = CodecMath.normalize(parts[:quaternion])
        integers = quaternion.map { |value| [[(value * 32_767.0).round, -32_767].max, 32_767].min }
        parts[:translation].pack('e*') + integers.pack('s<*') + parts[:scale].pack('e*')
      end
      private_class_method :pack_quantized_parts

      def unpack_quantized_parts(bytes)
        translation = bytes.byteslice(0, 12).unpack('e*')
        quaternion = bytes.byteslice(12, 8).unpack('s<*').map { |value| value / 32_767.0 }
        scale = bytes.byteslice(20, 12).unpack('e*')
        compose(translation, quaternion, scale)
      end
      private_class_method :unpack_quantized_parts

      def transform_candidate(name, codec, bytes, source, decoded, max_error, complexity)
        errors = source.each_with_index.map { |matrix, index| matrix_error(matrix, decoded[index]) }
        summary = CodecMath.error_summary(errors)
        {
          name: name, codec: codec, bytes: bytes, errors: summary,
          passed: summary[:max] <= max_error + 1.0e-12,
          raw_bytes: bytes.bytesize, deflate_bytes: CodecMath.compressed_size(bytes), complexity: complexity
        }
      end
      private_class_method :transform_candidate

      def failed_transform_candidate(name, codec)
        {
          name: name, codec: codec, bytes: ''.b, errors: { max: Float::INFINITY, p95: Float::INFINITY, rms: Float::INFINITY },
          passed: false, raw_bytes: 0, deflate_bytes: 0, complexity: 9
        }
      end
      private_class_method :failed_transform_candidate

      def matrix_error(left, right)
        left.each_with_index.map { |value, index| (value.to_f - right[index].to_f).abs }.max || 0.0
      end
      private_class_method :matrix_error

      def identity?(matrix)
        identity = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
        matrix == identity
      end
      private_class_method :identity?
    end
  end
end

end # SibamboHistory
