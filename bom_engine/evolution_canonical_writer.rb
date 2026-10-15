# frozen_string_literal: true

require_relative 'canonical_json_writer'
require_relative 'evolution_document'

module BOMEngine
  module EvolutionCanonicalWriter
    module_function

    def build(document)
      EvolutionDocument.validate!(document)
      graph = EvolutionDocument.graph_with_json_assets(document)
      graph['format'] ||= {}
      graph['format']['name'] = 'BOM Engine Canonical'
      graph['format']['version'] = '3.1.0'
      graph['format']['schema'] = 'https://sibambo.dev/schemas/bom-engine/3.1.0/schema.json'
      graph['evolution'] = EvolutionDocument.deep_copy(document.fetch('graph').fetch('evolution'))
      graph
    end

    def write(path, document)
      CanonicalJSONWriter.write(path, build(document), pretty: false, compress: true)
    end
  end
end
