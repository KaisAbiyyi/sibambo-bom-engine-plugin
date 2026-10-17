# frozen_string_literal: true

require_relative 'evolution_document'
require_relative 'evolution_stream'
require_relative 'performance_trace'
require 'zlib'

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
        EvolutionDocument.validate!(document)
        graph = document.fetch('graph')
        format = PerformanceTrace.stage(:e2_payload) do
          value = EvolutionDocument.deep_copy(graph['format'] || {})
          value['name'] = 'BOM Engine Canonical'
          value['version'] = '3.1.0'
          value['schema'] = 'https://sibambo.dev/schemas/bom-engine/3.1.0/schema.json'
          value
        end
        result = nil
        File.open(path, 'wb') do |file|
          digest_io = EvolutionStream::DigestIO.new(file)
          gzip = Zlib::GzipWriter.new(digest_io)
          gzip.mtime = 0
          write_graph(gzip, graph, format, document.fetch('assets'))
          gzip.finish
          digest_io.flush
          result = { path: path, bytes: digest_io.bytes, sha256: digest_io.sha256 }
        end
        result
      end
    end

    def write_graph(io, graph, format, assets)
      io.write('{')
      first = true
      wrote_assets = false
      graph.each do |key, value|
        io.write(',') unless first
        first = false
        io.write(JSON.generate(key.to_s))
        io.write(':')
        if key.to_s == 'format'
          EvolutionStream.write_json(io, format)
        elsif key.to_s == 'evolution'
          EvolutionStream.write_json(io, graph.fetch('evolution'))
        elsif key.to_s == 'assets'
          EvolutionStream.write_assets(io, assets)
          wrote_assets = true
        else
          EvolutionStream.write_json(io, value)
        end
      end
      unless wrote_assets
        io.write(',') unless first
        io.write(JSON.generate('assets'))
        io.write(':')
        EvolutionStream.write_assets(io, assets)
      end
      io.write('}')
    end
    private_class_method :write_graph
  end
end
