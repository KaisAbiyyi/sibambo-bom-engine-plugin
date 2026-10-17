# frozen_string_literal: true

require_relative 'canonical_json_writer'
require_relative 'evolution_document'
require_relative 'performance_trace'

module BOMEngine
  module EvolutionCanonicalWriter
    module_function

    def build(document)
      PerformanceTrace.stage(:e2_payload) do
        EvolutionDocument.validate!(document)
        graph = EvolutionDocument.graph_with_json_assets(document)
        graph['format'] ||= {}
        graph['format']['name'] = 'BOM Engine Canonical'
        graph['format']['version'] = '3.1.0'
        graph['format']['schema'] = 'https://sibambo.dev/schemas/bom-engine/3.1.0/schema.json'
        graph['evolution'] = EvolutionDocument.deep_copy(document.fetch('graph').fetch('evolution'))
        graph
      end
    end

    def write(path, document)
      PerformanceTrace.stage(:e2_serialize) do
        CanonicalJSONWriter.write(path, build(document), pretty: false, compress: true)
      end
    end
  end
end
