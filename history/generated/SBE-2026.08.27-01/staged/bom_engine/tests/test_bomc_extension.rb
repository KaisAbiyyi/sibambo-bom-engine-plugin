# Pure-Ruby BOMC extension-boundary tests. This file does not load SketchUp.

require 'fileutils'
require 'tmpdir'
require_relative '../bomc_extension'

module SibamboHistory
  module V20260827_01
  module Tests
    module BOMCExtensionTest
      module_function

      FakeModel = Struct.new(:path)
      class FakeMenu
        attr_reader :labels

        def initialize
          @labels = []
        end

        def add_item(label, &_block)
          @labels << label
          @labels.length
        end
      end

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        saved = BOMCExtension.output_path(FakeModel.new('D:/models/RUMAH_L.skp'))
        unsaved = BOMCExtension.output_path(FakeModel.new(''))
        assert(saved.tr('\\', '/').end_with?('/model-eval-exports/RUMAH_L__SBE-2026.08.27-01.bomc'), 'saved model gets deterministic one-file BOMC path')
        assert(unsaved.end_with?('Untitled__SBE-2026.08.27-01.bomc'), 'unsaved model gets deterministic BOMC filename')
        assert(BOMCExtension::DEFAULT_PROFILE == :production, 'production profile is the preferred default')
        assert(BOMCExtension::FORMAT_EXTENSION == '__SBE-2026.08.27-01.bomc', 'compiled user-facing extension is stable')
        menu = FakeMenu.new
        BOMCExtension.register_menu(menu)
        assert(menu.labels == ['BOM Engine: Export Compiled BOMC...'], 'compiled export command registers without replacing legacy menus')

        texture_dir = Dir.mktmpdir('bomc-texture-choice')
        begin
          source_path = File.join(texture_dir, 'original.jpg')
          staged_path = File.join(texture_dir, 'material.png')
          File.open(source_path, 'wb') { |file| file.write("\xff\xd8source-jpeg".b) }
          File.open(staged_path, 'wb') { |file| file.write("\x89PNG\r\n\x1a\nstaged-png-payload".b) }
          graph = { materials: [{ name: 'Material', texture: {} }] }
          extracted = [{ name: 'Material', texture: { filename: 'material.png', source_path: source_path } }]
          BOMCExtension.send(:attach_staged_textures, graph, extracted, texture_dir)
          selected = graph[:materials][0][:texture]
          assert(selected[:source_path] == source_path && selected[:filename] == 'original.jpg', 'readable native JPEG source is preserved instead of forced PNG staging')
          assert(selected.dig(:encoding_evidence, :selected) == :source && selected.dig(:encoding_evidence, :source_bytes) < selected.dig(:encoding_evidence, :staged_bytes), 'texture selection records source/staged byte evidence')

          missing_source = File.join(texture_dir, 'embedded', 'wood.jpg')
          staged_jpeg_path = File.join(texture_dir, 'wood.jpg')
          File.open(staged_jpeg_path, 'wb') { |file| file.write("\xff\xd8optimized-jpeg".b) }
          graph = { materials: [{ name: 'Embedded Wood', texture: {} }] }
          extracted = [{
            name: 'Embedded Wood',
            texture: {
              filename: 'wood.jpg',
              source_path: missing_source,
              staging_evidence: {
                selected: :jpeg_candidate,
                staged_bytes: 10_000,
                candidate_bytes: File.size(staged_jpeg_path),
                quality: { psnr_db: 42.5 },
                reason: :native_jpeg_restored
              }
            }
          }]
          BOMCExtension.send(:attach_staged_textures, graph, extracted, texture_dir)
          selected = graph[:materials][0][:texture]
          assert(selected[:source_path] == staged_jpeg_path && selected[:filename] == 'wood.jpg', 'unavailable embedded source uses the evidence-gated staged JPEG')
          assert(selected.dig(:encoding_evidence, :staging, :quality, :psnr_db) == 42.5, 'compiled texture metrics retain staging quality evidence')
        ensure
          FileUtils.remove_entry(texture_dir) if texture_dir && Dir.exist?(texture_dir)
        end

        output_dir = Dir.mktmpdir('bomc-extension-test')
        begin
          path = File.join(output_dir, 'nested', 'fixture__SBE-2026.08.27-01.bomc')
          published = BOMCExtension.publish_graph(path, fixture_graph, profile: :production)
          assert(File.file?(path), 'pure extension boundary publishes one BOMC file')
          assert(Dir.glob(File.join(output_dir, '**', '*')).select { |entry| File.file?(entry) }.length == 1, 'publication requires no companion files')
          assert(published[:path] == path && published[:bytes] == File.size(path), 'extension boundary reports path and bytes')
        ensure
          FileUtils.remove_entry(output_dir) if output_dir && Dir.exist?(output_dir)
        end
        puts 'BOMC Extension Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Extension Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def fixture_graph
        {
          format: { name: 'BOM Engine Canonical', version: '3.0.0' },
          source: { file_name: 'fixture.skp', model_name: 'Fixture' },
          materials: [], tags: [],
          transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
          meshes: [],
          definitions: [{ id: 'definition-root', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] }],
          nodes: [{ id: 'node-root', kind: 'root', name: 'Model Root', definition_id: 'definition-root', transform_id: 0, visible: true }]
        }
      end
    end
  end
end

exit(SibamboHistory::V20260827_01::Tests::BOMCExtensionTest.run ? 0 : 1)

end # SibamboHistory
