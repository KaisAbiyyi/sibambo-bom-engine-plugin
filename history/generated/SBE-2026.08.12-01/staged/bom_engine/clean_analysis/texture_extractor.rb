# frozen_string_literal: true

require 'tmpdir'

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    # SketchUp adapter used only by the Clean Visual package export.
    module TextureExtractor
      module_function

      def extract(model:, roots:, identity_plan:, snapshot:, include_hidden: false, progress: nil)
        Builder.new(
          model: model,
          identity_plan: identity_plan,
          snapshot: snapshot,
          include_hidden: include_hidden,
          progress: progress
        ).extract(roots)
      end

      class Builder
        UVQ_EPSILON = 1.0e-12

        def initialize(model:, identity_plan:, snapshot:, include_hidden:, progress:)
          @model = model
          @identity_plan = identity_plan
          @snapshot = snapshot
          @include_hidden = include_hidden == true
          @progress = progress
          @bundle = TextureBundle.new
          @root_definition_uuid = snapshot.scope.root_definition_uuid
          @primitive_keys = snapshot.primitives.each_with_object({}) { |item, out| out[item.key] = true }
          @eligible_definitions = snapshot.occurrences.each_with_object({}) do |item, out|
            out[item.definition_uuid] = true
          end
          @visited_definitions = {}
          @texture_writer = begin
            Sketchup.create_texture_writer
          rescue StandardError
            nil
          end
        end

        def extract(roots)
          extract_materials
          scan_entities(Array(roots), @root_definition_uuid)
          @bundle
        end

        private

        def extract_materials
          dimensions = @snapshot.materials.each_with_object({}) { |item, out| out[item.source_uuid] = item.texture }
          planned_materials.each do |material_uuid, material|
            checkpoint('Extracting texture assets')
            metadata = dimensions[material_uuid]
            next if metadata.nil? || !material.respond_to?(:texture) || material.texture.nil?

            write_texture(material, material_uuid, metadata)
          end
        end

        def planned_materials
          collection_items(@model.materials).each_with_object([]) do |material, result|
            begin
              result << [source_uuid(material), material]
            rescue KeyError
              next
            end
          end.sort_by(&:first)
        end

        def write_texture(material, material_uuid, metadata)
          Dir.mktmpdir('bom-clean-texture') do |directory|
            path = File.join(directory, 'texture.png')
            material.texture.write(path, true)
            raise 'SketchUp did not write the texture image' unless File.file?(path) && File.size(path).positive?

            @bundle.register_texture(
              material_uuid: material_uuid,
              bytes: File.binread(path),
              extension: 'png',
              width_m: texture_value(metadata, :width_m),
              height_m: texture_value(metadata, :height_m)
            )
          end
        rescue StandardError
          @bundle.register_missing(material_uuid: material_uuid, reason: 'texture_write_failed')
        end

        def scan_entities(entities, definition_uuid)
          entities.each do |entity|
            checkpoint('Extracting face UV coordinates')
            if face?(entity)
              add_face(entity, definition_uuid) if visible?(entity)
            elsif instance?(entity)
              scan_definition(entity.definition)
            end
          end
        end

        def scan_definition(definition)
          definition_uuid = source_uuid(definition)
          return unless @eligible_definitions[definition_uuid]
          return if @visited_definitions[definition_uuid]

          @visited_definitions[definition_uuid] = true
          scan_entities(collection_items(definition.entities), definition_uuid)
        end

        def add_face(face, definition_uuid)
          return if @texture_writer.nil?

          key = [definition_uuid, source_uuid(face)]
          return unless @primitive_keys[key]

          helper = face.get_UVHelper(true, true, @texture_writer)
          outer = face.outer_loop
          holes = collection_items(face.loops).reject { |loop| loop.equal?(outer) }
          front = textured_material?(face.material) ? uv_mapping(helper, :get_front_UVQ, outer, holes) : nil
          back = textured_material?(face.back_material) ? uv_mapping(helper, :get_back_UVQ, outer, holes) : nil
          @bundle.register_uv(primitive_key: key, front: front, back: back) if front || back
        rescue StandardError
          nil
        end

        def uv_mapping(helper, method, outer, holes)
          outer_uv = uv_loop(helper, method, outer)
          return nil if outer_uv.nil?

          hole_uv = holes.map { |loop| uv_loop(helper, method, loop) }
          return nil if hole_uv.any?(&:nil?)

          { outer: outer_uv, holes: hole_uv }
        end

        def uv_loop(helper, method, loop)
          collection_items(loop.vertices).map do |vertex|
            uvq = helper.public_send(method, vertex.position)
            q = coordinate(uvq, 2, :z)
            return nil unless q.finite? && q.abs > UVQ_EPSILON

            u = coordinate(uvq, 0, :x) / q
            v = coordinate(uvq, 1, :y) / q
            return nil unless u.finite? && v.finite?

            [u, v]
          end
        end

        def face?(entity)
          face_class = defined?(Sketchup::Face) && Sketchup::Face
          face_class ? entity.is_a?(face_class) : entity.respond_to?(:get_UVHelper) && entity.respond_to?(:loops)
        end

        def instance?(entity)
          entity.respond_to?(:definition) && entity.respond_to?(:transformation)
        end

        def textured_material?(material)
          !material.nil? && material.respond_to?(:texture) && !material.texture.nil?
        end

        def visible?(entity)
          return true if @include_hidden
          return false if entity.respond_to?(:hidden?) && entity.hidden?
          return false if entity.respond_to?(:visible?) && !entity.visible?

          layer = entity.respond_to?(:layer) ? entity.layer : nil
          !layer.respond_to?(:visible?) || layer.visible?
        end

        def source_uuid(entity)
          @identity_plan.source_uuid_for(entity).to_s.downcase
        end

        def texture_value(texture, key)
          texture[key] || texture[key.to_s]
        end

        def coordinate(value, index, method)
          value.respond_to?(method) ? value.public_send(method).to_f : Array(value).fetch(index).to_f
        end

        def collection_items(value)
          value.respond_to?(:to_a) ? value.to_a : Array(value)
        end

        def checkpoint(stage)
          @progress.call(stage) if @progress
        end
      end
    end
  end
end

end # SibamboHistory
