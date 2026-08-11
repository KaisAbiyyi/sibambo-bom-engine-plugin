# frozen_string_literal: true

require 'digest'

module BOMEngine
  module CleanAnalysis
    # Export-time texture bytes and face-local UV data. This object deliberately
    # stays outside the neutral SemanticV2 snapshot and is only consumed by the
    # optional Clean Visual package path.
    class TextureBundle
      EXTENSION_PATTERN = /\A[a-z0-9]+\z/.freeze

      attr_reader :assets

      def initialize
        @assets = {}
        @textures = {}
        @uv = {}
      end

      def register_texture(material_uuid:, bytes:, extension:, width_m: nil, height_m: nil)
        payload = bytes.to_s.b
        raise ArgumentError, 'texture bytes must not be empty' if payload.empty?

        ext = extension.to_s.downcase.sub(/\A\./, '')
        ext = 'png' unless EXTENSION_PATTERN.match?(ext)
        path = "assets/tex-#{Digest::SHA256.hexdigest(payload)}.#{ext}"
        @assets[path] ||= payload.freeze
        @textures[material_uuid.to_s] = {
          'asset' => path,
          'width_m' => numeric_or_nil(width_m),
          'height_m' => numeric_or_nil(height_m)
        }.reject { |_key, value| value.nil? }.freeze
        path
      end

      def register_missing(material_uuid:, reason:)
        @textures[material_uuid.to_s] = {
          'status' => 'missing',
          'reason' => reason.to_s
        }.freeze
      end

      def register_uv(primitive_key:, front: nil, back: nil)
        value = {}
        value[:front] = normalize_mapping(front) unless front.nil?
        value[:back] = normalize_mapping(back) unless back.nil?
        @uv[key_for(primitive_key)] = value.freeze
      end

      def texture_for(material_uuid)
        @textures[material_uuid.to_s]
      end

      def uv_for(primitive_key)
        @uv[key_for(primitive_key)]
      end

      private

      def key_for(value)
        Array(value).flatten.map(&:to_s).join('|')
      end

      def normalize_mapping(mapping)
        value = mapping || {}
        {
          outer: normalize_loop(value[:outer] || value['outer'] || []),
          holes: Array(value[:holes] || value['holes']).map { |loop| normalize_loop(loop) }.freeze
        }.freeze
      end

      def normalize_loop(loop)
        Array(loop).map do |uv|
          values = Array(uv)
          unless values.length == 2 && values.all? { |item| item.is_a?(Numeric) && item.finite? }
            raise ArgumentError, 'UV coordinates must be finite [u, v] pairs'
          end
          [values[0].to_f, values[1].to_f].freeze
        end.freeze
      end

      def numeric_or_nil(value)
        value.nil? ? nil : value.to_f
      end
    end
  end
end
