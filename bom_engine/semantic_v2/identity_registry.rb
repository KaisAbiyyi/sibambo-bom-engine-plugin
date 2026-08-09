# frozen_string_literal: true

require 'json'
require 'securerandom'

module BOMEngine
  module SemanticV2
    # Pure, JSON-shaped state for source ownership and semantic lineage.
    class IdentityRegistry
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i.freeze

      SourceClaim = Struct.new(
        :source_uuid,
        :owner_pid,
        :origin_model_id,
        keyword_init: true
      )
      SourceCollisionResolution = Struct.new(
        :owner_pid,
        :diagnostics,
        keyword_init: true
      )
      SemanticResolution = Struct.new(
        :semantic_uuid,
        :outcome,
        :diagnostics,
        keyword_init: true
      )

      def self.load(raw_json, uuid_generator: -> { SecureRandom.uuid })
        parsed = if raw_json.nil? || (raw_json.is_a?(String) && raw_json.strip.empty?)
                   nil
                 elsif raw_json.is_a?(String)
                   JSON.parse(raw_json)
                 elsif raw_json.is_a?(Hash)
                   raw_json
                 else
                   raise ArgumentError, 'registry must be JSON text, a Hash, or nil'
                 end
        new(parsed, uuid_generator: uuid_generator)
      rescue JSON::ParserError => error
        raise ArgumentError, "invalid registry JSON: #{error.message}"
      end

      def initialize(state, uuid_generator:)
        @uuid_generator = uuid_generator
        if state.nil?
          @model_id = allocate_uuid
          @revision = 0
          @prepared_generation = nil
          @source_claims = {}
          @semantic_lineage = {}
          @changed = true
        else
          load_state(state)
          @changed = false
        end
      end
      private :initialize

      def plan_source_claim(source_uuid:, owner_pid:, origin_model_id:)
        source_uuid = normalize_uuid(source_uuid, 'source_uuid')
        origin_model_id = normalize_uuid(origin_model_id, 'origin_model_id')
        owner_pid = normalize_pid(owner_pid)
        existing = @source_claims[source_uuid]

        if existing
          unless existing.fetch('owner_pid') == owner_pid &&
                 existing.fetch('origin_model_id') == origin_model_id
            raise ArgumentError, "source UUID already belongs to a different claim: #{source_uuid}"
          end
        else
          @source_claims[source_uuid] = {
            'source_uuid' => source_uuid,
            'owner_pid' => owner_pid,
            'origin_model_id' => origin_model_id
          }
          @changed = true
        end

        source_claim_value(@source_claims.fetch(source_uuid))
      end

      def resolve_source_collision(source_uuid:, claims:)
        source_uuid = normalize_uuid(source_uuid, 'source_uuid')
        normalized_claims = Array(claims).map do |claim|
          pid = claim[:owner_pid] || claim['owner_pid']
          normalize_pid(pid)
        end
        raise ArgumentError, 'collision claims cannot be empty' if normalized_claims.empty?

        registry_pid = @source_claims.dig(source_uuid, 'owner_pid')
        if registry_pid && normalized_claims.include?(registry_pid)
          SourceCollisionResolution.new(owner_pid: registry_pid, diagnostics: []).freeze
        else
          SourceCollisionResolution.new(
            owner_pid: normalized_claims.min,
            diagnostics: ['identity.collision_without_registry_owner']
          ).freeze
        end
      end

      def resolve_semantic(type:, exact_key:, candidates:)
        type = normalize_nonempty_string(type, 'semantic type')
        exact_key = normalize_nonempty_string(exact_key, 'semantic exact_key')
        raise ArgumentError, 'semantic candidates must be an Array' unless candidates.is_a?(Array)

        existing = @semantic_lineage.dig(type, exact_key)
        if existing
          return SemanticResolution.new(
            semantic_uuid: detached_string(existing.fetch('semantic_uuid')),
            outcome: 'exact_lineage_match',
            diagnostics: []
          ).freeze
        end

        semantic_uuid = allocate_uuid
        ensure_unused_semantic_uuid!(semantic_uuid)
        @semantic_lineage[type] ||= {}
        @semantic_lineage[type][exact_key] = {
          'semantic_uuid' => semantic_uuid,
          'type' => type,
          'exact_key' => exact_key
        }
        @changed = true
        SemanticResolution.new(
          semantic_uuid: detached_string(semantic_uuid),
          outcome: 'new_identity',
          diagnostics: []
        ).freeze
      end

      def changed?
        @changed
      end

      def next_revision
        @changed ? @revision + 1 : @revision
      end

      def to_h
        deep_copy(
          'model_id' => @model_id,
          'revision' => next_revision,
          'prepared_generation' => @prepared_generation,
          'source_claims' => @source_claims,
          'semantic_lineage' => @semantic_lineage
        )
      end

      private

      def load_state(state)
        state = stringify_keys(state)
        @model_id = normalize_uuid(state.fetch('model_id'), 'model_id')
        @revision = state.fetch('revision', 0)
        unless @revision.is_a?(Integer) && @revision >= 0
          raise ArgumentError, 'registry revision must be a non-negative Integer'
        end

        @prepared_generation = load_prepared_generation(state['prepared_generation'])
        @source_claims = load_source_claims(state.fetch('source_claims', {}))
        @semantic_lineage = load_semantic_lineage(state.fetch('semantic_lineage', {}))
      end

      def load_prepared_generation(value)
        return nil if value.nil?
        return normalize_uuid(value, 'prepared_generation') if value.is_a?(String)

        value = stringify_keys(value)
        revision = value.fetch('revision')
        unless revision.is_a?(Integer) && revision >= 0
          raise ArgumentError, 'prepared generation revision must be a non-negative Integer'
        end
        {
          'generation_uuid' => normalize_uuid(value.fetch('generation_uuid'), 'generation_uuid'),
          'revision' => revision
        }
      end

      def load_source_claims(value)
        value = stringify_keys(value)
        value.each_with_object({}) do |(source_uuid, claim), claims|
          source_uuid = normalize_uuid(source_uuid, 'source_uuid')
          claim = stringify_keys(claim)
          embedded_uuid = normalize_uuid(claim.fetch('source_uuid', source_uuid), 'source_uuid')
          raise ArgumentError, 'source claim key does not match source_uuid' unless embedded_uuid == source_uuid

          claims[source_uuid] = {
            'source_uuid' => source_uuid,
            'owner_pid' => normalize_pid(claim.fetch('owner_pid')),
            'origin_model_id' => normalize_uuid(claim.fetch('origin_model_id'), 'origin_model_id')
          }
        end
      end

      def load_semantic_lineage(value)
        value = stringify_keys(value)
        seen_uuids = {}
        value.each_with_object({}) do |(type, entries), lineage|
          type = normalize_nonempty_string(type, 'semantic type')
          lineage[type] = stringify_keys(entries).each_with_object({}) do |(exact_key, entry), by_key|
            exact_key = normalize_nonempty_string(exact_key, 'semantic exact_key')
            entry = stringify_keys(entry)
            semantic_uuid = normalize_uuid(entry.fetch('semantic_uuid'), 'semantic_uuid')
            raise ArgumentError, "duplicate semantic UUID: #{semantic_uuid}" if seen_uuids[semantic_uuid]
            raise ArgumentError, 'semantic lineage type mismatch' if entry.fetch('type', type).to_s != type
            if entry.fetch('exact_key', exact_key).to_s != exact_key
              raise ArgumentError, 'semantic lineage exact_key mismatch'
            end

            seen_uuids[semantic_uuid] = true
            by_key[exact_key] = {
              'semantic_uuid' => semantic_uuid,
              'type' => type,
              'exact_key' => exact_key
            }
          end
        end
      end

      def allocate_uuid
        normalize_uuid(@uuid_generator.call, 'generated UUID')
      end

      def ensure_unused_semantic_uuid!(semantic_uuid)
        used = @semantic_lineage.any? do |_type, entries|
          entries.any? { |_key, entry| entry.fetch('semantic_uuid') == semantic_uuid }
        end
        raise ArgumentError, "generated duplicate semantic UUID: #{semantic_uuid}" if used
      end

      def normalize_uuid(value, label)
        uuid = value.to_s.downcase.freeze
        raise ArgumentError, "invalid #{label}: #{value.inspect}" unless UUID_PATTERN.match?(uuid)

        uuid
      end

      def normalize_pid(value)
        raise ArgumentError, 'owner_pid must be a non-negative Integer' unless value.is_a?(Integer) && value >= 0

        value
      end

      def normalize_nonempty_string(value, label)
        string = value.to_s.dup.freeze
        raise ArgumentError, "#{label} cannot be empty" if string.empty?

        string
      end

      def source_claim_value(claim)
        SourceClaim.new(
          source_uuid: detached_string(claim.fetch('source_uuid')),
          owner_pid: claim.fetch('owner_pid'),
          origin_model_id: detached_string(claim.fetch('origin_model_id'))
        ).freeze
      end

      def detached_string(value)
        value.dup.freeze
      end

      def stringify_keys(value)
        raise ArgumentError, "expected object, got #{value.class}" unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
