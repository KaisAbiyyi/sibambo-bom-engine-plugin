# frozen_string_literal: true

require 'digest'

module BOMEngine
  module SemanticV2
    # RFC 8785 (JCS) serialization for JSON-compatible Ruby values.
    module CanonicalJSON
      module_function

      def generate(value)
        serialize(value).encode(Encoding::UTF_8)
      end

      def sha256(value)
        Digest::SHA256.hexdigest(generate(value))
      end

      def serialize(value)
        case value
        when nil
          'null'
        when true
          'true'
        when false
          'false'
        when String
          serialize_string(value)
        when Symbol
          serialize_string(value.to_s)
        when Integer, Float
          serialize_number(value)
        when Array
          "[#{value.map { |item| serialize(item) }.join(',')}]"
        when Hash
          serialize_object(value)
        else
          raise ArgumentError, "unsupported JSON value: #{value.class}"
        end
      end
      private_class_method :serialize

      def serialize_object(value)
        members = {}
        value.each do |key, member_value|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "JSON object key must be a String or Symbol: #{key.class}"
          end

          name = key.to_s
          raise ArgumentError, "invalid UTF-8 object key" unless valid_utf8?(name)
          raise ArgumentError, "duplicate object key: #{name.inspect}" if members.key?(name)

          members[name] = member_value
        end

        ordered_names = members.keys.sort_by { |name| utf16_code_units(name) }
        body = ordered_names.map do |name|
          "#{serialize_string(name)}:#{serialize(members.fetch(name))}"
        end
        "{#{body.join(',')}}"
      end
      private_class_method :serialize_object

      def serialize_string(value)
        raise ArgumentError, 'invalid UTF-8 string' unless valid_utf8?(value)

        escaped = value.encode(Encoding::UTF_8).each_codepoint.map do |codepoint|
          case codepoint
          when 0x08 then '\\b'
          when 0x09 then '\\t'
          when 0x0A then '\\n'
          when 0x0C then '\\f'
          when 0x0D then '\\r'
          when 0x22 then '\\"'
          when 0x5C then '\\\\'
          when 0x00..0x1F then format('\\u%04x', codepoint)
          else codepoint.chr(Encoding::UTF_8)
          end
        end.join
        "\"#{escaped}\""
      end
      private_class_method :serialize_string

      def valid_utf8?(value)
        value.encode(Encoding::UTF_8).valid_encoding?
      rescue EncodingError
        false
      end
      private_class_method :valid_utf8?

      def utf16_code_units(value)
        value.encode(Encoding::UTF_16BE).unpack('n*')
      end
      private_class_method :utf16_code_units

      # Ruby 3.2 and ECMAScript both choose a shortest round-trippable decimal
      # for an IEEE-754 double. JCS differs only in decimal/exponent layout, so
      # decompose Ruby's shortest digits and apply ECMAScript's thresholds.
      def serialize_number(value)
        number = Float(value)
        raise ArgumentError, 'non-finite JSON number' unless number.finite?
        return '0' if number.zero?

        sign = number.negative? ? '-' : ''
        source = number.abs.to_s
        coefficient, exponent_text = source.split(/[eE]/, 2)
        decimal_index = coefficient.index('.') || coefficient.length
        digits = coefficient.delete('.')
        exponent = exponent_text ? exponent_text.to_i : 0
        decimal_position = decimal_index + exponent

        leading_zeroes = digits[/\A0*/].length
        digits = digits[leading_zeroes..-1]
        decimal_position -= leading_zeroes
        digits = digits.sub(/0+\z/, '')

        scientific_exponent = decimal_position - 1
        rendered = if decimal_position.positive? && decimal_position <= 21
                     if digits.length <= decimal_position
                       digits + ('0' * (decimal_position - digits.length))
                     else
                       "#{digits[0, decimal_position]}.#{digits[decimal_position..-1]}"
                     end
                   elsif decimal_position <= 0 && decimal_position > -6
                     "0.#{'0' * -decimal_position}#{digits}"
                   else
                     mantissa = digits.length == 1 ? digits : "#{digits[0]}.#{digits[1..-1]}"
                     exponent_sign = scientific_exponent >= 0 ? '+' : ''
                     "#{mantissa}e#{exponent_sign}#{scientific_exponent}"
                   end

        sign + rendered
      end
      private_class_method :serialize_number
    end
  end
end
