# Pure-Ruby BOMC extension-boundary tests. This file does not load SketchUp.

require 'fileutils'
require 'tmpdir'
require_relative '../bomc_extension'

module BOMEngine
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
        assert(saved.tr('\\', '/').end_with?('/model-eval-exports/RUMAH_L.bomc'), 'saved model gets deterministic one-file BOMC path')
        assert(unsaved.end_with?('Untitled.bomc'), 'unsaved model gets deterministic BOMC filename')
        assert(BOMCExtension::DEFAULT_PROFILE == :production, 'production profile is the preferred default')
        assert(BOMCExtension::FORMAT_EXTENSION == '.bomc', 'compiled user-facing extension is stable')
        menu = FakeMenu.new
        BOMCExtension.register_menu(menu)
        assert(menu.labels == ['BOM Engine: Export Compiled BOMC...'], 'compiled export command registers without replacing legacy menus')

        output_dir = Dir.mktmpdir('bomc-extension-test')
        begin
          path = File.join(output_dir, 'nested', 'fixture.bomc')
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

exit(BOMEngine::Tests::BOMCExtensionTest.run ? 0 : 1)
