# Run with standalone Ruby:
#   ruby bom_engine_plugin/bom_engine/tests/test_model_eval_json_writer.rb

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative '../quantizer'
require_relative '../model_eval_json_writer'

module SibamboHistory
  module V20260827_01
  module Tests
    module ModelEvalJSONWriterTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        graph = JSON.parse(File.read(File.expand_path('../../examples/canonical-v3-small.json', __dir__)), symbolize_names: true)
        add_semantic_fixture(graph)
        temp_dir = Dir.mktmpdir('model-eval-json-writer')
        path = File.join(temp_dir, 'fixture__SBE-2026.08.27-01_model-eval.json')
        result = ModelEvalJSONWriter.write(path, graph)
        bytes = File.binread(path)
        payload = JSON.parse(bytes.force_encoding(Encoding::UTF_8), symbolize_names: true)

        assert(path.end_with?('__SBE-2026.08.27-01_model-eval.json'), 'deterministic compact filename contract')
        assert(bytes.byteslice(0, 2) != "\x1f\x8b", 'plain JSON is not gzip')
        assert(!bytes.include?("\n"), 'output is minified')
        assert(payload.dig(:format, :identifier) == 'model_eval_json_v1', 'format identifier')
        assert(payload.dig(:format, :version) == '1.1.0', 'format version')
        assert(payload[:strings].uniq.length == payload[:strings].length, 'string table is deduplicated')
        assert(payload[:meshes][0][:positions].all? { |value| value.is_a?(Integer) }, 'quantized integer positions')
        assert(payload[:meshes][0].dig(:quantization, :measured_max_error_m) <= 0.001, 'quantization error bound')
        assert(payload[:meshes][0][:faces][0].length == 16, 'compact face row includes semantic fields')
        assert(payload[:nodes][0].length == 13, 'compact node row includes semantic fields')
        assert(payload[:strings][payload[:nodes][0][9]] == 'Lantai Utama', 'semantic label survives compaction')
        assert(payload[:strings][payload[:nodes][0][11]] == 'floor', 'semantic role survives compaction')
        assert(payload[:statistics][:labeled_nodes] == 1, 'semantic coverage is reported')
        assert(payload[:statistics][:geometry_fallback_nodes] == 0, 'labeled node is not blind-classified')
        assert(!payload.key?(:scenes) && !payload.key?(:analysis) && !payload.key?(:metadata), 'verbose optional payload omitted')
        validation = ModelEvalJSONWriter.validate(payload)
        assert(validation[:triangles] > 0, 'table references validate')
        assert(result[:bytes] == File.size(path), 'writer reports bytes')

        destructive_graph = JSON.parse(File.read(File.expand_path('../../examples/canonical-v3-small.json', __dir__)), symbolize_names: true)
        add_semantic_fixture(destructive_graph)
        destructive_path = File.join(temp_dir, 'fixture_destructive__SBE-2026.08.27-01_model-eval.json')
        progress_stages = []
        destructive_result = ModelEvalJSONWriter.write(
          destructive_path,
          destructive_graph,
          destructive: true,
          include_payload: false,
          progress: ->(event) { progress_stages << event[:stage] }
        )
        assert(File.binread(destructive_path) == bytes, 'low-memory destructive writer preserves exact JSON contract')
        assert(!destructive_result.key?(:payload), 'low-memory result does not retain payload')
        assert(destructive_graph.dig(:format, :identifier) == 'model_eval_json_v1', 'destructive graph becomes valid compact payload')
        assert(progress_stages.include?('Model-Eval payload ready'), 'cooperative progress callback is emitted')
        puts 'Model-Eval JSON Writer Tests: ALL PASSED'
      ensure
        FileUtils.remove_entry(temp_dir) if temp_dir && Dir.exist?(temp_dir)
      end

      def add_semantic_fixture(graph)
        graph[:nodes][0][:semantic] = {
          label: 'Lantai Utama',
          source: 'instance_name',
          role: 'floor',
          classification_policy: 'label_first',
          aliases: ['Lantai Utama']
        }
        graph[:meshes][0][:faces][0][:semantic] = {
          label: nil,
          source: 'none',
          role: nil,
          classification_policy: 'geometry_fallback',
          aliases: []
        }
        graph[:nodes] << {
          id: 'node:text:annotation',
          kind: 'text',
          name: 'Lantai Utama',
          definition_id: nil,
          transform_id: 0,
          material_override_id: nil,
          tag_id: nil,
          source_identity: { persistent_id: 'annotation-1' }
        }
        graph[:definitions][0][:node_ids] << 'node:text:annotation'
      end
    end
  end
end

SibamboHistory::V20260827_01::Tests::ModelEvalJSONWriterTest.run

end # SibamboHistory
