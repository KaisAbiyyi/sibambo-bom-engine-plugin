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

        def frozen_array(value, field)
          raise ArgumentError, "#{field} must be frozen Array" unless value.is_a?(Array) && value.frozen?

          value
        end

        def frozen_value(value, field)
          case value
          when Array
            frozen_array(value, field)
            value.each_with_index { |item, index| frozen_value(item, "#{field}[#{index}]") }
          when Hash
            raise ArgumentError, "#{field} must be frozen" unless value.frozen?

            value.each { |key, item| frozen_value(key, "#{field} key"); frozen_value(item, "#{field}[#{key}]") }
          end
          value
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
            Validation.uuid_path(key, "primitive_keys[#{index}]")
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
          @key = Validation.uuid_path(key, 'primitive key')
          @definition_uuid = Validation.uuid(definition_uuid, 'definition_uuid')
          @source_uuid = Validation.uuid(source_uuid, 'source_uuid')
          raise ArgumentError, 'primitive key must end with source_uuid' unless @key.last == @source_uuid

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
          Validation.frozen_value(texture, 'texture') unless texture.nil?
          @texture = texture
          freeze
        end
      end

      class ConstructionHint
        attr_reader :target_key, :kind, :value, :source

        def initialize(target_key:, kind:, value:, source:)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          @kind = Validation.text(kind)
          Validation.frozen_value(value, 'value')
          @value = value
          @source = Validation.text(source)
          freeze
        end
      end

      class LabelEvidence
        attr_reader :target_key, :label, :source, :role,
                    :classification_policy, :aliases, :explicit

        def initialize(target_key:, label:, source:, role:, classification_policy:, aliases:, explicit:)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          @label = Validation.text(label)
          @source = Validation.text(source)
          @role = Validation.text(role)
          @classification_policy = Validation.text(classification_policy)
          Validation.frozen_array(aliases, 'aliases')
          @aliases = aliases.map { |alias_value| Validation.text(alias_value) }.freeze
          raise ArgumentError, 'explicit must be true or false' unless explicit == true || explicit == false
          @explicit = explicit
          freeze
        end
      end

      class ExclusionEvidence
        attr_reader :target_key, :eligible, :excluded, :reasons

        def initialize(target_key:, eligible:, excluded:, reasons:)
          @target_key = Validation.uuid_path(target_key, 'target_key')
          unless [true, false].include?(eligible) && [true, false].include?(excluded)
            raise ArgumentError, 'eligible and excluded must be booleans'
          end
          @eligible = eligible
          @excluded = excluded
          Validation.frozen_array(reasons, 'reasons')
          @reasons = reasons.map { |reason| Validation.text(reason) }.freeze
          freeze
        end
      end

      class Document
        attr_reader :model_id, :occurrences, :definitions, :primitives,
                    :materials, :evidence, :diagnostics

        def initialize(model_id:, occurrences:, definitions:, primitives:, materials:, evidence:, diagnostics:)
          @model_id = Validation.uuid(model_id, 'model_id')
          @occurrences = records(occurrences, Occurrence, 'occurrences')
          @definitions = records(definitions, Definition, 'definitions')
          @primitives = records(primitives, PolygonFragment, 'primitives')
          @materials = records(materials, Material, 'materials')
          @evidence = evidence_records(evidence)
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
          permitted = [ConstructionHint, LabelEvidence, ExclusionEvidence]
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
          unless @primitives.all? { |primitive| definition_uuids.include?(primitive.definition_uuid) }
            raise ArgumentError, 'unresolved definition ownership'
          end
          definitions_by_uuid = @definitions.to_h { |definition| [definition.source_uuid, definition] }
          primitives_by_key = @primitives.to_h { |primitive| [primitive.key, primitive] }
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
          referenced_materials.concat(@occurrences.filter_map(&:material_uuid))
          raise ArgumentError, 'unresolved material ownership' unless (referenced_materials - material_uuids).empty?
        end
      end
    end
  end
end
