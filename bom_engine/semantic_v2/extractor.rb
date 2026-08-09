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
          @primitives = []
          @materials = {}
          @evidence = []
          @diagnostics = Array(identity_plan.respond_to?(:diagnostics) ? identity_plan.diagnostics : []).map(&:to_s)
          @attached_labels = Hash.new { |hash, key| hash[key] = [] }
        end

        def extract(roots, parent_transform)
          checkpoint('Extracting neutral snapshot')
          root_uuid = uuid(@identity_plan.model_id, 'model_id')
          @definition_data[root_uuid] = { kind: 'model', primitive_keys: [], children: [] }
          root_transform = matrix(parent_transform)
          @occurrences << Snapshot::Occurrence.new(
            uuid_path: [].freeze,
            definition_uuid: root_uuid,
            transform: normalized_transform(root_transform)
          )
          root_items = Array(roots)
          index_direct_attached_labels(root_items)
          root_items.each do |entity|
            if face?(entity)
              extract_face(entity, definition_uuid: root_uuid, owner_chain: [])
            elsif instance?(entity)
              ensure_definition(entity.definition)
              emit_occurrence(entity, parent_path: [], parent_transform: root_transform)
            end
          end
          checkpoint('Neutral snapshot ready')
          build_document(root_uuid)
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
          index_direct_attached_labels(items)
          items.each do |entity|
            if face?(entity)
              extract_face(entity, definition_uuid: definition_uuid, owner_chain: [definition_uuid])
            elsif instance?(entity)
              entry[:children] << entity
              ensure_definition(entity.definition)
            end
          end
          definition_uuid
        end

        def emit_occurrence(entity, parent_path:, parent_transform:)
          occurrence_uuid = uuid(@identity_plan.occurrence_uuid_for(entity), 'occurrence source_uuid')
          path = (parent_path + [occurrence_uuid]).freeze
          definition_uuid = ensure_definition(entity.definition)
          transform = multiply_matrices(parent_transform, matrix(entity.transformation))
          reasons = exclusion_reasons(entity, policy: false)
          if reasons.empty?
            @occurrences << Snapshot::Occurrence.new(
              uuid_path: path,
              definition_uuid: definition_uuid,
              transform: normalized_transform(transform),
              material_uuid: material_uuid(entity.respond_to?(:material) ? entity.material : nil)
            )
            add_label_evidence(entity, path, definition_name: entity.definition.respond_to?(:name) ? entity.definition.name : nil)
            @definition_data.fetch(definition_uuid).fetch(:children).each do |child|
              emit_occurrence(child, parent_path: path, parent_transform: transform)
            end
          else
            @evidence << exclusion_evidence(path, reasons)
          end
        end

        def extract_face(face, definition_uuid:, owner_chain:)
          face_uuid = source_uuid(face)
          key = (owner_chain + [face_uuid]).freeze
          reasons = exclusion_reasons(face, policy: true)
          @evidence << Snapshot::ExclusionEvidence.new(
            target_key: key,
            eligible: reasons.empty?,
            excluded: !reasons.empty?,
            reasons: reasons.freeze
          )
          add_label_evidence(face, key, definition_name: nil)
          return unless reasons.empty?

          hints = [Snapshot::ConstructionHint.new(
            target_key: key,
            kind: 'surface_normal',
            value: vector(face.normal),
            source: 'face_geometry'
          )].freeze
          front_material_uuid = material_uuid(face.respond_to?(:material) ? face.material : nil)
          back_material_uuid = material_uuid(face.respond_to?(:back_material) ? face.back_material : nil)
          loops = Array(face.loops).map do |loop|
            build_loop(loop, owner_chain, face)
          end.freeze
          fragment = Snapshot::PolygonFragment.new(
            key: key,
            definition_uuid: definition_uuid,
            source_uuid: face_uuid,
            loops: loops,
            front_material_uuid: front_material_uuid,
            back_material_uuid: back_material_uuid,
            normal: vector(face.normal),
            area_m2: face.area.to_f * SQUARE_INCH_TO_M2,
            construction_hints: hints
          )
          @primitives << fragment
          @definition_data.fetch(definition_uuid).fetch(:primitive_keys) << key
          @evidence.concat(hints)
          checkpoint('Extracting polygon fragment')
        end

        def build_loop(loop, owner_chain, owning_face)
          vertices = Array(loop.vertices).map do |vertex|
            point(vertex.position)
          end.freeze
          edges = loop.respond_to?(:edges) ? Array(loop.edges) : []
          edge_source_uuids = edges.filter_map { |edge| optional_source_uuid(edge) }.freeze
          adjacent_keys = edges.flat_map do |edge|
            next [] unless edge.respond_to?(:faces)

            Array(edge.faces).reject { |face| face.equal?(owning_face) }.filter_map do |face|
              adjacent_uuid = optional_source_uuid(face)
              (owner_chain + [adjacent_uuid]).freeze if adjacent_uuid
            end
          end.uniq.freeze
          Snapshot::Loop.new(
            kind: loop.respond_to?(:outer?) && loop.outer? ? 'outer' : 'hole',
            vertices: vertices,
            edge_source_uuids: edge_source_uuids,
            adjacent_primitive_keys: adjacent_keys
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
            width: (texture.respond_to?(:width) ? texture.width.to_f : nil),
            height: (texture.respond_to?(:height) ? texture.height.to_f : nil)
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

        def index_direct_attached_labels(items)
          items.each do |entity|
            next unless text?(entity)

            attached = entity.respond_to?(:attached_to) ? entity.attached_to : nil
            path = attached.is_a?(Array) ? attached.first : nil
            path = path.to_a if path.respond_to?(:to_a)
            path_entities = Array(path)
            target = path_entities.reverse.find { |candidate| instance?(candidate) }
            target ||= path_entities.last
            label = SemanticLabeler.clean(entity.text)
            next if target.nil? || label.empty?

            @attached_labels[target.__id__] << { value: label }
          end
        rescue StandardError => error
          @diagnostics << "attached_label.#{error.class}"
        end

        def add_label_evidence(entity, target_key, definition_name:)
          semantic = SemanticLabeler.build(
            instance_name: entity.respond_to?(:name) ? entity.name : '',
            definition_name: definition_name,
            tag_name: tag_name(entity),
            attached_labels: @attached_labels[entity.__id__]
          )
          unless semantic[:label].nil?
            @evidence << Snapshot::LabelEvidence.new(
              target_key: target_key,
              label: semantic[:label],
              source: semantic[:source],
              role: nil,
              classification_policy: semantic[:classification_policy],
              aliases: Array(semantic[:aliases]).map { |item| item.to_s.freeze }.freeze,
              explicit: true
            )
          end
          return if semantic[:role].nil?

          @evidence << Snapshot::LabelEvidence.new(
            target_key: target_key,
            label: nil,
            source: 'role_inference',
            role: semantic[:role],
            classification_policy: semantic[:classification_policy],
            aliases: [].freeze,
            explicit: false
          )
        end

        def tag_name(entity)
          tag = entity.respond_to?(:layer) ? entity.layer : nil
          tag.respond_to?(:name) ? tag.name : nil
        end

        def exclusion_reasons(entity, policy:)
          reasons = []
          unless setting(:include_hidden, false)
            reasons << 'hidden' if entity.respond_to?(:hidden?) && entity.hidden?
            reasons << 'not_visible' if entity.respond_to?(:visible?) && !entity.visible? && !reasons.include?('hidden')
            layer = entity.respond_to?(:layer) ? entity.layer : nil
            reasons << 'hidden_tag' if layer&.respond_to?(:visible?) && !layer.visible?
          end
          if policy
            face_policy = setting(:face_policy, nil)
            reasons << 'policy_excluded' if face_policy.respond_to?(:call) && !face_policy.call(entity)
          end
          reasons.uniq
        end

        def exclusion_evidence(key, reasons)
          Snapshot::ExclusionEvidence.new(
            target_key: key,
            eligible: false,
            excluded: true,
            reasons: reasons.freeze
          )
        end

        def build_document(root_uuid)
          definitions = @definition_data.map do |definition_uuid, entry|
            Snapshot::Definition.new(
              source_uuid: definition_uuid,
              kind: entry.fetch(:kind),
              primitive_keys: entry.fetch(:primitive_keys).sort.freeze
            )
          end.sort_by(&:source_uuid).freeze
          Snapshot::Document.new(
            model_id: root_uuid,
            occurrences: @occurrences.sort_by(&:uuid_path).freeze,
            definitions: definitions,
            primitives: @primitives.sort_by(&:key).freeze,
            materials: @materials.values.sort_by(&:source_uuid).freeze,
            evidence: @evidence.sort_by { |item| [item.target_key, item.class.name, item.respond_to?(:source) ? item.source.to_s : ''] }.freeze,
            diagnostics: @diagnostics.uniq.sort.map(&:freeze).freeze
          )
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
