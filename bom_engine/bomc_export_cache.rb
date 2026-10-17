# frozen_string_literal: true
# Single-pass export caching for normalization, raw sections, and candidate groups (Track T6)

require 'digest'

module BOMEngine
  module BOMCExportCache
    POLICY_REVISION = '2026.09.08.1'.freeze

    class Cache
      attr_reader :stats

      def initialize
        @normalizations = {}
        @candidates = {}
        @preparations = {}
        @raw_sections = {}
        @stats = {
          normalization_hits: 0,
          normalization_misses: 0,
          candidate_hits: 0,
          candidate_misses: 0,
          preparation_hits: 0,
          preparation_misses: 0,
          raw_section_hits: 0,
          raw_section_misses: 0
        }
      end

      def self.compute_key(source_digest:, profile:, semantic_class: nil, texture_digest: nil, encoder_digest: nil, policy_revision: POLICY_REVISION)
        Digest::SHA256.hexdigest([
          source_digest.to_s,
          profile.to_s,
          semantic_class.to_s,
          texture_digest.to_s,
          encoder_digest.to_s,
          policy_revision.to_s
        ].join(':::'))
      end

      # Bounded-memory deterministic identity for synthetic/unsaved fixtures.
      # Production exports should normally arrive with the saved SKP digest from
      # BOMCSizeGate.source_info / CaptureIR and never need this fallback.
      def self.stable_source_digest(value)
        digest = Digest::SHA256.new
        update_digest(digest, value, {})
        digest.hexdigest
      end

      def self.update_digest(digest, value, seen)
        case value
        when Hash
          object_id = value.object_id
          if seen[object_id]
            digest.update('H:cycle;')
            return
          end
          seen[object_id] = true
          digest.update("H#{value.length}:")
          value.keys.sort_by { |key| [key.class.name.to_s, key.to_s] }.each do |key|
            update_digest(digest, key, seen)
            update_digest(digest, value[key], seen)
          end
          seen.delete(object_id)
        when Array
          object_id = value.object_id
          if seen[object_id]
            digest.update('A:cycle;')
            return
          end
          seen[object_id] = true
          digest.update("A#{value.length}:")
          value.each { |child| update_digest(digest, child, seen) }
          seen.delete(object_id)
        when String
          bytes = value.b
          digest.update("S#{bytes.bytesize}:")
          digest.update(bytes)
        when Symbol
          text = value.to_s
          digest.update("Y#{text.bytesize}:#{text}")
        when Integer
          digest.update("I#{value};")
        when Float
          digest.update('F')
          digest.update([value].pack('G'))
        when true
          digest.update('T;')
        when false
          digest.update('F;')
        when nil
          digest.update('N;')
        else
          klass = value.class.name.to_s
          text = value.to_s
          digest.update("O#{klass.bytesize}:#{klass}:#{text.bytesize}:")
          digest.update(text)
        end
      end
      private_class_method :update_digest

      def fetch_normalization(key)
        if @normalizations.key?(key)
          @stats[:normalization_hits] += 1
          @normalizations[key]
        else
          @stats[:normalization_misses] += 1
          nil
        end
      end

      def store_normalization(key, model)
        @normalizations[key] = model
      end

      def fetch_candidates(key)
        if @candidates.key?(key)
          @stats[:candidate_hits] += 1
          @candidates[key]
        else
          @stats[:candidate_misses] += 1
          nil
        end
      end

      def store_candidates(key, candidates)
        @candidates[key] = candidates
      end

      def fetch_preparation(key)
        if @preparations.key?(key)
          @stats[:preparation_hits] += 1
          @preparations[key]
        else
          @stats[:preparation_misses] += 1
          nil
        end
      end

      def store_preparation(key, preparation)
        @preparations[key] = preparation
      end

      def peek_preparation(key)
        @preparations[key]
      end

      def fetch_raw_section(key)
        if @raw_sections.key?(key)
          @stats[:raw_section_hits] += 1
          @raw_sections[key]
        else
          @stats[:raw_section_misses] += 1
          nil
        end
      end

      def store_raw_section(key, section_bytes)
        @raw_sections[key] = section_bytes
      end

      def clear!
        @normalizations.clear
        @candidates.clear
        @preparations.clear
        @raw_sections.clear
      end
    end
  end
end
