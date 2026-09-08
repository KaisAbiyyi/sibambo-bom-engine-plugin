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
        @raw_sections = {}
        @stats = {
          normalization_hits: 0,
          normalization_misses: 0,
          candidate_hits: 0,
          candidate_misses: 0,
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
        @raw_sections.clear
      end
    end
  end
end
