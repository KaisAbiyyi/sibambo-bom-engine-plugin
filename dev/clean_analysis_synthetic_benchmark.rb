# frozen_string_literal: true

require 'digest'
require 'json'

runtime_root = ENV['BOM_ENGINE_BENCHMARK_ROOT'].to_s
runtime_root = File.expand_path('../bom_engine', __dir__) if runtime_root.empty?
require File.join(runtime_root, 'semantic_v2')
require File.join(runtime_root, 'clean_analysis')
require_relative '../bom_engine/tests/support/clean_analysis_completeness_fixture'

fixture = Object.new.extend(CleanAnalysisCompletenessFixture)
materials = 100.times.map { |index| fixture.material(index) }
box_points = [
  [[0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0]],
  [[0, 0, 3], [0, 4, 3], [4, 4, 3], [4, 0, 3]],
  [[0, 0, 0], [0, 0, 3], [4, 0, 3], [4, 0, 0]],
  [[4, 0, 0], [4, 0, 3], [4, 4, 3], [4, 4, 0]],
  [[4, 4, 0], [4, 4, 3], [0, 4, 3], [0, 4, 0]],
  [[0, 4, 0], [0, 4, 3], [0, 0, 3], [0, 0, 0]]
]
normals = [[0, 0, 1], [0, 0, -1], [0, 1, 0], [-1, 0, 0], [0, -1, 0], [1, 0, 0]]
root_faces = box_points.each_with_index.map do |points, index|
  fixture.polygon(
    definition_uuid: fixture.uuid(1),
    source_uuid: fixture.uuid(10 + index),
    points: points,
    normal: normals.fetch(index),
    material_uuid: materials.fetch(index % 3).source_uuid
  )
end
window_face = fixture.polygon(
  definition_uuid: fixture.uuid(100), source_uuid: fixture.uuid(101),
  points: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]], normal: [0, -1, 0],
  material_uuid: materials.fetch(1).source_uuid
)
unknown_face = fixture.polygon(
  definition_uuid: fixture.uuid(102), source_uuid: fixture.uuid(103),
  points: [[0, 0, 0], [0.5, 0, 0], [0.5, 0, 0.5], [0, 0, 0.5]], normal: [0, -1, 0],
  material_uuid: materials.fetch(2).source_uuid
)
excluded_face = fixture.polygon(
  definition_uuid: fixture.uuid(104), source_uuid: fixture.uuid(105),
  points: [[0, 0, 0], [1, 0, 0], [1, 0, 2], [0, 0, 2]], normal: [0, -1, 0],
  material_uuid: materials.fetch(20).source_uuid
)
window_path = [fixture.uuid(110)]
unknown_path = [fixture.uuid(111)]
excluded_path = [fixture.uuid(112)]
snapshot = fixture.document(
  root_primitives: root_faces,
  definitions: [
    fixture.definition(fixture.uuid(100), [window_face]),
    fixture.definition(fixture.uuid(102), [unknown_face]),
    fixture.definition(fixture.uuid(104), [excluded_face])
  ],
  primitives: [window_face, unknown_face, excluded_face],
  occurrences: [
    fixture.occurrence(path: window_path, definition_uuid: fixture.uuid(100)),
    fixture.occurrence(path: unknown_path, definition_uuid: fixture.uuid(102)),
    fixture.occurrence(path: excluded_path, definition_uuid: fixture.uuid(104))
  ],
  materials: materials,
  evidence: [
    fixture.label(window_path, 'Window', 'window'),
    fixture.label(unknown_path, 'Unknown Visible'),
    fixture.label(excluded_path, 'Sree Entourage')
  ]
)

document = if ENV['BOM_ENGINE_BENCHMARK_DEBUG'] == '1'
             BOMEngine::CleanAnalysis.compile(snapshot, debug: true)
           else
             BOMEngine::CleanAnalysis.compile(snapshot)
           end
json = BOMEngine::CleanAnalysis::Writer.generate(document)
all_material_records = materials.sort_by(&:source_uuid).map do |material|
  rgba = material.rgba.map do |channel|
    value = (channel.to_f / 255.0).round(9)
    value.zero? ? 0.0 : value
  end
  {
    'id' => "mat-#{Digest::SHA256.hexdigest(material.source_uuid)[0, 16]}",
    'name' => material.name,
    'base_color_rgba' => rgba,
    'opacity' => rgba.fetch(3),
    'color_space' => 'srgb',
    'texture' => nil
  }
end
hypothetical_unpruned_bytes = JSON.generate(document.merge('materials' => all_material_records)).bytesize
top_level_points = document.fetch('surfaces').flat_map do |surface|
  surface.fetch('outer') + surface.fetch('holes').flatten(1)
end
puts JSON.generate(
  'bytes' => json.bytesize,
  'hypothetical_unpruned_bytes' => hypothetical_unpruned_bytes,
  'material_pruning_saved_bytes' => hypothetical_unpruned_bytes - json.bytesize,
  'sha256' => Digest::SHA256.hexdigest(json),
  'materials' => document.fetch('materials').length,
  'surfaces' => document.fetch('surfaces').length,
  'definitions' => document.fetch('definitions').length,
  'instances' => document.fetch('instances').length,
  'components' => document.fetch('components').length,
  'fallback' => document.fetch('fallback_geometry').length,
  'top_level_vertex_occurrences' => top_level_points.length,
  'top_level_unique_vertices' => top_level_points.uniq.length,
  'coverage' => document.dig('diagnostics', 'coverage')
)
