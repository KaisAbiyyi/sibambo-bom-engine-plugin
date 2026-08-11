# frozen_string_literal: true

# Real-host acceptance harness. Run inside SketchUp through the development
# autorun wrapper; it creates a tiny SKP fixture, traces API -> snapshot ->
# compiler -> writer -> JSON, and writes one machine-readable report.
require 'json'

module BOMEngine
  module Tests
    module SketchupAppearanceAcceptance
      module_function

      MATERIAL_SPECS = {
        'Acceptance Red' => [255, 0, 0],
        'Acceptance Blue' => [0, 0, 255],
        'Acceptance Green' => [0, 255, 0],
        'Acceptance Yellow' => [255, 255, 0],
        'Acceptance Translucent' => [160, 80, 200]
      }.freeze

      def run(fixture_path:, output_path:, report_path:)
        model = Sketchup.active_model
        unless model.path.to_s.empty? && !model.modified?
          raise 'appearance fixture requires a fresh, unsaved, unmodified SketchUp model'
        end
        fixture = create_fixture(model)
        model.save(fixture_path)

        stage_a = api_trace(model, fixture)
        plan = BOMEngine::SemanticV2::IdentityCoordinator.plan(
          model: model,
          roots: model.entities,
          prepare_model_writes: false,
          deterministic_virtual_identities: true
        )
        snapshot = BOMEngine::SemanticV2::Extractor.extract(
          model: model,
          roots: model.entities,
          parent_transform: Geom::Transformation.new,
          identity_plan: plan,
          settings: {
            include_hidden: false,
            extraction_policy_id: BOMEngine::CleanAnalysis::Exporter::EXTRACTION_POLICY_ID,
            scope_mode: 'model'
          }
        )
        stage_b = snapshot_trace(snapshot)

        compiler = BOMEngine::CleanAnalysis::Compiler.new(snapshot)
        document = compiler.compile
        stage_c = compiler_trace(compiler, document)
        write_result = BOMEngine::CleanAnalysis::Writer.write(output_path, document)
        stage_d = writer_trace(document, write_result)
        exported = JSON.parse(File.binread(output_path))
        stage_e = exported_trace(exported)
        assertions = assertions(stage_a, stage_b, stage_c, stage_e)

        report = {
          status: assertions.values.all? ? 'passed' : 'failed',
          build: BOMEngine::CleanAnalysis::BuildInfo.diagnostic,
          sketchup_version: Sketchup.version.to_s,
          ruby_version: RUBY_VERSION,
          fixture_path: File.expand_path(fixture_path),
          output_path: File.expand_path(output_path),
          first_loss: first_loss(stage_a, stage_b, stage_c, stage_e),
          assertions: assertions,
          stage_a_api: stage_a,
          stage_b_snapshot: stage_b,
          stage_c_compiler: stage_c,
          stage_d_writer: stage_d,
          stage_e_json: stage_e
        }
        write_json(report_path, report)
        puts JSON.pretty_generate(report)
        report
      rescue StandardError => error
        report = {
          status: 'failed',
          error_class: error.class.name,
          error: error.message,
          backtrace: Array(error.backtrace).first(20)
        }
        write_json(report_path, report) if report_path
        puts JSON.pretty_generate(report)
        report
      end

      def create_fixture(model)
        model.start_operation('CleanV1 appearance acceptance fixture', true)
        model.entities.clear!
        model.definitions.purge_unused
        model.materials.purge_unused

        materials = MATERIAL_SPECS.each_with_object({}) do |(name, rgb), result|
          material = model.materials.add(name)
          material.color = Sketchup::Color.new(*rgb)
          result[name] = material
        end
        materials.fetch('Acceptance Translucent').alpha = 0.5

        faces = {}
        faces['A'] = add_square(model.entities, 0, 0)
        faces['A'].material = materials.fetch('Acceptance Red')
        faces['B'] = add_square(model.entities, 3, 0)
        faces['B'].material = materials.fetch('Acceptance Blue')
        faces['C'] = add_square(model.entities, 6, 0)
        faces['C'].material = materials.fetch('Acceptance Green')
        faces['C'].back_material = materials.fetch('Acceptance Yellow')
        faces['D'] = add_square(model.entities, 9, 0)
        faces['E'] = add_square(model.entities, 12, 0)
        faces['E'].material = materials.fetch('Acceptance Translucent')

        definition = model.definitions.add('Appearance Shared Component')
        definition_face = add_square(definition.entities, 0, 0)
        instance_red = model.entities.add_instance(
          definition,
          Geom::Transformation.translation([0, 3, 0])
        )
        instance_red.name = 'Appearance Instance Red'
        instance_red.material = materials.fetch('Acceptance Red')
        instance_blue = model.entities.add_instance(
          definition,
          Geom::Transformation.translation([3, 3, 0])
        )
        instance_blue.name = 'Appearance Instance Blue'
        instance_blue.material = materials.fetch('Acceptance Blue')
        model.commit_operation
        {
          faces: faces,
          definition: definition,
          definition_face: definition_face,
          instances: [instance_red, instance_blue],
          materials: materials
        }
      rescue StandardError
        model.abort_operation
        raise
      end

      def add_square(entities, x, y)
        entities.add_face(
          [x, y, 0], [x + 2, y, 0], [x + 2, y + 2, 0], [x, y + 2, 0]
        )
      end
      private_class_method :add_square

      def api_trace(model, fixture)
        {
          model_material_count: model.materials.count,
          materials: model.materials.map { |material| material_api(material) },
          faces: fixture.fetch(:faces).each_with_object({}) do |(label, face), result|
            result[label] = face_api(face)
          end,
          instances: fixture.fetch(:instances).map do |instance|
            {
              persistent_id: instance.persistent_id,
              name: instance.name,
              material: material_api(instance.material)
            }
          end,
          definition: {
            name: fixture.fetch(:definition).name,
            contained_face: face_api(fixture.fetch(:definition_face))
          }
        }
      end

      def face_api(face)
        {
          persistent_id: face.persistent_id,
          front_material: material_api(face.material),
          back_material: material_api(face.back_material)
        }
      end
      private_class_method :face_api

      def material_api(material)
        return nil if material.nil?

        color = material.color
        {
          persistent_id: material.persistent_id,
          name: material.name,
          color: [color.red, color.green, color.blue, color.alpha],
          alpha: material.alpha,
          texture: material.texture && {
            filename: File.basename(material.texture.filename.to_s),
            width: material.texture.width.to_f,
            height: material.texture.height.to_f
          }
        }
      end
      private_class_method :material_api

      def snapshot_trace(snapshot)
        {
          material_count: snapshot.materials.length,
          materials: snapshot.materials.map do |material|
            {
              source_uuid: material.source_uuid,
              name: material.name,
              rgba: material.rgba,
              texture: material.texture
            }
          end,
          primitives: snapshot.primitives.map do |primitive|
            {
              source_uuid: primitive.source_uuid,
              definition_uuid: primitive.definition_uuid,
              front_material_uuid: primitive.front_material_uuid,
              back_material_uuid: primitive.back_material_uuid
            }
          end,
          occurrences: snapshot.occurrences.map do |occurrence|
            {
              uuid_path: occurrence.uuid_path,
              definition_uuid: occurrence.definition_uuid,
              material_uuid: occurrence.material_uuid
            }
          end
        }
      end

      def compiler_trace(compiler, document)
        {
          material_ids: compiler.instance_variable_get(:@material_ids),
          materials: document.fetch('materials'),
          surfaces: material_fields(document.fetch('surfaces')),
          definition_surfaces: document.fetch('definitions').flat_map do |definition|
            material_fields(definition.dig('geometry', 'surfaces')).map do |surface|
              surface.merge('definition_id' => definition.fetch('id'))
            end
          end,
          instances: material_fields(document.fetch('instances'))
        }
      end

      def writer_trace(document, write_result)
        {
          bytes: write_result.fetch(:bytes),
          document_material_count: document.fetch('materials').length,
          document_reference_count: count_material_refs(document)
        }
      end

      def exported_trace(exported)
        {
          material_count: exported.fetch('materials').length,
          materials: exported.fetch('materials'),
          surfaces: material_fields(exported.fetch('surfaces')),
          definition_surfaces: exported.fetch('definitions').flat_map do |definition|
            material_fields(definition.dig('geometry', 'surfaces')).map do |surface|
              surface.merge('definition_id' => definition.fetch('id'))
            end
          end,
          instances: material_fields(exported.fetch('instances')),
          reference_count: count_material_refs(exported),
          definition_count: exported.fetch('definitions').length
        }
      end

      def material_fields(records)
        Array(records).map do |record|
          record.select do |key, _value|
            key == 'id' || key == 'front_material_id' || key == 'back_material_id' ||
              key == 'inherited_material_id' || key == 'material_id'
          end
        end
      end
      private_class_method :material_fields

      def count_material_refs(value)
        case value
        when Hash
          value.inject(0) do |sum, (key, child)|
            sum + (key.to_s.end_with?('material_id') && child ? 1 : 0) + count_material_refs(child)
          end
        when Array
          value.inject(0) { |sum, child| sum + count_material_refs(child) }
        else
          0
        end
      end
      private_class_method :count_material_refs

      def assertions(stage_a, stage_b, stage_c, stage_e)
        ids = stage_e.fetch(:materials).each_with_object({}) do |material, result|
          result[material.fetch('name')] = material.fetch('id')
        end
        surfaces = stage_e.fetch(:surfaces)
        instances = stage_e.fetch(:instances)
        translucent = stage_e.fetch(:materials).find { |item| item.fetch('name') == 'Acceptance Translucent' }
        {
          materials: stage_a.fetch(:model_material_count) == 5 &&
            stage_b.fetch(:material_count) == 5 && stage_c.fetch(:materials).length == 5 &&
            stage_e.fetch(:material_count) == 5,
          front: surfaces.any? { |item| item['front_material_id'] == ids['Acceptance Red'] } &&
            surfaces.any? { |item| item['front_material_id'] == ids['Acceptance Blue'] },
          back: surfaces.any? do |item|
            item['front_material_id'] == ids['Acceptance Green'] &&
              item['back_material_id'] == ids['Acceptance Yellow']
          end,
          unpainted: surfaces.any? do |item|
            !item.key?('front_material_id') && !item.key?('back_material_id') &&
              !item.key?('inherited_material_id')
          end,
          instance_override: instances.count { |item| item['material_id'] == ids['Acceptance Red'] } == 1 &&
            instances.count { |item| item['material_id'] == ids['Acceptance Blue'] } == 1,
          opacity: translucent && translucent.fetch('base_color_rgba')[3] == 0.5 &&
            translucent.fetch('opacity') == 0.5,
          shared_definition_once: stage_e.fetch(:definition_count) == 1,
          writer_preserved_refs: stage_e.fetch(:reference_count) ==
            stage_c.fetch(:surfaces).sum { |item| count_material_refs(item) } +
              stage_c.fetch(:definition_surfaces).sum { |item| count_material_refs(item) } +
              stage_c.fetch(:instances).sum { |item| count_material_refs(item) }
        }
      end

      def first_loss(stage_a, stage_b, stage_c, stage_e)
        return 'stage_a_sketchup_api' unless stage_a.fetch(:model_material_count) == 5
        return 'stage_b_neutral_snapshot' unless stage_b.fetch(:material_count) == 5
        return 'stage_c_clean_compiler' unless stage_c.fetch(:materials).length == 5
        return 'stage_e_exported_json' unless stage_e.fetch(:material_count) == 5

        'none'
      end
      private_class_method :first_loss

      def write_json(path, value)
        File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(value) + "\n") }
      end
      private_class_method :write_json
    end
  end
end
