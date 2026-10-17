# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'

module BOMEngine
  module EvolutionStream
    BASE64_INPUT_CHUNK = 48 * 1024
    JSON_SCALAR_CHUNK = 1024
    OUTPUT_BUFFER_BYTES = 64 * 1024

    class DigestIO
      attr_reader :bytes

      def initialize(io)
        @io = io
        @digest = Digest::SHA256.new
        @bytes = 0
      end

      def write(value)
        bytes = value.to_s.b
        written = @io.write(bytes)
        @digest.update(bytes.byteslice(0, written))
        @bytes += written
        written
      end

      def flush
        @io.flush
      end

      def sha256
        @digest.hexdigest
      end
    end

    class BufferedIO
      def initialize(io, limit = OUTPUT_BUFFER_BYTES)
        @io = io
        @limit = Integer(limit)
        @buffer = ''.b
      end

      def write(value)
        bytes = value.to_s.b
        if bytes.bytesize >= @limit
          flush
          return @io.write(bytes)
        end
        @buffer << bytes
        flush if @buffer.bytesize >= @limit
        bytes.bytesize
      end

      def flush
        return if @buffer.empty?
        @io.write(@buffer)
        @buffer.clear
      end
    end

    module_function

    def write_json(io, value)
      case value
      when Hash
        io.write('{')
        first = true
        value.each do |key, child|
          io.write(',') unless first
          first = false
          io.write(JSON.generate(key.to_s))
          io.write(':')
          write_json(io, child)
        end
        io.write('}')
      when Array
        write_array(io, value)
      else
        io.write(JSON.generate(value))
      end
    end

    def write_array(io, value)
      io.write('[')
      if value.all? { |child| json_scalar?(child) }
        first = true
        value.each_slice(JSON_SCALAR_CHUNK) do |chunk|
          encoded = JSON.generate(chunk)
          body = encoded.byteslice(1, encoded.bytesize - 2)
          next if body.empty?
          io.write(',') unless first
          first = false
          io.write(body)
        end
      else
        value.each_with_index do |child, index|
          io.write(',') unless index.zero?
          if child.is_a?(Hash)
            # A single canonical row/mesh is the bounded ownership unit. Let the
            # native JSON encoder handle it in one pass instead of allocating a
            # Ruby String per scalar; we still never materialize the full graph.
            io.write(JSON.generate(child))
          else
            write_json(io, child)
          end
        end
      end
      io.write(']')
    end
    private_class_method :write_array

    def json_scalar?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.nil?
    end
    private_class_method :json_scalar?

    def write_assets(io, assets)
      io.write('[')
      Array(assets).each_with_index do |asset, index|
        io.write(',') unless index.zero?
        write_asset(io, asset)
      end
      io.write(']')
    end

    def write_asset(io, asset)
      io.write('{')
      first = true
      asset.each do |key, value|
        next if key == 'bytes'
        io.write(',') unless first
        first = false
        io.write(JSON.generate(key.to_s))
        io.write(':')
        write_json(io, value)
      end
      io.write(',') unless first
      io.write(JSON.generate('data_base64'))
      io.write(':')
      write_base64_string(io, asset.fetch('bytes'))
      io.write('}')
    end

    def write_base64_string(io, bytes)
      raw = bytes.to_s.b
      io.write('"')
      offset = 0
      while offset < raw.bytesize
        length = [BASE64_INPUT_CHUNK, raw.bytesize - offset].min
        unless length == raw.bytesize - offset
          length -= length % 3
        end
        chunk = raw.byteslice(offset, length)
        io.write(Base64.strict_encode64(chunk))
        offset += length
      end
      io.write('"')
    end
  end
end
