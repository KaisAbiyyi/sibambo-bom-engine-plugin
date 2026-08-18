# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'weakref'

require_relative 'canonical_json'
require_relative 'identity_registry'

module SibamboHistory
  module V20260812_01
  module SemanticV2
    # Produces source identities without mutating SketchUp and owns the isolated
    # model write primitive used later by recoverable publication.
    class IdentityCoordinator
      DICTIONARY = 'BOMEngine.SemanticV2'
      SOURCE_UUID_KEY = 'source_uuid'
      ORIGIN_MODEL_ID_KEY = 'origin_model_id'
      MODEL_ID_KEY = 'model_id'
      REGISTRY_JSON_KEY = 'registry_json'
      REGISTRY_REVISION_KEY = 'registry_revision'
      OPERATION_NAME = 'BOM Engine Semantic v2 Identity'
      MINIMUM_SKETCHUP_VERSION = [20, 1].freeze

      class UnsupportedRuntimeError < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code.to_s.dup.freeze
          super(message)
        end
      end

      EntityWrite = Struct.new(:entity, :source_uuid, :origin_model_id, keyword_init: true)
      PendingState = Struct.new(:model_uuid, :entity_uuids, keyword_init: true)
      PendingOwner = Struct.new(:owner_ref, :value, keyword_init: true)
      ForeignSourceProvenance = Struct.new(
        :source_uuid,
        :origin_model_id,
        :destination_source_uuid,
        keyword_init: true
      )

      # Immutable lookup result consumed by compilation before any model write.
      class Plan
        attr_reader :model_id, :registry, :diagnostics, :foreign_source_provenance

        def initialize(model_id:, registry:, source_uuids:, entity_writes:, model_writes:, diagnostics:,
                       foreign_source_provenance:)
          @model_id = model_id.dup.freeze
          @registry = registry
          @source_uuids = source_uuids.freeze
          @entity_writes = entity_writes.freeze
          @model_writes = model_writes.freeze
          @diagnostics = diagnostics.map { |item| item.dup.freeze }.uniq.sort.freeze
          @foreign_source_provenance = foreign_source_provenance.sort_by do |item|
            [item.origin_model_id, item.source_uuid, item.destination_source_uuid.to_s]
          end.freeze
          freeze
        end

        def source_uuid_for(entity)
          @source_uuids.fetch(entity)
        end

        def occurrence_uuid_for(instance)
          source_uuid_for(instance)
        end

        def write_required?
          registry.changed? || !@entity_writes.empty? || !@model_writes.empty?
        end

        private

        attr_reader :entity_writes, :model_writes
      end

      class << self
        def plan(model:, roots:, uuid_generator: -> { SecureRandom.uuid }, runtime_version: nil,
                 progress: nil, prepare_model_writes: true,
                 deterministic_virtual_identities: false)
          validate_runtime_version!(detected_runtime_version || runtime_version)
          entities = recursively_collect(identity_roots(model, roots), progress)
          validate_persistent_owners!(entities)
          fallback_model_uuid = if deterministic_virtual_identities
                                  deterministic_model_uuid(model, entities)
                                end
          pending = deterministic_virtual_identities ? nil : pending_state_for(model)
          registry = load_registry(
            model,
            uuid_generator,
            pending,
            fallback_model_uuid: fallback_model_uuid
          )
          source_uuids = {}
          entity_writes = []
          diagnostics = []
          foreign_source_provenance = []
          retired_foreign_claims = registry.discard_foreign_source_claims
          active_foreign_keys = {}

          valid = []
          invalid = []
          entities.each do |entity|
            report_progress(progress)
            valid_identity = valid_entity_identity?(
              entity,
              allow_missing_origin: deterministic_virtual_identities
            )
            (valid_identity ? valid : invalid) << entity
          end
          destination_model_id = registry.model_id
          domestic = []
          foreign = []
          valid.each do |entity|
            report_progress(progress)
            origin_model_id = entity_origin_model_id(entity).to_s.downcase
            destination = origin_model_id.empty? || origin_model_id == destination_model_id
            (destination ? domestic : foreign) << entity
          end
          domestic_claims = Hash.new { |hash, key| hash[key] = [] }
          domestic.each do |entity|
            report_progress(progress)
            domestic_claims[normalized_source_uuid(entity)] << entity
          end
          domestic_claims.each_value do |claims|
            report_progress(progress)
            assign_valid_claims(
              claims,
              registry,
              source_uuids,
              entity_writes,
              diagnostics,
              uuid_generator,
              pending,
              deterministic_virtual_identities
            )
          end
          foreign.each do |entity|
            report_progress(progress)
            diagnostics << foreign_source_diagnostic(entity)
            prior_source_uuid = normalized_source_uuid(entity)
            prior_origin_model_id = entity_origin_model_id(entity).to_s.downcase
            active_foreign_keys[[prior_origin_model_id, prior_source_uuid]] = true
            destination_source_uuid = assign_new_identity(
              entity,
              registry,
              source_uuids,
              entity_writes,
              uuid_generator,
              pending,
              deterministic_virtual_identities
            )
            foreign_source_provenance << ForeignSourceProvenance.new(
              source_uuid: prior_source_uuid.dup.freeze,
              origin_model_id: prior_origin_model_id.dup.freeze,
              destination_source_uuid: destination_source_uuid.dup.freeze
            ).freeze
          end
          retired_foreign_claims.each do |claim|
            key = [claim.origin_model_id, claim.source_uuid]
            next if active_foreign_keys[key]

            diagnostics << "identity.foreign_registry_claim_retired " \
                           "origin_model_id=#{claim.origin_model_id} " \
                           "source_uuid=#{claim.source_uuid}"
            foreign_source_provenance << ForeignSourceProvenance.new(
              source_uuid: claim.source_uuid,
              origin_model_id: claim.origin_model_id,
              destination_source_uuid: nil
            ).freeze
          end
          invalid.each do |entity|
            report_progress(progress)
            assign_new_identity(
              entity,
              registry,
              source_uuids,
              entity_writes,
              uuid_generator,
              pending,
              deterministic_virtual_identities
            )
          end

          model_writes = prepare_model_writes ? planned_model_writes(model, registry) : {}.freeze
          Plan.new(
            model_id: registry.model_id,
            registry: registry,
            source_uuids: source_uuids,
            entity_writes: entity_writes,
            model_writes: model_writes,
            diagnostics: diagnostics.uniq,
            foreign_source_provenance: foreign_source_provenance
          )
        end

        private

        def detected_runtime_version
          return nil unless defined?(::Sketchup) && ::Sketchup.respond_to?(:version)

          ::Sketchup.version.to_s
        end

        def validate_runtime_version!(version)
          return if version.nil? || version.to_s.empty?

          parts = version.to_s.split('.').first(2).map(&:to_i)
          parts << 0 while parts.length < 2
          return if (parts <=> MINIMUM_SKETCHUP_VERSION) >= 0

          raise UnsupportedRuntimeError.new(
            'identity.unsupported_runtime.sketchup_before_2020_1',
            "Semantic v2 identity planning requires SketchUp 2020.1 or newer; found #{version}"
          )
        end

        def validate_persistent_owners!(entities)
          unsupported = entities.find { |entity| !valid_persistent_id?(entity) }
          return if unsupported.nil?

          raise UnsupportedRuntimeError.new(
            'identity.unsupported_runtime.persistent_id_unavailable',
            "Semantic v2 identity planning requires every source owner to expose a positive persistent ID (#{unsupported.class})"
          )
        end

        def commit!(model:, plan:)
          return plan unless plan.write_required?

          model.start_operation(OPERATION_NAME, true)
          begin
            plan.send(:entity_writes).each do |write|
              write.entity.set_attribute(DICTIONARY, SOURCE_UUID_KEY, write.source_uuid)
              write.entity.set_attribute(DICTIONARY, ORIGIN_MODEL_ID_KEY, write.origin_model_id)
            end
            planned_model_writes(model, plan.registry).each do |key, value|
              model.set_attribute(DICTIONARY, key, value)
            end
            model.commit_operation
            clear_pending(model)
          rescue Exception
            model.abort_operation
            raise
          end
          plan
        end

        def load_registry(model, uuid_generator, pending, fallback_model_uuid: nil)
          raw = model.get_attribute(DICTIONARY, REGISTRY_JSON_KEY, nil)
          return IdentityRegistry.load(raw, uuid_generator: uuid_generator) unless raw.nil? || raw.to_s.strip.empty?

          model_id = model.get_attribute(DICTIONARY, MODEL_ID_KEY, nil)
          revision = model.get_attribute(DICTIONARY, REGISTRY_REVISION_KEY, 0)
          if IdentityRegistry::UUID_PATTERN.match?(model_id.to_s) && revision.is_a?(Integer) && revision >= 0
            IdentityRegistry.load(
              {
                'model_id' => model_id,
                'revision' => revision,
                'prepared_generation' => nil,
                'source_claims' => {},
                'semantic_lineage' => {}
              },
              uuid_generator: uuid_generator
            )
          elsif fallback_model_uuid
            IdentityRegistry.load(
              {
                'model_id' => fallback_model_uuid,
                'revision' => 0,
                'prepared_generation' => nil,
                'source_claims' => {},
                'semantic_lineage' => {}
              },
              uuid_generator: uuid_generator
            )
          else
            pending.model_uuid ||= allocate_uuid(uuid_generator)
            first_allocation = true
            registry_generator = lambda do
              if first_allocation
                first_allocation = false
                pending.model_uuid
              else
                uuid_generator.call
              end
            end
            IdentityRegistry.load(nil, uuid_generator: registry_generator)
          end
        end

        def pending_state_for(model)
          @pending_by_model ||= {}
          prune_dead_owners!(@pending_by_model)
          owner_key = model.__id__
          entry = @pending_by_model[owner_key]
          if same_live_owner?(entry, model)
            prune_dead_owners!(entry.value.entity_uuids)
            return entry.value
          end

          state = PendingState.new(
            model_uuid: nil,
            entity_uuids: {}
          )
          @pending_by_model[owner_key] = PendingOwner.new(
            owner_ref: WeakRef.new(model),
            value: state
          )
          state
        end

        def clear_pending(model)
          return unless @pending_by_model

          owner_key = model.__id__
          entry = @pending_by_model[owner_key]
          @pending_by_model.delete(owner_key) if same_live_owner?(entry, model)
        end

        def prune_dead_owners!(owners)
          owners.delete_if { |_key, entry| !live_owner?(entry) }
        end

        def live_owner?(entry)
          entry && entry.owner_ref.weakref_alive?
        rescue WeakRef::RefError
          false
        end

        def same_live_owner?(entry, owner)
          entry && entry.owner_ref.__getobj__.equal?(owner)
        rescue WeakRef::RefError
          false
        end

        def recursively_collect(roots, progress = nil)
          entities = []
          registered = {}
          expanded = {}
          visit_collection = nil
          register_entity = lambda do |entity|
            identity = entity.__id__
            unless registered[identity]
              registered[identity] = true
              entities << entity
              report_progress(progress)
            end
            identity
          end
          visit_entity = lambda do |entity|
            identity = register_entity.call(entity)
            return if expanded[identity]

            expanded[identity] = true
            children = entity.entities if entity.respond_to?(:entities)
            visit_collection.call(children) if children
            definition = entity.definition if entity.respond_to?(:definition)
            visit_entity.call(definition) if definition
            material = entity.material if entity.respond_to?(:material)
            visit_entity.call(material) if material
            back_material = entity.back_material if entity.respond_to?(:back_material)
            visit_entity.call(back_material) if back_material
            loops = entity.loops if entity.respond_to?(:loops)
            Array(loops).each do |loop|
              edges = loop.respond_to?(:edges) ? Array(loop.edges) : []
              edges.each do |edge|
                visit_entity.call(edge)
                next unless edge.respond_to?(:faces)

                Array(edge.faces).each { |incident_face| register_entity.call(incident_face) }
              end
            end
            if entity.respond_to?(:attached_to)
              attachment = entity.attached_to
              path = attachment.is_a?(Array) ? attachment.first : nil
              path = path.to_a if path.respond_to?(:to_a)
              Array(path).each { |path_entity| visit_entity.call(path_entity) }
            end
          end
          visit_collection = lambda do |collection|
            collection.each { |entity| visit_entity.call(entity) }
          end
          visit_collection.call(roots)
          entities
        end

        def report_progress(progress)
          progress.call('Planning source identities') if progress
        end

        def identity_roots(model, roots)
          items = Array(roots).dup
          if model.respond_to?(:active_path) && model.active_path
            active_path = model.active_path
            items.concat(active_path.respond_to?(:to_a) ? active_path.to_a : Array(active_path))
          end
          items
        end

        def valid_entity_identity?(entity, allow_missing_origin: false)
          origin_model_id = entity_origin_model_id(entity).to_s
          IdentityRegistry::UUID_PATTERN.match?(entity_source_uuid(entity).to_s) &&
            (allow_missing_origin || IdentityRegistry::UUID_PATTERN.match?(origin_model_id)) &&
            valid_persistent_id?(entity)
        end

        def valid_persistent_id?(entity)
          entity.respond_to?(:persistent_id) && entity.persistent_id.is_a?(Integer) && entity.persistent_id.positive?
        end

        def entity_source_uuid(entity)
          entity.get_attribute(DICTIONARY, SOURCE_UUID_KEY, nil)
        end

        def entity_origin_model_id(entity)
          entity.get_attribute(DICTIONARY, ORIGIN_MODEL_ID_KEY, nil)
        end

        def normalized_source_uuid(entity)
          entity_source_uuid(entity).downcase
        end

        def foreign_source_diagnostic(entity)
          "identity.foreign_source_rebased " \
            "origin_model_id=#{entity_origin_model_id(entity).to_s.downcase} " \
            "source_uuid=#{normalized_source_uuid(entity)}"
        end

        def assign_valid_claims(
          claims,
          registry,
          source_uuids,
          entity_writes,
          diagnostics,
          uuid_generator,
          pending,
          deterministic_virtual_identities
        )
          winner = if claims.length == 1
                     claims.first
                   else
                     resolution = registry.resolve_source_collision(
                       source_uuid: normalized_source_uuid(claims.first),
                       claims: claims.map { |entity| { owner_pid: entity.persistent_id } }
                     )
                     diagnostics.concat(resolution.diagnostics)
                     claims.find { |entity| entity.persistent_id == resolution.owner_pid }
                   end

          assign_preserved_identity(
            winner,
            registry,
            source_uuids,
            entity_writes,
            uuid_generator,
            pending,
            deterministic_virtual_identities
          )
          (claims - [winner]).each do |entity|
            assign_new_identity(
              entity,
              registry,
              source_uuids,
              entity_writes,
              uuid_generator,
              pending,
              deterministic_virtual_identities
            )
          end
        end

        def assign_preserved_identity(
          entity,
          registry,
          source_uuids,
          entity_writes,
          uuid_generator,
          pending,
          deterministic_virtual_identities
        )
          source_uuid = normalized_source_uuid(entity)
          origin_model_id = entity_origin_model_id(entity).to_s.downcase
          origin_model_id = registry.model_id if origin_model_id.empty?
          registry.plan_source_claim(
            source_uuid: source_uuid,
            owner_pid: entity.persistent_id,
            origin_model_id: origin_model_id
          )
          source_uuids[entity] = source_uuid.freeze
        rescue ArgumentError => error
          raise unless error.message.start_with?('source UUID already belongs')

          assign_new_identity(
            entity,
            registry,
            source_uuids,
            entity_writes,
            uuid_generator,
            pending,
            deterministic_virtual_identities
          )
        end

        def assign_new_identity(
          entity,
          registry,
          source_uuids,
          entity_writes,
          uuid_generator,
          pending,
          deterministic_virtual_identities
        )
          owner_pid = entity.persistent_id
          source_uuid = if deterministic_virtual_identities
                          deterministic_entity_uuid(registry.model_id, entity)
                        else
                          pending_uuid_for(pending, entity, uuid_generator)
                        end
          origin_model_id = registry.model_id
          registry.plan_source_claim(
            source_uuid: source_uuid,
            owner_pid: owner_pid,
            origin_model_id: origin_model_id
          )
          source_uuids[entity] = source_uuid.freeze
          entity_writes << EntityWrite.new(
            entity: entity,
            source_uuid: source_uuid.freeze,
            origin_model_id: origin_model_id.dup.freeze
          ).freeze
          source_uuid
        end

        def deterministic_model_uuid(model, entities)
          guid = stable_guid(model)
          values = if guid.empty?
                     entities.map { |entity| stable_entity_identity(entity) }.sort
                   else
                     ["guid=#{guid}"]
                   end
          deterministic_uuid('bom-engine-clean-model-v1', values)
        end

        def deterministic_entity_uuid(model_id, entity)
          deterministic_uuid(
            'bom-engine-clean-source-v1',
            [model_id, stable_entity_identity(entity)]
          )
        end

        def stable_entity_identity(entity)
          values = [
            "kind=#{entity.class.name}",
            "persistent_id=#{entity.persistent_id}"
          ]
          guid = stable_guid(entity)
          values << "guid=#{guid}" unless guid.empty?
          values.join('|')
        end

        def stable_guid(owner)
          return '' unless owner.respond_to?(:guid)

          owner.guid.to_s.strip.downcase
        rescue StandardError
          ''
        end

        def deterministic_uuid(domain, values)
          hexadecimal = Digest::SHA256.hexdigest(
            ([domain] + Array(values).map(&:to_s)).join('|')
          )[0, 32]
          hexadecimal[12] = '5'
          hexadecimal[16] = format('%x', (hexadecimal[16].to_i(16) & 0x3) | 0x8)
          [
            hexadecimal[0, 8],
            hexadecimal[8, 4],
            hexadecimal[12, 4],
            hexadecimal[16, 4],
            hexadecimal[20, 12]
          ].join('-').freeze
        end

        def pending_uuid_for(pending, entity, uuid_generator)
          owners = pending.entity_uuids
          owner_key = entity.__id__
          entry = owners[owner_key]
          return entry.value if same_live_owner?(entry, entity)

          source_uuid = allocate_uuid(uuid_generator)
          owners[owner_key] = PendingOwner.new(
            owner_ref: WeakRef.new(entity),
            value: source_uuid
          )
          source_uuid
        end

        def allocate_uuid(uuid_generator)
          value = uuid_generator.call.to_s.downcase
          raise ArgumentError, "invalid generated UUID: #{value.inspect}" unless IdentityRegistry::UUID_PATTERN.match?(value)

          value.freeze
        end

        def planned_model_writes(model, registry)
          state = registry.to_h
          desired = {
            MODEL_ID_KEY => state.fetch('model_id'),
            REGISTRY_JSON_KEY => CanonicalJSON.generate(state),
            REGISTRY_REVISION_KEY => state.fetch('revision')
          }
          desired.reject do |key, value|
            model.get_attribute(DICTIONARY, key, nil) == value
          end.freeze
        end
      end
    end
  end
end

end # SibamboHistory
