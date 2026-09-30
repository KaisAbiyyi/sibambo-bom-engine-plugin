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
        assert(
          saved.tr('\\', '/').end_with?('/model-eval-exports/RUMAH_L__SIBAMBO-BOMC-v1.2.0__VISUAL.bomc'),
          'saved model gets deterministic version-tagged BOMC path'
        )
        assert(
          unsaved.end_with?('Untitled__SIBAMBO-BOMC-v1.2.0__VISUAL.bomc'),
          'unsaved model gets deterministic version-tagged BOMC filename'
        )
        dialog = BOMCExtension.normalize_dialog_settings(
          output_path: 'D:/exports/RUMAH_L.bomc',
          profile: 'research',
          batch_size: '1024'
        )
        assert(
          dialog[:output_path].tr('\\', '/').end_with?('/RUMAH_L__SIBAMBO-BOMC-v1.2.0__RESEARCH.bomc'),
          'dialog enforces current extension version tag'
        )
        assert(dialog[:profile] == :research, 'dialog profile reaches exporter')
        assert(BOMCExtension.normalize_output_path('D:/exports/house.skp', profile: :exact).end_with?('/house__SIBAMBO-BOMC-v1.2.0__EXACT.bomc'),
          'typed SKP source path produces a clean BOMC filename')
        assert(
          dialog.dig(:processing, :mode) == :custom &&
            dialog.dig(:processing, :max_items) == 1024 &&
            dialog.dig(:processing, :max_items_limit) == 1024,
          'dialog batch control reaches cooperative processing settings'
        )
        assert(BOMCExtension::DEFAULT_PROFILE == :visual, 'visual profile is the preferred web-first default')
        assert(BOMCExtension::FORMAT_EXTENSION == '.bomc', 'compiled user-facing extension is stable')
        assert(ConversionJob::TIMER_INTERVAL_SECONDS <= 0.001, 'cooperative runner resumes work without a 10 ms idle tax')
        assert(ConversionJob::UI_PROGRESS_INTERVAL_SECONDS >= 0.05, 'HTML progress rendering is throttled independently from work scheduling')
        [:exact, :research, :visual].each do |profile|
          filename = BOMCExtension.normalize_output_path(
            'D:/exports/House__SIBAMBO-BOMC-v1.2.0__VISUAL.bomc', profile: profile
          )
          assert(filename.end_with?("House__SIBAMBO-BOMC-v1.2.0__#{profile.to_s.upcase}.bomc"), "profile #{profile} has one normalized filename suffix")
        end
        seen_profile = nil
        gate_singleton = class << BOMCSizeGate; self; end
        original_compile = gate_singleton.instance_method(:compile)
        gate_singleton.define_method(:compile) do |**kwargs|
          seen_profile = kwargs[:profile]
          { path: kwargs[:output_path], candidate_bytes: 1, bytes: 'x', savings_bytes: 0 }
        end
        context = nil
        begin
          context = BOMCExtension.send(:export_context, 'fixture.bomc', ->(_event) {}, profile: :exact)
          context[:compile].call({}, {}, 'fixture.bomc', ->(_event) {})
        ensure
          gate_singleton.define_method(:compile, original_compile)
          context[:cleanup].call if context
        end
        assert(seen_profile == :exact, 'interactive export context propagates selected profile into size gate compiler')
        [:exact, :research, :visual].each do |profile|
          decoded = BOMCDecoder.decode(BOMCWriter.pack(fixture_graph, profile: profile)[:bytes])
          assert(decoded.dig(:encoding_contract, :profile) == profile, "Section 20 preserves #{profile} profile")
        end
        assert(BOMCExtension.send(:resolve_jpeg_color_map, :exact, nil) == true,
          'standard Exact enables the verified JPEG color-map candidate automatically')
        assert(BOMCExtension.send(:resolve_jpeg_color_map, :research, nil) == false,
          'Research does not enable the Exact-only JPEG color-map codec')
        assert(BOMCExtension.send(:resolve_jpeg_color_map, :exact, false) == false,
          'callers can explicitly disable JPEG color-map compatibility for legacy consumers')
        menu = FakeMenu.new
        BOMCExtension.register_menu(menu)
        assert(
          menu.labels == ['Sibambo BOMC Engine: Export BOMC 1.2...', 'About Sibambo BOMC Engine'],
          'JCM is part of standard Exact and no longer needs a separate experimental menu'
        )

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
