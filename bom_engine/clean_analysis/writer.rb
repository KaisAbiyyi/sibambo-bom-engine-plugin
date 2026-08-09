# frozen_string_literal: true

require 'fileutils'
require 'json'

module BOMEngine
  module CleanAnalysis
    module Writer
      FORBIDDEN_GEOMETRY_KEYS = %w[triangles faces positions loops].freeze

      module_function

      def generate(document)
        validate_document!(document)
        JSON.pretty_generate(document) + "\n"
      end

      def write(path, document)
        output_path = File.expand_path(path.to_s)
        raise ArgumentError, 'clean analysis output path is required' if path.to_s.strip.empty?

        bytes = generate(document)
        FileUtils.mkdir_p(File.dirname(output_path))
        File.open(output_path, 'wb') { |file| file.write(bytes) }
        {
          path: output_path,
          bytes: bytes.bytesize,
          counts: document.fetch('diagnostics').fetch('counts').dup
        }
      end

      def validate_document!(document)
        unless document.is_a?(Hash) && document.dig('format', 'identifier') == Compiler::FORMAT_IDENTIFIER
          raise ArgumentError, 'clean analysis document has the wrong format identifier'
        end

        forbidden = find_forbidden_key(document)
        raise ArgumentError, "redundant geometry key: #{forbidden}" if forbidden
      end
      private_class_method :validate_document!

      def find_forbidden_key(value)
        case value
        when Hash
          value.each do |key, child|
            return key if FORBIDDEN_GEOMETRY_KEYS.include?(key.to_s)

            nested = find_forbidden_key(child)
            return nested if nested
          end
        when Array
          value.each do |child|
            nested = find_forbidden_key(child)
            return nested if nested
          end
        end
        nil
      end
      private_class_method :find_forbidden_key
    end
  end
end
