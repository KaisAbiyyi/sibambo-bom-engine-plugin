# frozen_string_literal: true

require_relative 'identity_registry'

module BOMEngine
  module SemanticV2
    # Private, format-neutral extraction records. These values intentionally do
    # not expose a Hash/JSON conversion API; reconstruction owns interpretation.
    module Snapshot
      module Validation
        module_function

        UUID_PATTERN = IdentityRegistry::UUID_PATTERN

        def uuid(value, field)
          text = value.to_s.downcase
          raise ArgumentError, "#{field} must be a UUID" unless UUID_PATTERN.match?(text)

          text.freeze
        end

        def uuid_path(value, field)
          frozen_array(value, field)
          value.map.with_index { |item, index| uuid(item, "#{field}[#{index}]") }.freeze
        end

        def definition_local_primitive_key(value, definition_uuid:, source_uuid: nil, field: 'primitive key')
          key = uuid_path(value, field)
          unless key.length == 2 && key.first == definition_uuid &&
                 (source_uuid.nil? || key.last == source_uuid)
            raise ArgumentError,
                  "#{field} must be a definition-local primitive key [definition_uuid, source_uuid]"
          end

          key
        end

        def frozen_array(value, field)
          raise ArgumentError, "#{field} must be frozen Array" unless value.is_a?(Array) && value.frozen?

          value
        end

        def immutable_copy(value, field)
          case value
          when Array
            value.map.with_index { |item, index| immutable_copy(item, "#{field}[#{index}]") }.freeze
          when Hash
            value.each_with_object({}) do |(key, item), copy|
              immutable_key = immutable_copy(key, "#{field} key")
              copy[immutable_key] = immutable_copy(item, "#{field}[#{key}]")
            end.freeze
          when String
            value.dup.freeze
          when NilClass, TrueClass, FalseClass, Symbol, Integer
            value
          when Float
            raise ArgumentError, "#{field} must be finite" unless value.finite?

            value
          else
            raise ArgumentError, "unsupported snapshot value for #{field}: #{value.class}"
          end
        end

        def text(value)
          value.nil? ? nil : value.to_s.dup.freeze
        end

        def finite_number(value, field)
          number = Float(value)
          raise ArgumentError, "#{field} must be finite" unless number.finite?

          number
        rescue TypeError, ArgumentError
          raise ArgumentError, "#{field} must be finite"
        end

        def point(value, field)
          frozen_array(value, field)
          raise ArgumentError, "#{field} must contain three coordinates" unless value.length == 3

          value.map.with_index { |item, index| finite_number(item, "#{field}[#{index}]") }.freeze
        end
      end

      class Definition
        attr_reader :source_uuid, :kind, :primitive_keys

        def initialize(source_uuid:, kind:, primitive_keys:)
          @source_uuid = Validation.uuid(source_uuid, 'definition source_uuid')
          @kind = Validation.text(kind)
          Validation.frozen_array(primitive_keys, 'primitive_keys')
          @primitive_keys = primitive_keys.map.with_index do |key, index|
            Validation.definition_local_primitive_key(
              key,
              definition_uuid: @source_uuid,
              field: "primitive_keys[#{index}]"
            )
          end.freeze
          freeze
        end
      end

      class Occurrence
        attr_reader :uuid_path, :definition_uuid, :transform, :material_uuid

        def initialize(uuid_path:, definition_uuid:, transform:, material_uuid: nil)
          @uuid_path = Validation.uuid_path(uuid_path, 'uuid_path')
          @definition_uuid = Validation.uuid(definition_uuid, 'definition_uuid')
          Validation.frozen_array(transform, 'transform')
          raise ArgumentError, 'transform must contain 16 values' unless transform.length == 16

          @transform = transform.map.with_index do |item, index|
            Validation.finite_number(item, "transform[#{index}]")
          end.freeze
          @material_uuid = material_uuid && Validation.uuid(material_uuid, 'material_uuid')
          freeze
        end
      end

      class ExtractionScope
        MODES = %w[model selection].freeze
        RECONSTRUCTION_POLICY_ID = 'bom-semantic-reconstruction/1.0.0'.freeze

        attr_reader :mode, :root_source_uuids, :context_occurrence_uuid_path,
                    :root_definition_uuid, :extraction_policy_id,
                    :reconstruction_policy_id

        def initialize(mode:, root_source_uuids:, context_occurrence_uuid_path:,
                       root_definition_uuid:, extraction_policy_id: nil,
                       reconstruction_policy_id: nil)
          @mode = Validation.text(mode)
          raise ArgumentError, 'scope mode must be model or selection' unless MODES.include?(@mode)

          @root_source_uuids = Validation.uuid_path(root_source_uuids, 'root_source_uuids').sort.freeze
          if @root_source_uuids.uniq.length != @root_source_uuids.length
            raise ArgumentError, 'root_source_uuids must be unique'
          end
          @context_occurrence_uuid_path = Validation.uuid_path(
            context_occurrence_uuid_path,
            'context_occurrence_uuid_path'
          )
          @root_definition_uuid = Validation.uuid(root_definition_uuid, 'root_definition_uuid')
          @extraction_policy_id = optional_policy_id(extraction_policy_id, 'extraction_policy_id')
          @reconstruction_policy_id = optional_policy_id(
            reconstruction_policy_id,
            'reconstruction_policy_id'
          )
          if @reconstruction_policy_id &&
             @reconstruction_policy_id != RECONSTRUCTION_POLICY_ID
            raise ArgumentError,
                  "reconstruction_policy_id must be #{RECONSTRUCTION_POLICY_ID}"
          end
          freeze
        end

        private

        def optional_policy_id(value, field)
          return nil if value.nil?

          text = Validation.text(value)
          raise ArgumentError, "#{field} cannot be empty" if text.empty?

          text
        end
      end

      class ModelContext
        attr_reader :true_north_xy, :context_transform

        def initialize(true_north_xy:, context_transform:)
          Validation.frozen_array(true_north_xy, 'true_north_xy')
          raise ArgumentError, 'true_north_xy must contain two coordinates' unless true_north_xy.length == 2

          @true_north_xy = true_north_xy.map.with_index do |item, index|
            Validation.finite_number(item, "true_north_xy[#{index}]")
          end.freeze
          magnitude = Math.sqrt(@true_north_xy[0]**2 + @true_north_xy[1]**2)
          unless (magnitude - 1.0).abs <= 1.0e-9
            raise ArgumentError, 'true_north_xy must be normalized'
          end

          Validation.frozen_array(context_transform, 'context_transform')
          unless context_transform.length == 16
            raise ArgumentError, 'context_transform must contain 16 values'
          end
          @context_transform = context_transform.map.with_index do |item, index|
            Validation.finite_number(item, "context_transform[#{index}]")
          end.freeze
          freeze
        end
      end

      class ForeignSourceProvenance
        attr_reader :source_uuid, :origin_model_id, :destination_source_uuid

        def initialize(source_uuid:, origin_model_id:, destination_source_uuid: nil)
          @source_uuid = Validation.uuid(source_uuid, 'foreign source_uuid')
          @origin_model_id = Validation.uuid(origin_model_id, 'foreign origin_model_id')
          @destination_source_uuid = destination_source_uuid && Validation.uuid(
            destination_source_uuid,
            'foreign destination_source_uuid'
          )
          freeze
        end
      end

      class Loop
        attr_reader :kind, :vertices, :edge_source_uuids, :adjacent_primitive_keys

        def initialize(kind:, vertices:, edge_source_uuids:, adjacent_primitive_keys:)
          @kind = Validation.text(kind)
          raise ArgumentError, 'loop kind must be outer or hole' unless %w[outer hole].include?(@kind)

          Validation.frozen_array(vertices, 'vertices')
          raise ArgumentError, 'loop must contain at least three vertices' if vertices.length < 3
          @vertices = vertices.map.with_index { |point, index| Validation.point(point, "vertices[#{index}]") }.freeze
          Validation.frozen_array(edge_source_uuids, 'edge_source_uuids')
          @edge_source_uuids = edge_source_uuids.map.with_index do |uuid, index|
            Validation.uuid(uuid, "edge_source_uuids[#{index}]")
          end.freeze
          unless @edge_source_uuids.length == @vertices.length
            raise ArgumentError, 'loop requires one source UUID per edge segment'
          end
          Validation.frozen_array(adjacent_primitive_keys, 'adjacent_primitive_keys')
          @adjacent_primitive_keys = adjacent_primitive_keys.map.with_index do |key, index|
            Validation.uuid_path(key, "adjacent_primitive_keys[#{index}]")
          end.freeze
          freeze
        end
      end

      class PolygonFragment
        attr_reader :key, :definition_uuid, :source_uuid, :loops,
                    :front_material_uuid, :back_material_uuid, :normal,
                    :area_m2, :construction_hints

        def initialize(key:, definition_uuid:, source_uuid:, loops:, front_material_uuid:,
                       back_material_uuid:, normal:, area_m2:, construction_hints:)
          @definition_uuid = Validation.uuid(definition_uuid, 'definition_uuid')
          @source_uuid = Validation.uuid(source_uuid, 'source_uuid')
          @key = Validation.definition_local_primitive_key(
            key,
            definition_uuid: @definition_uuid,
            source_uuid: @source_uuid
          )

          Validation.frozen_array(loops, 'loops')
          raise ArgumentError, 'polygon fragment requires one outer loop' unless loops.count { |loop| loop.kind == 'outer' } == 1
          raise ArgumentError, 'loops must contain Loop records' unless loops.all? { |loop| loop.is_a?(Loop) && loop.frozen? }
          @loops = loops.dup.freeze
          @front_material_uuid = front_material_uuid && Validation.uuid(front_material_uuid, 'front_material_uuid')
          @back_material_uuid = back_material_uuid && Validation.uuid(back_material_uuid, 'back_material_uuid')
          @normal = Validation.point(normal, 'normal')
          @area_m2 = Validation.finite_number(area_m2, 'area_m2')
          raise ArgumentError, 'area_m2 cannot be negative' if @area_m2.negative?

          Validation.frozen_array(construction_hints, 'construction_hints')
          raise ArgumentError, 'construction_hints must contain ConstructionHint records' unless construction_hints.all? { |hint| hint.is_a?(ConstructionHint) && hint.frozen? }
          @construction_hints = construction_hints.dup.freeze
          freeze
        end
      end


      def self.occurrence_fragment_key(occurrence:, primitive:)
        unless occurrence.is_a?(Occurrence) && primitive.is_a?(PolygonFragment)
          raise ArgumentError, 'occurrence fragment ownership requires occurrence and polygon records'
        end
        unless occurrence.definition_uuid == primitive.definition_uuid
          raise ArgumentError, 'unresolved occurrence fragment definition ownership'
        end

        (occurrence.uuid_path + primitive.key).freeze
      end

      class Material
        attr_reader :source_uuid, :name, :rgba, :texture

        def initialize(source_uuid:, name:, rgba:, texture:)
          @source_uuid = Validation.uuid(source_uuid, 'material source_uuid')
          @name = Validation.text(name)
          Validation.frozen_array(rgba, 'rgba')
          unless rgba.length == 4 && rgba.all? { |channel| channel.is_a?(Integer) && channel.between?(0, 255) }
            raise ArgumentError, 'rgba must contain four byte values'
          end
          @rgba = rgba.dup.freeze
          @texture = Validation.immutable_copy(texture, 'texture') unless texture.nil?
          freeze
        end
      end

      class ConstructionHint
        attr_reader :target_key, :source_uuid, :dictionary, :attribute_key, :value

        def initialize(target_key:, source_uuid:, dictionary:, attribute_key:, value:)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          @source_uuid = Validation.uuid(source_uuid, 'construction source_uuid')
          @dictionary = Validation.text(dictionary)
          @attribute_key = Validation.text(attribute_key)
          raise ArgumentError, 'construction dictionary cannot be empty' if @dictionary.empty?
          raise ArgumentError, 'construction attribute key cannot be empty' if @attribute_key.empty?
          @value = Validation.immutable_copy(value, 'value')
          freeze
        end
      end

      class LabelEvidence
        attr_reader :target_key, :label, :source, :role,
                     :classification_policy, :aliases, :explicit,
                     :annotation_source_uuid, :target_occurrence_uuid_path,
                     :primary, :target_kind

        def initialize(target_key:, label:, source:, role:, classification_policy:, aliases:, explicit:,
                       annotation_source_uuid: nil, target_occurrence_uuid_path: nil,
                       primary: true, target_kind:)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          @target_kind = evidence_target_kind(target_kind)
          @label = Validation.text(label)
          @source = Validation.text(source)
          @role = Validation.text(role)
          @classification_policy = Validation.text(classification_policy)
          Validation.frozen_array(aliases, 'aliases')
          @aliases = aliases.map { |alias_value| Validation.text(alias_value) }.freeze
          raise ArgumentError, 'explicit must be true or false' unless explicit == true || explicit == false
          @explicit = explicit
          @annotation_source_uuid = annotation_source_uuid && Validation.uuid(
            annotation_source_uuid,
            'annotation_source_uuid'
          )
          @target_occurrence_uuid_path = if target_occurrence_uuid_path.nil?
                                           nil
                                         else
                                           Validation.uuid_path(
                                             target_occurrence_uuid_path,
                                             'target_occurrence_uuid_path'
                                           )
                                          end
          if @source == 'attached_text' &&
             (@annotation_source_uuid.nil? || @target_occurrence_uuid_path.nil?)
            raise ArgumentError,
                  'attached_text evidence requires annotation source UUID and target occurrence path'
          end
          raise ArgumentError, 'primary must be true or false' unless primary == true || primary == false
          @primary = primary
          freeze
        end

        private

        def evidence_target_kind(value)
          kind = Validation.text(value)
          return kind if %w[occurrence primitive].include?(kind)

          raise ArgumentError, 'label target_kind must be occurrence or primitive'
        end
      end

      class VisibilityEvidence
        attr_reader :target_key, :target_kind, :source_uuid,
                    :hidden, :visible, :tag_visible, :observed_visible

        def initialize(target_key:, target_kind:, source_uuid:, hidden:, visible:, tag_visible:)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          @target_kind = evidence_target_kind(target_kind)
          @source_uuid = Validation.uuid(source_uuid, 'visibility source_uuid')
          unless !@target_key.empty? && @target_key.last == @source_uuid
            raise ArgumentError, 'visibility source_uuid must match target key suffix'
          end
          @hidden = optional_boolean(hidden, 'hidden')
          @visible = optional_boolean(visible, 'visible')
          @tag_visible = optional_boolean(tag_visible, 'tag_visible')
          @observed_visible = if @hidden == true || @visible == false || @tag_visible == false
                                false
                              elsif @hidden == false && @visible == true && @tag_visible == true
                                true
                              else
                                nil
                              end
          freeze
        end

        private

        def evidence_target_kind(value)
          kind = Validation.text(value)
          return kind if %w[occurrence primitive].include?(kind)

          raise ArgumentError, 'visibility target_kind must be occurrence or primitive'
        end

        def optional_boolean(value, field)
          return value if value.nil? || value == true || value == false

          raise ArgumentError, "#{field} must be true, false, or nil"
        end
      end

      class ExclusionEvidence
        attr_reader :target_key, :target_kind, :source_uuid,
                    :eligible, :excluded, :reasons, :rule_ids

        def initialize(target_key:, target_kind:, source_uuid:, eligible:, excluded:,
                       reasons:, rule_ids: [].freeze)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          @target_kind = evidence_target_kind(target_kind)
          @source_uuid = Validation.uuid(source_uuid, 'eligibility source_uuid')
          unless !@target_key.empty? && @target_key.last == @source_uuid
            raise ArgumentError, 'eligibility source_uuid must match target key suffix'
          end
          unless [true, false].include?(eligible) && [true, false].include?(excluded)
            raise ArgumentError, 'eligible and excluded must be booleans'
          end
          raise ArgumentError, 'eligible and excluded must be logical opposites' unless eligible == !excluded
          @eligible = eligible
          @excluded = excluded
          Validation.frozen_array(reasons, 'reasons')
          @reasons = reasons.map { |reason| Validation.text(reason) }.freeze
          Validation.frozen_array(rule_ids, 'rule_ids')
          @rule_ids = rule_ids.map { |rule_id| Validation.text(rule_id) }.freeze
          unless @reasons.length == @rule_ids.length && @rule_ids.none?(&:empty?)
            raise ArgumentError, 'every exclusion reason requires one stable rule ID'
          end
          if @excluded && @reasons.empty?
            raise ArgumentError, 'excluded evidence requires at least one reason and stable rule ID'
          end
          if @eligible && !@reasons.empty?
            raise ArgumentError, 'eligible evidence cannot carry exclusion reasons or rule IDs'
          end
          freeze
        end

        private

        def evidence_target_kind(value)
          kind = Validation.text(value)
          return kind if %w[occurrence primitive].include?(kind)

          raise ArgumentError, 'eligibility target_kind must be occurrence or primitive'
        end
      end

      class AdjacencyBoundary
        BOUNDARY_TYPES = %w[out_of_scope_adjacency excluded_adjacency].freeze

        attr_reader :target_key, :edge_source_uuid, :adjacent_source_uuid,
                    :boundary_type

        def initialize(target_key:, edge_source_uuid:, adjacent_source_uuid:, boundary_type:)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          @edge_source_uuid = Validation.uuid(edge_source_uuid, 'edge_source_uuid')
          @adjacent_source_uuid = Validation.uuid(
            adjacent_source_uuid,
            'adjacent_source_uuid'
          )
          @boundary_type = Validation.text(boundary_type)
          unless BOUNDARY_TYPES.include?(@boundary_type)
            raise ArgumentError, 'unsupported adjacency boundary type'
          end
          freeze
        end
      end

      class Document
        attr_reader :model_id, :scope, :occurrences, :definitions, :primitives,
                    :materials, :evidence, :diagnostics, :model_context,
                    :foreign_source_provenance

        def initialize(model_id:, scope:, model_context:, occurrences:, definitions:, primitives:,
                       materials:, evidence:, foreign_source_provenance:, diagnostics:)
          @model_id = Validation.uuid(model_id, 'model_id')
          unless scope.is_a?(ExtractionScope) && scope.frozen?
            raise ArgumentError, 'scope must be an immutable ExtractionScope record'
          end
          @scope = scope
          unless model_context.is_a?(ModelContext) && model_context.frozen?
            raise ArgumentError, 'model_context must be an immutable ModelContext record'
          end
          @model_context = model_context
          @occurrences = records(occurrences, Occurrence, 'occurrences')
          @definitions = records(definitions, Definition, 'definitions')
          @primitives = records(primitives, PolygonFragment, 'primitives')
          @materials = records(materials, Material, 'materials')
          @evidence = evidence_records(evidence)
          @foreign_source_provenance = records(
            foreign_source_provenance,
            ForeignSourceProvenance,
            'foreign_source_provenance'
          )
          Validation.frozen_array(diagnostics, 'diagnostics')
          @diagnostics = diagnostics.map { |item| Validation.text(item) }.freeze
          validate_graph!
          freeze
        end

        def to_json(*)
          raise TypeError, 'private neutral snapshot cannot be serialized directly'
        end

        private

        def records(value, type, field)
          Validation.frozen_array(value, field)
          raise ArgumentError, "#{field} must contain #{type.name.split('::').last} records" unless value.all? { |item| item.is_a?(type) && item.frozen? }

          value.dup.freeze
        end

        def evidence_records(value)
          Validation.frozen_array(value, 'evidence')
          permitted = [
            ConstructionHint,
            LabelEvidence,
            VisibilityEvidence,
            ExclusionEvidence,
            AdjacencyBoundary
          ]
          unless value.all? { |item| permitted.any? { |type| item.is_a?(type) } && item.frozen? }
            raise ArgumentError, 'evidence must contain neutral evidence records'
          end
          value.dup.freeze
        end

        def validate_graph!
          primitive_keys = @primitives.map(&:key)
          raise ArgumentError, 'duplicate primitive key' unless primitive_keys.uniq.length == primitive_keys.length

          definition_uuids = @definitions.map(&:source_uuid)
          raise ArgumentError, 'duplicate definition source_uuid' unless definition_uuids.uniq.length == definition_uuids.length
          unless @occurrences.all? { |occurrence| definition_uuids.include?(occurrence.definition_uuid) }
            raise ArgumentError, 'unresolved occurrence definition ownership'
          end
          root_occurrence = @occurrences.find do |occurrence|
            occurrence.uuid_path == @scope.context_occurrence_uuid_path &&
              occurrence.definition_uuid == @scope.root_definition_uuid
          end
          unless root_occurrence
            raise ArgumentError, 'unresolved extraction scope root occurrence'
          end
          unless root_occurrence.transform == @model_context.context_transform
            raise ArgumentError, 'model context transform must match the scope root occurrence'
          end
          if @scope.mode == 'model' &&
             (!@scope.context_occurrence_uuid_path.empty? ||
              @scope.root_definition_uuid != @model_id)
            raise ArgumentError, 'model scope must use the model root context and definition'
          end
          unless @primitives.all? { |primitive| definition_uuids.include?(primitive.definition_uuid) }
            raise ArgumentError, 'unresolved definition ownership'
          end
          definitions_by_uuid = @definitions.each_with_object({}) do |definition, by_uuid|
            by_uuid[definition.source_uuid] = definition
          end
          primitives_by_key = @primitives.each_with_object({}) do |primitive, by_key|
            by_key[primitive.key] = primitive
          end
          adjacency_keys = @primitives.flat_map do |primitive|
            primitive.loops.flat_map(&:adjacent_primitive_keys)
          end
          unless adjacency_keys.all? { |key| primitives_by_key.key?(key) }
            raise ArgumentError, 'unresolved primitive adjacency'
          end
          @evidence.grep(AdjacencyBoundary).each do |boundary|
            primitive = primitives_by_key[boundary.target_key]
            edge_owned = primitive && primitive.loops.any? do |loop|
              loop.edge_source_uuids.include?(boundary.edge_source_uuid)
            end
            raise ArgumentError, 'unresolved adjacency boundary owner/edge' unless edge_owned
          end
          validate_evidence_graph!(definitions_by_uuid, primitives_by_key)
          owned = @primitives.all? do |primitive|
            definitions_by_uuid.fetch(primitive.definition_uuid).primitive_keys.include?(primitive.key)
          end
          declared = @definitions.all? do |definition|
            definition.primitive_keys.all? do |key|
              primitive = primitives_by_key[key]
              primitive && primitive.definition_uuid == definition.source_uuid
            end
          end
          raise ArgumentError, 'unresolved definition ownership' unless owned && declared

          material_uuids = @materials.map(&:source_uuid)
          referenced_materials = @primitives.flat_map do |primitive|
            [primitive.front_material_uuid, primitive.back_material_uuid].compact
          end
          referenced_materials.concat(@occurrences.map(&:material_uuid).compact)
          raise ArgumentError, 'unresolved material ownership' unless (referenced_materials - material_uuids).empty?
        end

        def validate_evidence_graph!(definitions_by_uuid, primitives_by_key)
          occurrences_by_path = @occurrences.each_with_object({}) do |occurrence, by_path|
            by_path[occurrence.uuid_path] = occurrence
          end

          construction_hints = @evidence.grep(ConstructionHint) +
                               @primitives.flat_map(&:construction_hints)
          construction_hints.uniq.each do |hint|
            primitive = primitives_by_key[hint.target_key]
            unless primitive && primitive.source_uuid == hint.source_uuid
              raise ArgumentError, 'unresolved construction evidence target/source correspondence'
            end
          end

          @evidence.grep(LabelEvidence).each do |label|
            resolved = evidence_target_resolved?(
              label.target_kind,
              label.target_key,
              occurrences_by_path,
              primitives_by_key
            )
            raise ArgumentError, 'unresolved label evidence target' unless resolved

            next unless label.source == 'attached_text'

            occurrence = occurrences_by_path[label.target_occurrence_uuid_path]
            raise ArgumentError, 'unresolved attached label occurrence path' if occurrence.nil?
            if label.target_kind == 'primitive'
              primitive = primitives_by_key.fetch(label.target_key)
              unless primitive.definition_uuid == occurrence.definition_uuid
                raise ArgumentError, 'attached label occurrence does not own target primitive'
              end
            end
          end

          exclusions = @evidence.grep(ExclusionEvidence)
          exclusions.each do |item|
            resolved = if item.eligible
                         evidence_target_resolved?(
                           item.target_kind,
                           item.target_key,
                           occurrences_by_path,
                           primitives_by_key
                         )
                       else
                         excluded_candidate_target_resolved?(
                           item,
                           definitions_by_uuid,
                           occurrences_by_path
                         )
                       end
            raise ArgumentError, 'unresolved eligibility evidence target' unless resolved
          end

          @evidence.grep(VisibilityEvidence).each do |item|
            eligibility = exclusions.find do |candidate|
              candidate.target_kind == item.target_kind &&
                candidate.target_key == item.target_key &&
                candidate.source_uuid == item.source_uuid
            end
            raise ArgumentError, 'unresolved visibility evidence target' if eligibility.nil?
          end
        end

        def evidence_target_resolved?(kind, key, occurrences_by_path, primitives_by_key)
          if kind == 'occurrence'
            occurrences_by_path.key?(key)
          else
            primitives_by_key.key?(key)
          end
        end

        def excluded_candidate_target_resolved?(item, definitions_by_uuid, occurrences_by_path)
          if item.target_kind == 'primitive'
            item.target_key.length == 2 && definitions_by_uuid.key?(item.target_key.first)
          else
            !item.target_key.empty? && occurrences_by_path.key?(item.target_key[0..-2])
          end
        end
      end
    end
  end
end
