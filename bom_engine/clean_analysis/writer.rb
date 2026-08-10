# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'stringio'

module BOMEngine
  module CleanAnalysis
    module Writer
      FORBIDDEN_GEOMETRY_KEYS = %w[triangles faces positions loops].freeze

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

        document.fetch('surfaces', []).each do |surface|
          report_progress(progress)
          SurfaceValidator.validate!(surface)
        end
        document.fetch('definitions', []).each do |definition|
          definition.fetch('geometry').fetch('surfaces').each do |surface|
            report_progress(progress)
            SurfaceValidator.validate!(surface)
          end
        end
      end
      private_class_method :validate_document!

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
