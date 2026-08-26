# Run with standalone Ruby:
#   ruby bom_engine/tests/test_bomc_size_gate.rb

require 'fileutils'
require 'tmpdir'
require_relative '../bomc_size_gate'
require_relative '../bomc_decoder'

module SibamboHistory
  module V20260826_02
  module Tests
    module BOMCSizeGateTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        test_boundaries
        test_source_capture
        test_escalation_and_invariants
        test_failed_candidates_are_not_published
        puts 'BOMC Size Gate Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Size Gate Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def test_boundaries
        source = { available: true, bytes: 100 }
        assert(BOMCSizeGate.evaluate(candidate_bytes: 99, source_info: source) == :pass, 'strictly smaller candidate passes')
        assert(BOMCSizeGate.evaluate(candidate_bytes: 100, source_info: source) == :fail, 'equal-size candidate fails')
        assert(BOMCSizeGate.evaluate(candidate_bytes: 101, source_info: source) == :fail, 'larger candidate fails')
        assert(BOMCSizeGate.evaluate(candidate_bytes: 1, source_info: { available: false }) == :unavailable, 'unknown source size is explicit')
      end

      def test_source_capture
        directory = Dir.mktmpdir('bomc-source')
        begin
          path = File.join(directory, 'source.skp')
          File.open(path, 'wb') { |file| file.write('x' * 321) }
          info = BOMCSizeGate.source_info(path)
          File.open(path, 'ab') { |file| file.write('later') }
          assert(info[:available] && info[:bytes] == 321, 'source size is captured once from the saved SKP')
          assert(!BOMCSizeGate.source_info('')[:available], 'unsaved model reports unavailable source size')
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
        end
      end

      def test_escalation_and_invariants
        graph = graph_fixture
        standard = BOMCWriter.pack(graph, compression_level: 6, minimal_metadata: false)
        compact = BOMCWriter.pack(graph, compression_level: 9, minimal_metadata: false)
        events = []
        result = BOMCSizeGate.compile(
          graph: graph,
          source_info: { available: true, bytes: compact[:bytes].bytesize },
          base_path: nil,
          checkpoint: ->(**event) { events << event }
        )
        repeated = BOMCSizeGate.compile(
          graph: graph,
          source_info: { available: true, bytes: compact[:bytes].bytesize },
          base_path: nil
        )
        assert(result[:status] == :pass && result[:strategy] == :maximum_lossless, 'bounded escalation reaches minimal lossless metadata after equality fails')
        assert(result[:candidate_bytes] < standard[:bytes].bytesize, 'selected escalated candidate is strictly smaller than source')
        assert(result[:attempts].map { |attempt| attempt[:strategy] } == [:standard, :compact, :maximum_lossless], 'strategy order is deterministic and bounded')
        assert(events.count { |event| event[:stage] == :size_gate } == 3, 'each bounded strategy reports a size-gate checkpoint')
        assert(result[:sha256] == repeated[:sha256] && result[:attempts] == repeated[:attempts], 'compression escalation choice and bytes are deterministic')

        baseline = BOMCDecoder.decode(standard[:bytes])
        selected = BOMCDecoder.decode(result[:bytes])
        assert(selected[:coverage] == baseline[:coverage] && selected[:coverage][:unaccounted] == 0, 'escalation preserves complete coverage disposition')
        assert(selected[:meshes] == baseline[:meshes], 'escalation preserves geometry, topology, precision, and UV data')
        assert(selected[:materials] == baseline[:materials] && selected[:instances] == baseline[:instances], 'escalation preserves materials, semantics, and instances')
      end

      def test_failed_candidates_are_not_published
        directory = Dir.mktmpdir('bomc-gate')
        begin
          output = File.join(directory, 'result__SBE-2026.08.26-02.bomc')
          File.open(output, 'wb') { |file| file.write('keep-me') }
          error = nil
          begin
            BOMCSizeGate.compile(
              graph: graph_fixture,
              source_info: { available: true, bytes: 1 },
              base_path: nil,
              output_path: output
            )
          rescue BOMCSizeGate::TargetNotMet => caught
            error = caught
          end
          assert(!error.nil? && error.source_bytes == 1 && error.best_candidate_bytes > 1, 'unreachable target returns actionable source and best sizes')
          assert(error.delta_bytes == error.best_candidate_bytes - error.source_bytes, 'gate failure reports exact positive delta')
          assert(!error.dominant_sections.empty?, 'gate failure identifies dominant stored sections')
          assert(File.binread(output) == 'keep-me', 'failed candidates never replace an existing output')
          assert(Dir.glob(File.join(directory, '*.part')).empty?, 'failed size gate leaves no partial files')
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
        end
      end

      def graph_fixture
        identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        long_name = 'source-model-name-' + ('abcdef0123456789' * 64)
        {
          source: { file_name: long_name + '.skp', model_name: long_name },
          coordinate_system: { units: 'm', handedness: 'right', up_axis: 'Z' },
          materials: [], tags: [], meshes: [], transforms: [identity],
          definitions: [{ id: 'root-definition', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] }],
          nodes: [{ id: 'root-node', kind: 'root', name: 'Root', owner_definition_id: nil, definition_id: 'root-definition', transform_id: 0, visible: true }]
        }
      end
    end
  end
end

exit(SibamboHistory::V20260826_02::Tests::BOMCSizeGateTest.run ? 0 : 1)

end # SibamboHistory
