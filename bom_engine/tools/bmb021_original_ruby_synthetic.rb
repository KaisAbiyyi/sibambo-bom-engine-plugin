#!/usr/bin/env ruby
# STRICT synthetic original Ruby producer proof: zero SketchUp APIs or private SKPs.
require 'digest'
require 'json'
require 'base64'
require 'fileutils'
require_relative 'benchmark_bomc'

root = ENV.fetch('BMB021_RUBY_EXPORT_DIR')
producer_sha = ENV.fetch('BMB021_RUBY_SHA')
abort 'producer SHA must be full immutable commit' unless /\A[0-9a-f]{40}\z/.match?(producer_sha)

# Pure-Ruby test corpus constructor from the original repository, not a cloned
# Builder implementation, native SketchUp model, or owner artifact.
graph = BOMEngine::BOMCBenchmark.shared_graph(1)
packed = BOMEngine::BOMCWriter.pack(graph, profile: :production)
bytes = packed.fetch(:bytes)
decoded = BOMEngine::BOMCDecoder.decode(bytes)
BOMEngine::BOMCValidator.validate!(graph, decoded)

materials = graph.fetch(:materials)
meshes = graph.fetch(:meshes)
faces = meshes.flat_map { |mesh| mesh.fetch(:faces) }
manifest = {
  gate: 'BMB021_ORIGINAL_RUBY_PRODUCER',
  file: 'ruby-producer-synthetic.bomc',
  sha256: Digest::SHA256.hexdigest(bytes),
  byteSize: bytes.bytesize,
  sourceRepository: 'KaisAbiyyi/sibambo-bom-engine-plugin',
  sourceSha: producer_sha,
  originalEntrypoint: 'BOMEngine::BOMCWriter.pack',
  expected: {
    materials: materials.length,
    meshes: meshes.length,
    faces: faces.length,
    triangles: faces.sum { |f| f.fetch(:triangles).length / 3 },
    definitions: graph.fetch(:definitions).length,
    instances: graph.fetch(:nodes).length,
    frontBackDistinctFaces: faces.count { |f|
      f[:front_material_id] && f[:back_material_id] && f[:front_material_id] != f[:back_material_id]
    }
  }
}
FileUtils.mkdir_p(root)
File.binwrite(File.join(root, manifest[:file]), bytes)
File.write(File.join(root, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")
puts 'BMB021_RUBY_MANIFEST:' + JSON.generate(manifest)
if ENV['BMB021_PRINT_BASE64'] == '1'
  puts 'BMB021_RUBY_FIXTURE_BASE64:' + Base64.strict_encode64(bytes)
end
