# frozen_string_literal: true

module BOMEngine
  module CleanAnalysis
    # Internal, deterministic source-primitive disposition accounting. The full
    # ledger is emitted only for debug exports; production receives aggregates.
    class CoverageLedger
      DISPOSITIONS = %w[analytical visual_retained fallback explicitly_excluded].freeze
      PRIORITY = {
        'explicitly_excluded' => 0,
        'fallback' => 1,
        'visual_retained' => 2,
        'analytical' => 3
      }.freeze

      def initialize(primitives, visual_edges)
        @entries = {}
        primitives.each do |primitive|
          add(
            primitive.key,
            primitive_type: 'polygon',
            definition_uuid: primitive.definition_uuid
          )
        end
        visual_edges.each do |edge|
          add(
            edge_key(edge),
            primitive_type: 'standalone_edge',
            definition_uuid: edge_value(edge, :definition_uuid)
          )
        end
      end

      def mark(source_key, disposition, reason:, occurrence_ancestry: nil)
        raise ArgumentError, "unsupported coverage disposition: #{disposition}" unless DISPOSITIONS.include?(disposition)

        entry = @entries.fetch(key_string(source_key))
        if entry['disposition'].nil? || PRIORITY.fetch(disposition) > PRIORITY.fetch(entry['disposition'])
          entry['disposition'] = disposition
          entry['reason'] = reason.to_s
        end
        ancestry = Array(occurrence_ancestry)
        unless ancestry.empty? || entry['occurrence_ancestries'].include?(ancestry)
          entry['occurrence_ancestries'] << ancestry.dup
          entry['occurrence_ancestries'].sort!
        end
      end

      def counts
        result = DISPOSITIONS.each_with_object({}) { |name, values| values[name] = 0 }
        @entries.each_value do |entry|
          disposition = entry['disposition']
          disposition.nil? ? result['unaccounted'] = result.fetch('unaccounted', 0) + 1 : result[disposition] += 1
        end
        result['unaccounted'] ||= 0
        result
      end

      def entries
        @entries.values.sort_by { |entry| entry.fetch('source_key') }.map do |entry|
          entry.merge('occurrence_ancestries' => entry.fetch('occurrence_ancestries').map(&:dup))
        end
      end

      private

      def add(source_key, primitive_type:, definition_uuid:)
        key = key_string(source_key)
        raise ArgumentError, "duplicate coverage source key: #{key}" if @entries.key?(key)

        @entries[key] = {
          'source_key' => Array(source_key).map(&:to_s),
          'primitive_type' => primitive_type,
          'definition_uuid' => definition_uuid.to_s,
          'occurrence_ancestries' => [],
          'disposition' => nil,
          'reason' => nil
        }
      end

      def edge_key(edge)
        [edge_value(edge, :definition_uuid), edge_value(edge, :source_uuid)]
      end

      def edge_value(edge, key)
        edge.fetch(key) { edge.fetch(key.to_s) }
      end

      def key_string(value)
        Array(value).map(&:to_s).join('/')
      end
    end
  end
end
