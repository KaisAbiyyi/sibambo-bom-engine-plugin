# frozen_string_literal: true

module BOMEngine
  module NumericShape
    class ShapeError < ArgumentError; end

    module_function

    def scalar(value, path:)
      if value.nil? || value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(TrueClass) || value.is_a?(FalseClass) || value.is_a?(Symbol)
        raise_shape(path, 'numeric scalar', value)
      end

      num = if value.is_a?(Numeric)
              value.to_f
            elsif length_like?(value) && value.respond_to?(:to_f)
              value.to_f
            elsif value.is_a?(String)
              Float(value)
            else
              raise_shape(path, 'numeric scalar', value)
            end

      unless num.finite?
        raise_shape(path, 'finite numeric scalar', value)
      end

      num
    rescue ShapeError
      raise
    rescue StandardError
      raise_shape(path, 'numeric scalar', value)
    end

    def optional_vec2(value, path:)
      return nil if value.nil?

      vec2(value, path: path)
    end

    def optional_vec3(value, path:)
      return nil if value.nil?

      vec3(value, path: path)
    end

    def vec2(value, path:)
      raw = if value.is_a?(Hash)
              if coordinate_key?(value, :u) && coordinate_key?(value, :v)
                [coordinate_value(value, :u), coordinate_value(value, :v)]
              elsif coordinate_key?(value, :x) && coordinate_key?(value, :y)
                [coordinate_value(value, :x), coordinate_value(value, :y)]
              else
                raise_shape(path, 'vec2 as [u,v], [x,y], {u:,v:}, or {x:,y:}', value)
              end
            elsif value.is_a?(Array)
              value
            elsif value.respond_to?(:x) && value.respond_to?(:y)
              [value.x, value.y]
            else
              raise_shape(path, 'vec2 as [u,v], [x,y], {u:,v:}, or {x:,y:}', value)
            end

      raise_shape(path, 'vec2 with exactly 2 components', value) unless raw.length == 2
      raw.each_with_index.map { |component, index| scalar(component, path: "#{path}[#{index}]") }
    end

    def vec3(value, path:)
      raw = if value.is_a?(Hash)
              unless coordinate_key?(value, :x) && coordinate_key?(value, :y) && coordinate_key?(value, :z)
                raise_shape(path, 'vec3 as [x,y,z] or {x:,y:,z:}', value)
              end
              [coordinate_value(value, :x), coordinate_value(value, :y), coordinate_value(value, :z)]
            elsif value.is_a?(Array)
              value
            elsif value.respond_to?(:x) && value.respond_to?(:y) && value.respond_to?(:z)
              [value.x, value.y, value.z]
            else
              raise_shape(path, 'vec3 as [x,y,z] or {x:,y:,z:}', value)
            end

      raise_shape(path, 'vec3 with exactly 3 components', value) unless raw.length == 3
      raw.each_with_index.map { |component, index| scalar(component, path: "#{path}[#{index}]") }
    end

    def flat_xyz(value, path:)
      return [] if value.nil?
      return vec3(value, path: path) if value.is_a?(Hash) || xyz_object?(value)
      raise_shape(path, 'flat XYZ scalars or a list of vec3 points', value) unless value.is_a?(Array)
      return [] if value.empty?

      if value.all? { |item| scalar_like?(item) }
        raise_shape(path, 'flat XYZ scalar count divisible by 3', value) unless (value.length % 3).zero?
        return value.each_with_index.map { |item, index| scalar(item, path: "#{path}[#{index}]") }
      end

      unless value.all? { |item| vec3_like?(item) }
        bad_index = value.index { |item| !vec3_like?(item) }
        raise_shape("#{path}[#{bad_index}]", 'vec3 point; mixed scalar/structured XYZ payloads are not allowed', value[bad_index])
      end

      value.each_with_index.flat_map { |point, index| vec3(point, path: "#{path}[#{index}]") }
    end

    def flat_numeric(value, path:, expected_length: nil, multiple_of: nil)
      raise_shape(path, 'flat numeric array', value) unless value.is_a?(Array)
      result = value.each_with_index.map { |item, index| scalar(item, path: "#{path}[#{index}]") }
      if expected_length && result.length != expected_length
        raise_shape(path, "flat numeric array with exactly #{expected_length} components", value)
      end
      if multiple_of && !(result.length % multiple_of).zero?
        raise_shape(path, "flat numeric array with component count divisible by #{multiple_of}", value)
      end
      result
    end

    def coordinate_key?(hash, key)
      hash.key?(key) || hash.key?(key.to_s)
    end
    private_class_method :coordinate_key?

    def coordinate_value(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
    private_class_method :coordinate_value

    def length_like?(value)
      return true if defined?(Length) && value.is_a?(Length)
      name = value.class.name
      name == 'Length' || (name && name.end_with?('::Length')) || (value.respond_to?(:to_f) && name =~ /Length/i)
    end
    private_class_method :length_like?

    def scalar_like?(value)
      return false if value.nil? || value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(TrueClass) || value.is_a?(FalseClass) || value.is_a?(Symbol)
      if value.is_a?(Numeric)
        value.to_f.finite?
      elsif length_like?(value) && value.respond_to?(:to_f)
        value.to_f.finite? rescue false
      elsif value.is_a?(String)
        begin
          Float(value).finite?
        rescue ArgumentError, TypeError
          false
        end
      else
        false
      end
    end
    private_class_method :scalar_like?

    def xyz_object?(value)
      !value.is_a?(Array) && !value.is_a?(Hash) && value.respond_to?(:x) && value.respond_to?(:y) && value.respond_to?(:z)
    end
    private_class_method :xyz_object?

    def vec3_like?(value)
      return true if value.is_a?(Array) && value.length == 3
      return coordinate_key?(value, :x) && coordinate_key?(value, :y) && coordinate_key?(value, :z) if value.is_a?(Hash)
      xyz_object?(value)
    end
    private_class_method :vec3_like?

    def raise_shape(path, expected, value)
      preview = begin
        value.inspect
      rescue StandardError
        "<#{value.class}>"
      end
      preview = "#{preview[0, 157]}..." if preview.length > 160
      raise ShapeError, "BOMC numeric shape invalid at #{path}: expected #{expected}; got #{value.class}: #{preview}"
    end
    private_class_method :raise_shape
  end
end
