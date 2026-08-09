# frozen_string_literal: true

require_relative '../semantic_labeler'
require_relative 'snapshot'

module BOMEngine
  module SemanticV2
    # Read-only SketchUp-facing traversal that produces the internal neutral
    # snapshot. It deliberately has no dependency on reconstruction or writers.
    module Extractor
      INCH_TO_M = 0.0254
      SQUARE_INCH_TO_M2 = 0.00064516

      module_function

      def extract(model:, roots:, parent_transform:, identity_plan:, settings:, progress: nil)
        Builder.new(
          model: model,
          identity_plan: identity_plan,
          settings: settings || {},
          progress: progress
        ).extract(roots, parent_transform)
      end

      class Builder
        def initialize(model:, identity_plan:, settings:, progress:)
          @model = model
          @identity_plan = identity_plan
          @settings = settings
          @progress = progress
          @definition_data = {}
          @occurrences = []
          @pending_primitives = []
          @primitives = []
          @materials = {}
          @evidence = []
          @diagnostics = Array(identity_plan.respond_to?(:diagnostics) ? identity_plan.diagnostics : []).map(&:to_s)
          @attached_labels_by_occurrence = Hash.new { |hash, key| hash[key] = [] }
          @attached_labels_by_source = Hash.new { |hash, key| hash[key] = [] }
          @definition_attached_labels = Hash.new { |hash, key| hash[key] = [] }
          @indexed_annotation_uuids = {}
          @scope_face_keys = {}
          @eligibility_decisions = {}
          @recorded_eligibility_evidence = {}
        end

        def extract(roots, parent_transform)
          checkpoint('Extracting neutral snapshot')
          model_id = uuid(@identity_plan.model_id, 'model_id')
          root_items = Array(roots)
          context_entities = active_context_entities
          context_path = context_entities.map do |entity|
            uuid(@identity_plan.occurrence_uuid_for(entity), 'context occurrence source_uuid')
          end.freeze
          root_definition = context_entities.empty? ? nil : context_entities.last.definition
          root_definition_uuid = root_definition.nil? ? model_id : source_uuid(root_definition)
          root_kind = root_definition.nil? ? 'model' : definition_kind(root_definition)
          validate_context_roots!(root_items, root_definition, context_entities)
          @definition_data[root_definition_uuid] = { kind: root_kind, primitive_keys: [], children: [] }
          root_transform = matrix(parent_transform)
          @occurrences << Snapshot::Occurrence.new(
            uuid_path: context_path,
            definition_uuid: root_definition_uuid,
            transform: normalized_transform(root_transform)
          )
          index_direct_attached_labels(root_items)
          root_items.each do |entity|
            checkpoint('Extracting model entities')
            if face?(entity)
              extract_face(
                entity,
                definition_uuid: root_definition_uuid,
                owner_chain: [root_definition_uuid],
                label_occurrence_path: context_path
              )
            elsif instance?(entity)
              ensure_definition(entity.definition)
              emit_occurrence(entity, parent_path: context_path, parent_transform: root_transform)
            end
          end
          checkpoint('Neutral snapshot ready')
          build_document(
            model_id,
            extraction_scope(
              roots: root_items,
              context_path: context_path,
              root_definition_uuid: root_definition_uuid
            ),
            root_transform
          )
        end

        private

        def ensure_definition(definition)
          definition_uuid = source_uuid(definition)
          return definition_uuid if @definition_data.key?(definition_uuid)

          entry = {
            kind: definition_kind(definition),
            primitive_keys: [],
            children: []
          }
          @definition_data[definition_uuid] = entry
          items = Array(definition.entities)
          index_direct_attached_labels(items, definition_uuid: definition_uuid)
          items.each do |entity|
            checkpoint('Extracting definition entities')
            if face?(entity)
              extract_face(
                entity,
                definition_uuid: definition_uuid,
                owner_chain: [definition_uuid],
                label_occurrence_path: nil
              )
            elsif instance?(entity)
              entry[:children] << entity
              ensure_definition(entity.definition)
            end
          end
          definition_uuid
        end

        def emit_occurrence(entity, parent_path:, parent_transform:)
          checkpoint('Extracting component occurrences')
          occurrence_uuid = uuid(@identity_plan.occurrence_uuid_for(entity), 'occurrence source_uuid')
          path = (parent_path + [occurrence_uuid]).freeze
          definition_uuid = ensure_definition(entity.definition)
          transform = multiply_matrices(parent_transform, matrix(entity.transformation))
          decision = record_eligibility_evidence(entity, path, policy: false)
          if decision.fetch(:eligible)
            @occurrences << Snapshot::Occurrence.new(
              uuid_path: path,
              definition_uuid: definition_uuid,
              transform: normalized_transform(transform),
              material_uuid: material_uuid(entity.respond_to?(:material) ? entity.material : nil)
            )
            materialize_definition_attached_labels(definition_uuid, path)
            add_label_evidence(
              entity,
              path,
              definition_name: entity.definition.respond_to?(:name) ? entity.definition.name : nil,
              target_occurrence_path: path
            )
            @definition_data.fetch(definition_uuid).fetch(:children).each do |child|
              emit_occurrence(child, parent_path: path, parent_transform: transform)
            end
          else
            nil
          end
        end

        def extract_face(face, definition_uuid:, owner_chain:, label_occurrence_path: nil)
          checkpoint('Extracting polygon fragments')
          face_uuid = source_uuid(face)
          key = (owner_chain + [face_uuid]).freeze
          @scope_face_keys[face_uuid] = key
          decision = record_eligibility_evidence(face, key, policy: true)
          add_label_evidence(
            face,
            key,
            definition_name: nil,
            target_occurrence_path: label_occurrence_path
          )
          return unless decision.fetch(:eligible)

          hints = construction_hints(face, key)
          front_material_uuid = material_uuid(face.respond_to?(:material) ? face.material : nil)
          back_material_uuid = material_uuid(face.respond_to?(:back_material) ? face.back_material : nil)
          loops = Array(face.loops).map do |loop|
            pending_loop(loop, owner_chain, face)
          end.freeze
          @pending_primitives << {
            key: key,
            definition_uuid: definition_uuid,
            source_uuid: face_uuid,
            loops: loops,
            front_material_uuid: front_material_uuid,
            back_material_uuid: back_material_uuid,
            normal: vector(face.normal),
            area_m2: face.area.to_f * SQUARE_INCH_TO_M2,
            construction_hints: hints
          }.freeze
          @definition_data.fetch(definition_uuid).fetch(:primitive_keys) << key
          @evidence.concat(hints)
        end

        def construction_hints(owner, target_key)
          return [].freeze unless owner.respond_to?(:get_attribute)

          allowlist = setting(:construction_attribute_allowlist, {})
          unless allowlist.is_a?(Hash)
            raise ArgumentError, 'construction_attribute_allowlist must be a Hash'
          end

          owner_source_uuid = source_uuid(owner)
          missing = Object.new
          hints = []
          allowlist.keys.map(&:to_s).sort.each do |dictionary|
            keys = allowlist[dictionary] || allowlist[dictionary.to_sym]
            Array(keys).map(&:to_s).uniq.sort.each do |attribute_key|
              value = owner.get_attribute(dictionary, attribute_key, missing)
              next if value.equal?(missing)

              hints << Snapshot::ConstructionHint.new(
                target_key: target_key,
                source_uuid: owner_source_uuid,
                dictionary: dictionary,
                attribute_key: attribute_key,
                value: value
              )
            end
          end
          hints.freeze
        end

        def pending_loop(loop, owner_chain, owning_face)
          vertices = Array(loop.vertices).map do |vertex|
            point(vertex.position)
          end.freeze
          edges = loop.respond_to?(:edges) ? Array(loop.edges) : []
          owning_key = (owner_chain + [source_uuid(owning_face)]).freeze
          pending_edges = edges.map do |edge|
            {
              source_uuid: source_uuid(edge),
              adjacent_faces: if edge.respond_to?(:faces)
                                Array(edge.faces).reject { |face| face.equal?(owning_face) }.freeze
                              else
                                [].freeze
                              end
            }.freeze
          end.freeze
          {
            kind: loop.respond_to?(:outer?) && loop.outer? ? 'outer' : 'hole',
            vertices: vertices,
            owning_key: owning_key,
            edges: pending_edges
          }.freeze
        end

        def materialize_loop(pending)
          adjacent_keys = pending.fetch(:edges).flat_map do |edge|
            edge.fetch(:adjacent_faces).each_with_object([]) do |face, keys|
              adjacent_uuid = source_uuid(face)
              adjacent_key = @scope_face_keys[adjacent_uuid]
              if adjacent_key && eligibility_decision(face, policy: true).fetch(:eligible)
                keys << adjacent_key
              else
                @evidence << Snapshot::AdjacencyBoundary.new(
                  target_key: pending.fetch(:owning_key),
                  edge_source_uuid: edge.fetch(:source_uuid),
                  adjacent_source_uuid: adjacent_uuid,
                  boundary_type: adjacent_key ? 'excluded_adjacency' : 'out_of_scope_adjacency'
                )
              end
            end
          end.uniq.freeze
          Snapshot::Loop.new(
            kind: pending.fetch(:kind),
            vertices: pending.fetch(:vertices),
            edge_source_uuids: pending.fetch(:edges).map { |edge| edge.fetch(:source_uuid) }.freeze,
            adjacent_primitive_keys: adjacent_keys
          )
        end

        def materialize_primitive(pending)
          Snapshot::PolygonFragment.new(
            key: pending.fetch(:key),
            definition_uuid: pending.fetch(:definition_uuid),
            source_uuid: pending.fetch(:source_uuid),
            loops: pending.fetch(:loops).map { |loop| materialize_loop(loop) }.freeze,
            front_material_uuid: pending.fetch(:front_material_uuid),
            back_material_uuid: pending.fetch(:back_material_uuid),
            normal: pending.fetch(:normal),
            area_m2: pending.fetch(:area_m2),
            construction_hints: pending.fetch(:construction_hints)
          )
        end

        def material_uuid(material)
          return nil if material.nil?

          color = material.respond_to?(:color) ? material.color : nil
          rgba = [
            color_channel(color, :red, :r),
            color_channel(color, :green, :g),
            color_channel(color, :blue, :b),
            alpha_channel(material, color)
          ].freeze
          texture = texture_hint(material.respond_to?(:texture) ? material.texture : nil)
          material_source_uuid = source_uuid(material)
          return material_source_uuid if @materials.key?(material_source_uuid)

          @materials[material_source_uuid] = Snapshot::Material.new(
            source_uuid: material_source_uuid,
            name: material.respond_to?(:name) ? material.name : '',
            rgba: rgba,
            texture: texture
          )
          material_source_uuid
        end

        def texture_hint(texture)
          return nil if texture.nil?

          {
            filename: (texture.respond_to?(:filename) ? texture.filename.to_s.dup.freeze : nil),
            width_m: (texture.respond_to?(:width) ? texture.width.to_f * INCH_TO_M : nil),
            height_m: (texture.respond_to?(:height) ? texture.height.to_f * INCH_TO_M : nil)
          }.freeze
        end

        def color_channel(color, primary, fallback)
          value = if color&.respond_to?(primary)
                    color.public_send(primary)
                  elsif color&.respond_to?(fallback)
                    color.public_send(fallback)
                  else
                    0
                  end
          [[value.to_i, 0].max, 255].min
        end

        def alpha_channel(material, color)
          value = if color&.respond_to?(:alpha)
                    color.alpha
                  elsif material.respond_to?(:alpha)
                    material.alpha
                  else
                    255
                  end
          value = value.to_f * 255.0 if value.to_f.between?(0.0, 1.0)
          [[value.round, 0].max, 255].min
        end

        def index_direct_attached_labels(items, definition_uuid: nil)
          items.each do |entity|
            next unless text?(entity)

            annotation_source_uuid = source_uuid(entity)
            next if @indexed_annotation_uuids[annotation_source_uuid]

            @indexed_annotation_uuids[annotation_source_uuid] = true
            attached = entity.respond_to?(:attached_to) ? entity.attached_to : nil
            path = attached.is_a?(Array) ? attached.first : nil
            path = path.to_a if path.respond_to?(:to_a)
            path_entities = Array(path)
            label = SemanticLabeler.clean(entity.text)
            next if path_entities.empty? || label.empty?

            candidate = {
              value: label.dup.freeze,
              annotation_source_uuid: annotation_source_uuid.dup.freeze
            }.freeze
            occurrence_entities = path_entities.select { |candidate_entity| instance?(candidate_entity) }
            if definition_uuid
              relative_path = occurrence_entities.map do |instance|
                uuid(@identity_plan.occurrence_uuid_for(instance), 'attached target occurrence source_uuid')
              end.freeze
              @definition_attached_labels[definition_uuid] << {
                relative_occurrence_uuid_path: relative_path,
                target_source_uuid: occurrence_entities.empty? ? source_uuid(path_entities.last) : nil,
                candidate: candidate
              }.freeze
            elsif occurrence_entities.empty?
              target_source_uuid = source_uuid(path_entities.last)
              @attached_labels_by_source[target_source_uuid] << candidate
            else
              target_path = occurrence_entities.map do |instance|
                uuid(@identity_plan.occurrence_uuid_for(instance), 'attached target occurrence source_uuid')
              end.freeze
              @attached_labels_by_occurrence[target_path] << candidate
            end
          end
        rescue KeyError
          raise
        rescue StandardError => error
          @diagnostics << "attached_label.#{error.class}"
        end

        def materialize_definition_attached_labels(definition_uuid, occurrence_path)
          records = @definition_attached_labels[definition_uuid]
          direct = Hash.new { |hash, key| hash[key] = [] }
          records.each do |record|
            relative_path = record.fetch(:relative_occurrence_uuid_path)
            if relative_path.empty?
              direct[record.fetch(:target_source_uuid)] << record.fetch(:candidate)
            else
              target_path = (occurrence_path + relative_path).freeze
              @attached_labels_by_occurrence[target_path] << record.fetch(:candidate)
            end
          end
          direct.each do |target_source_uuid, candidates|
            add_attached_label_evidence(
              target_key: [definition_uuid, target_source_uuid].freeze,
              target_occurrence_path: occurrence_path,
              attached_labels: sorted_attached_labels(candidates)
            )
          end
        end

        def add_label_evidence(entity, target_key, definition_name:, target_occurrence_path: nil)
          target_kind = face?(entity) ? 'primitive' : 'occurrence'
          attached_labels = attached_label_candidates(entity, target_occurrence_path)
          semantic = SemanticLabeler.build(
            instance_name: entity.respond_to?(:name) ? entity.name : '',
            definition_name: definition_name,
            tag_name: tag_name(entity),
            attached_labels: attached_labels
          )
          unless semantic[:label].nil?
            if semantic[:source] == 'attached_text'
              append_attached_labels(
                target_key: target_key,
                target_occurrence_path: target_occurrence_path,
                attached_labels: attached_labels,
                semantic: semantic,
                target_kind: target_kind
              )
            else
              @evidence << Snapshot::LabelEvidence.new(
                target_key: target_key,
                label: semantic[:label],
                source: semantic[:source],
                role: nil,
                classification_policy: semantic[:classification_policy],
                aliases: frozen_texts(semantic[:aliases]),
                explicit: true,
                target_occurrence_uuid_path: target_occurrence_path,
                primary: true,
                target_kind: target_kind
              )
            end
          end
          return if semantic[:role].nil?

          @evidence << Snapshot::LabelEvidence.new(
            target_key: target_key,
            label: nil,
            source: 'role_inference',
            role: semantic[:role],
            classification_policy: semantic[:classification_policy],
            aliases: [].freeze,
            explicit: false,
            target_occurrence_uuid_path: target_occurrence_path,
            primary: false,
            target_kind: target_kind
          )
        end

        def add_attached_label_evidence(target_key:, target_occurrence_path:, attached_labels:)
          return if attached_labels.empty?

          semantic = SemanticLabeler.build(
            instance_name: '',
            definition_name: nil,
            tag_name: nil,
            attached_labels: attached_labels
          )
          append_attached_labels(
            target_key: target_key,
            target_occurrence_path: target_occurrence_path,
            attached_labels: attached_labels,
            semantic: semantic,
            target_kind: 'primitive'
          )
          return if semantic[:role].nil?

          @evidence << Snapshot::LabelEvidence.new(
            target_key: target_key,
            label: nil,
            source: 'role_inference',
            role: semantic[:role],
            classification_policy: semantic[:classification_policy],
            aliases: [].freeze,
            explicit: false,
            target_occurrence_uuid_path: target_occurrence_path,
            primary: false,
            target_kind: 'primitive'
          )
        end

        def append_attached_labels(target_key:, target_occurrence_path:, attached_labels:, semantic:,
                                   target_kind:)
          accepted = attached_labels.select do |candidate|
            semantic[:aliases].any? { |label| label.casecmp?(candidate.fetch(:value)) }
          end
          accepted.each_with_index do |candidate, index|
            @evidence << Snapshot::LabelEvidence.new(
              target_key: target_key,
              label: candidate.fetch(:value),
              source: 'attached_text',
              role: nil,
              classification_policy: semantic[:classification_policy],
              aliases: index.zero? ? frozen_texts(semantic[:aliases]) : [].freeze,
              explicit: true,
              annotation_source_uuid: candidate.fetch(:annotation_source_uuid),
              target_occurrence_uuid_path: target_occurrence_path,
              primary: index.zero?,
              target_kind: target_kind
            )
          end
        end

        def attached_label_candidates(entity, target_occurrence_path)
          candidates = []
          candidates.concat(@attached_labels_by_occurrence[target_occurrence_path]) unless target_occurrence_path.nil?
          if target_occurrence_path.nil? || face?(entity)
            candidates.concat(@attached_labels_by_source[source_uuid(entity)])
          end
          sorted_attached_labels(candidates)
        end

        def sorted_attached_labels(candidates)
          # Persistent annotation UUID is the stable precedence tie-break;
          # neither roots order nor definition traversal may choose a label.
          candidates.sort_by do |candidate|
            [candidate.fetch(:annotation_source_uuid), candidate.fetch(:value)]
          end
        end

        def frozen_texts(values)
          Array(values).map { |item| item.to_s.dup.freeze }.freeze
        end

        def tag_name(entity)
          tag = entity.respond_to?(:layer) ? entity.layer : nil
          tag.respond_to?(:name) ? tag.name : nil
        end

        def record_eligibility_evidence(entity, target_key, policy:)
          decision = eligibility_decision(entity, policy: policy)
          evidence_key = [target_key, policy].freeze
          return decision if @recorded_eligibility_evidence[evidence_key]

          @recorded_eligibility_evidence[evidence_key] = true
          observation = decision.fetch(:visibility)
          target_kind = policy ? 'primitive' : 'occurrence'
          entity_source_uuid = source_uuid(entity)
          @evidence << Snapshot::VisibilityEvidence.new(
            target_key: target_key,
            target_kind: target_kind,
            source_uuid: entity_source_uuid,
            hidden: observation.fetch(:hidden),
            visible: observation.fetch(:visible),
            tag_visible: observation.fetch(:tag_visible)
          )
          @evidence << Snapshot::ExclusionEvidence.new(
            target_key: target_key,
            target_kind: target_kind,
            source_uuid: entity_source_uuid,
            eligible: decision.fetch(:eligible),
            excluded: !decision.fetch(:eligible),
            reasons: decision.fetch(:reasons),
            rule_ids: decision.fetch(:rule_ids)
          )
          decision
        end

        def eligibility_decision(entity, policy:)
          cache_key = [source_uuid(entity), policy].freeze
          cached = @eligibility_decisions[cache_key]
          return cached unless cached.nil?

          observation = visibility_observation(entity)
          exclusions = []
          unless setting(:include_hidden, false)
            if observation.fetch(:hidden) == true
              exclusions << ['visibility.entity_hidden', 'hidden']
            elsif observation.fetch(:visible) == false
              exclusions << ['visibility.entity_not_visible', 'not_visible']
            end
            if observation.fetch(:tag_visible) == false
              exclusions << ['visibility.tag_hidden', 'hidden_tag']
            end
          end
          exclusions.concat(policy_exclusions(entity)) if policy
          exclusions = exclusions.uniq.sort_by { |rule_id, reason| [rule_id, reason] }
          decision = {
            eligible: exclusions.empty?,
            reasons: exclusions.map { |_rule_id, reason| reason.to_s.dup.freeze }.freeze,
            rule_ids: exclusions.map { |rule_id, _reason| rule_id.to_s.dup.freeze }.freeze,
            visibility: observation
          }.freeze
          @eligibility_decisions[cache_key] = decision
          decision
        end

        def visibility_observation(entity)
          layer = entity.respond_to?(:layer) ? entity.layer : nil
          {
            hidden: entity.respond_to?(:hidden?) ? !!entity.hidden? : nil,
            visible: entity.respond_to?(:visible?) ? !!entity.visible? : nil,
            tag_visible: layer&.respond_to?(:visible?) ? !!layer.visible? : nil
          }.freeze
        end

        def policy_exclusions(entity)
          face_policy = setting(:face_policy, nil)
          return [] unless face_policy.respond_to?(:call)

          outcome = face_policy.call(entity)
          return [] if outcome == true || (outcome.is_a?(Hash) && policy_eligible?(outcome))

          rule_id = if outcome.is_a?(Hash)
                      outcome[:rule_id] || outcome['rule_id']
                    else
                      setting(:face_policy_rule_id, nil)
                    end
          reason = if outcome.is_a?(Hash)
                     outcome[:reason] || outcome['reason'] || 'policy_excluded'
                   else
                     'policy_excluded'
                   end
          if rule_id.nil? || rule_id.to_s.empty?
            raise ArgumentError, 'excluded face policy decisions require a stable rule ID'
          end

          [[rule_id.to_s, reason.to_s]]
        end

        def policy_eligible?(outcome)
          value = outcome.key?(:eligible) ? outcome[:eligible] : outcome['eligible']
          value == true
        end

        def build_document(model_id, scope, context_transform)
          @primitives = @pending_primitives.map do |pending|
            checkpoint('Finalizing polygon fragments')
            materialize_primitive(pending)
          end
          definitions = @definition_data.map do |definition_uuid, entry|
            checkpoint('Finalizing extracted definitions')
            Snapshot::Definition.new(
              source_uuid: definition_uuid,
              kind: entry.fetch(:kind),
              primitive_keys: entry.fetch(:primitive_keys).sort.freeze
            )
          end.sort_by(&:source_uuid).freeze
          checkpoint('Sorting snapshot occurrences')
          occurrences = @occurrences.sort_by(&:uuid_path).freeze
          checkpoint('Sorting snapshot primitives')
          primitives = @primitives.sort_by(&:key).freeze
          checkpoint('Sorting snapshot materials')
          materials = @materials.values.sort_by(&:source_uuid).freeze
          labels = []
          other_evidence = []
          @evidence.each do |item|
            checkpoint('Indexing snapshot evidence')
            if item.is_a?(Snapshot::LabelEvidence)
              labels << item
            else
              other_evidence << item
            end
          end
          checkpoint('Sorting snapshot labels')
          labels.sort_by! do |item|
            [
              item.target_key,
              item.target_kind.to_s,
              Array(item.target_occurrence_uuid_path),
              item.source.to_s,
              item.annotation_source_uuid.to_s,
              item.label.to_s
            ]
          end
          evidence = (labels + other_evidence).freeze
          Snapshot::Document.new(
            model_id: model_id,
            scope: scope,
            model_context: Snapshot::ModelContext.new(
              true_north_xy: true_north_xy,
              context_transform: normalized_transform(context_transform)
            ),
            occurrences: occurrences,
            definitions: definitions,
            primitives: primitives,
            materials: materials,
            evidence: evidence,
            foreign_source_provenance: foreign_source_provenance,
            diagnostics: @diagnostics.uniq.sort.map(&:freeze).freeze,
            progress: @progress
          )
        end

        def true_north_xy
          degrees = setting(:true_north_degrees, nil)
          if degrees.nil? && @model.respond_to?(:shadow_info)
            shadow_info = @model.shadow_info
            if shadow_info.respond_to?(:[])
              degrees = shadow_info['NorthAngle']
              degrees = shadow_info[:NorthAngle] if degrees.nil?
            end
          end
          radians = (degrees || 0.0).to_f * Math::PI / 180.0
          [Math.sin(radians).round(12), Math.cos(radians).round(12)].freeze
        end

        def foreign_source_provenance
          values = if @identity_plan.respond_to?(:foreign_source_provenance)
                     Array(@identity_plan.foreign_source_provenance)
                   else
                     []
                   end
          values.map do |item|
            Snapshot::ForeignSourceProvenance.new(
              source_uuid: item.source_uuid,
              origin_model_id: item.origin_model_id,
              destination_source_uuid: item.destination_source_uuid
            )
          end.sort_by do |item|
            [item.origin_model_id, item.source_uuid, item.destination_source_uuid.to_s]
          end.freeze
        end

        def active_context_entities
          path = setting(:context_path, nil)
          path = @model.active_path if path.nil? && @model.respond_to?(:active_path)
          return [] if path.nil?

          path.respond_to?(:to_a) ? path.to_a : Array(path)
        end

        def extraction_scope(roots:, context_path:, root_definition_uuid:)
          root_source_uuids = roots.map { |entity| source_uuid(entity) }
          if root_source_uuids.uniq.length != root_source_uuids.length
            raise ArgumentError, 'duplicate extraction roots are not allowed'
          end
          root_source_uuids = root_source_uuids.sort.freeze
          mode = setting(:scope_mode, nil)
          mode = full_model_roots?(roots) ? 'model' : 'selection' if mode.nil?
          if mode.to_s == 'model'
            raise ArgumentError, 'model scope requires an empty context' unless context_path.empty?
            unless root_definition_uuid == @identity_plan.model_id
              raise ArgumentError, 'model scope requires model root definition ownership'
            end
            unless full_model_roots?(roots)
              raise ArgumentError, 'model scope requires all model roots exactly once'
            end
          end
          extraction_policy_id = setting(:extraction_policy_id, nil)
          if setting(:face_policy, nil).respond_to?(:call) &&
             (extraction_policy_id.nil? || extraction_policy_id.to_s.empty?)
            raise ArgumentError, 'callable face policy requires extraction_policy_id'
          end
          Snapshot::ExtractionScope.new(
            mode: mode,
            root_source_uuids: root_source_uuids,
            context_occurrence_uuid_path: context_path,
            root_definition_uuid: root_definition_uuid,
            extraction_policy_id: extraction_policy_id,
            reconstruction_policy_id: setting(:reconstruction_policy_id, nil)
          )
        end

        def full_model_roots?(roots)
          return false unless @model.respond_to?(:entities)

          model_roots = Array(@model.entities)
          roots.length == model_roots.length &&
            roots.uniq.length == roots.length &&
            model_roots.uniq.length == model_roots.length &&
            (roots - model_roots).empty? &&
            (model_roots - roots).empty?
        end

        def validate_context_roots!(roots, root_definition, active_path_entities)
          return if root_definition.nil?

          context_entities = Array(root_definition.entities)
          invalid = roots.reject do |entity|
            context_entities.include?(entity) ||
              valid_external_context_annotation?(
                entity,
                active_path_entities,
                context_entities
              )
          end
          return if invalid.empty?

          raise ArgumentError, 'active-context roots must belong to the edited definition'
        end

        def valid_external_context_annotation?(entity, active_path_entities, context_entities)
          return false unless text?(entity)

          attached = entity.respond_to?(:attached_to) ? entity.attached_to : nil
          path = attached.is_a?(Array) ? attached.first : nil
          path = path.to_a if path.respond_to?(:to_a)
          path_entities = Array(path)
          prefix_length = active_path_entities.length
          return false unless path_entities.first(prefix_length) == active_path_entities

          relative_root = path_entities[prefix_length]
          !relative_root.nil? && context_entities.include?(relative_root)
        rescue StandardError
          false
        end

        def face?(entity)
          entity.respond_to?(:loops) && entity.respond_to?(:normal) && entity.respond_to?(:area)
        end

        def definition_kind(definition)
          return 'group' if definition.respond_to?(:group?) && definition.group?
          return definition.kind.to_s if definition.respond_to?(:kind)

          'component'
        end

        def instance?(entity)
          entity.respond_to?(:definition) && entity.respond_to?(:transformation)
        end

        def text?(entity)
          entity.respond_to?(:text) && entity.respond_to?(:attached_to)
        end

        def source_uuid(entity)
          uuid(@identity_plan.source_uuid_for(entity), 'source_uuid')
        end

        def optional_source_uuid(entity)
          source_uuid(entity)
        rescue KeyError
          nil
        end

        def uuid(value, field)
          Snapshot::Validation.uuid(value, field)
        end

        def vector(value)
          [coordinate(value, 0, :x), coordinate(value, 1, :y), coordinate(value, 2, :z)].freeze
        end

        def point(value)
          vector(value).map { |coordinate_value| coordinate_value * INCH_TO_M }.freeze
        end

        def coordinate(value, index, method)
          if value.respond_to?(method)
            value.public_send(method).to_f
          else
            Array(value).fetch(index).to_f
          end
        end

        def matrix(value)
          values = if value.nil?
                     identity_matrix
                   elsif value.respond_to?(:to_a)
                     value.to_a
                   else
                     Array(value)
                   end
          raise ArgumentError, 'transformation must contain 16 values' unless values.length == 16

          values.map(&:to_f)
        end

        def identity_matrix
          [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0
          ]
        end

        def multiply_matrices(left, right)
          Array.new(16) do |index|
            column = index / 4
            row = index % 4
            4.times.sum { |inner| left[inner * 4 + row] * right[column * 4 + inner] }
          end
        end

        def normalized_transform(value)
          value.each_with_index.map do |item, index|
            translation_index = [12, 13, 14].include?(index)
            normalized = translation_index ? item * INCH_TO_M : item
            normalized.round(12)
          end.freeze
        end

        def setting(name, fallback)
          @settings.fetch(name) { @settings.fetch(name.to_s, fallback) }
        end

        def checkpoint(message)
          return if @progress.nil?

          if @progress.respond_to?(:call)
            @progress.call(message)
          elsif @progress.respond_to?(:update)
            @progress.update(message)
          end
        end
      end
    end
  end
end
