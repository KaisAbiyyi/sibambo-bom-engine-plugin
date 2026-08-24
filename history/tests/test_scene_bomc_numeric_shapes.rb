# frozen_string_literal: true

root = File.expand_path('../..', __dir__)
engine = File.join(root, 'history', 'generated', 'SBE-2026.08.19-01', 'staged', 'bom_engine')
load File.join(engine, 'bomc_writer.rb')
load File.join(engine, 'bomc_decoder.rb')

identity = SibamboHistory::V20260819_01::BOMC::ModelAdapter::IDENTITY.dup
uv_outer = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
graph = {
  format: { name: 'BOM Engine Canonical', version: '3.0.0' },
  source: { file_name: 'large-scene-fixture.skp', model_name: 'Large scene fixture', scope: 'all' },
  coordinate_system: { units: 'm', handedness: 'right', up_axis: 'Z' },
  materials: [{
    id: 'mat-textured', name: 'Textured', color: { r: 255, g: 255, b: 255, a: 255 }, opacity: 1.0,
    texture: { bytes: "\x89PNG\r\n\x1a\nfixture".b, filename: 'fixture.png', width_m: 1.0, height_m: 1.0 }
  }],
  tags: [],
  transforms: [identity.each_slice(4).to_a],
  meshes: [{
    id: 'mesh-panel', definition_id: 'definition-panel',
    positions_m: [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]],
    faces: [{
      id: 'face-panel', outer: [0, 1, 2, 3], holes: [], triangles: [0, 1, 2, 0, 2, 3],
      front_material_id: 'mat-textured', normal: [[0.0, 0.0, 1.0]], area_m2: 1.0,
      surface_hint: 'wall', uv: { front_outer: [uv_outer], front_holes: [] }
    }],
    edges: []
  }],
  definitions: [
    { id: 'definition-root', name: 'Root', kind: 'model_definition', node_ids: ['node-panel', 'node-image'] },
    { id: 'definition-panel', name: 'Panel', kind: 'component_definition', mesh_id: 'mesh-panel', node_ids: [] }
  ],
  nodes: [
    { id: 'node-root', kind: 'root', name: 'Root', definition_id: 'definition-root', transform_id: 0, visible: true },
    { id: 'node-panel', kind: 'component_instance', name: 'Panel', owner_definition_id: 'definition-root', definition_id: 'definition-panel', transform_id: 0, visible: true },
    {
      id: 'node-image', kind: 'image', name: 'Reference image', owner_definition_id: 'definition-root',
      transform_id: 0, visible: true,
      image: {
        filename: 'reference.png', bytes: "\x89PNG\r\n\x1a\nreference".b,
        width_m: 2.0, height_m: 1.0, position: { x: 1.25, y: 2.5, z: 0.75 }
      }
    }
  ],
  scenes: [{
    id: 'scene:1', name: 'Scene 1', is_active_at_export: true,
    camera: {
      projection: 'perspective', eye_m: [[2.0, 2.0, 2.0]], target_m: [[0.0, 0.0, 0.0]],
      up: [[0.0, 0.0, 1.0]], field_of_view_degrees: 35.0, aspect_ratio: 1.5
    },
    transition_time_seconds: 0.0, visibility: {}
  }]
}

packed = SibamboHistory::V20260819_01::BOMCWriter.pack(graph)
decoded = SibamboHistory::V20260819_01::BOMCDecoder.decode(packed.fetch(:bytes))
face = decoded.fetch(:meshes).first.fetch(:faces).first
scene = decoded.fetch(:scenes).first
image = decoded.fetch(:fallback).find { |row| row[:kind] == 'image' }

raise "nested UV loop was not normalized: #{face[:uv].inspect}" unless face.dig(:uv, :front_outer) == uv_outer
raise "nested scene camera was not normalized: #{scene.inspect}" unless scene.dig(:camera, :eye_m) == [2.0, 2.0, 2.0]
raise "image position hash was not normalized: #{image.inspect}" unless image && image[:position] == [1.25, 2.5, 0.75]

def assert_invalid_shape(graph, expected)
  candidate = Marshal.load(Marshal.dump(graph))
  yield(candidate)
  begin
    SibamboHistory::V20260819_01::BOMCWriter.pack(candidate)
  rescue ArgumentError => error
    return if error.message.include?(expected)

    raise "expected validation error containing #{expected.inspect}; got #{error.message.inspect}"
  end
  raise "expected validation error containing #{expected.inspect}; export succeeded"
end

assert_invalid_shape(graph, 'image.position uses unsupported coordinate keys') do |candidate|
  candidate[:nodes].last[:image][:position] = { x: 1.0, y: 2.0 }
end
assert_invalid_shape(graph, 'transform must contain exactly 16 numbers') do |candidate|
  candidate[:transforms] = [identity.first(15)]
end
assert_invalid_shape(graph, 'mesh.positions_m must contain a multiple of 3 numbers') do |candidate|
  candidate[:meshes].first[:positions_m] << [42.0]
end
assert_invalid_shape(graph, 'scene.camera.eye_m[0] must be a finite number') do |candidate|
  candidate[:scenes].first[:camera][:eye_m] = [Float::INFINITY, 0.0, 0.0]
end

puts 'scene BOMC numeric shapes: PASS (nested vectors and coordinate hashes normalize; malformed shapes fail safely)'
