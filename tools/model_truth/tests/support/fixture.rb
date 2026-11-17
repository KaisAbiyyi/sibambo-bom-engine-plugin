# frozen_string_literal: true

# Neutral model description (inches, SketchUp style) from which the tests derive
# BOTH the hand-built BOMC "decoded" Hash and the mock SketchUp model, so the two
# sides have equal content by construction.

require 'digest'
require 'json'
require_relative '../../canonical'

module MTFixture
  INCH = 0.0254

  module_function

  def m(v)
    (v.to_f * INCH).round(9)
  end

  # Fresh spec each call (tests mutate copies).
  def spec
    {
      tags: [{ name: 'Walls', visible: true }, { name: 'Hidden', visible: false }],
      textures: [{ media: :jpeg, w: 2, h: 2, bgr_true: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120] }],
      materials: [
        { name: 'Brick', color: [200, 100, 50, 255], opacity: 1.0, type: 1, texture: 0, tex_w_in: 40.0, tex_h_in: 20.0 },
        { name: 'Paint', color: [10, 20, 30, 255], opacity: 0.5, type: 0, texture: nil }
      ],
      defs: [
        {
          kind: 'root',
          faces: [
            { loops: [[[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]]], tris: [[0, 1, 2], [0, 2, 3]], normal: [0, 0, 1],
              front: 0, back: nil, tag: 0, hidden: false,
              uv_front: [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]], uv_back: nil }
          ],
          extra_edges: [{ a: [20, 0, 0], b: [30, 0, 0], tag: 1, hidden: true, soft: false, smooth: false }],
          nodes: [
            { type: :component, def: 1, t: [0, 0, 0], material: nil, tag: 0 },
            { type: :component, def: 1, t: [100, 0, 0], material: 1, tag: nil },
            { type: :group, def: 2, t: [0, 50, 0], material: nil, tag: 0 },
            { type: :image, t: [0, 5, 0], tag: nil },
            { type: :text, text: "Hello \u00e9", t: [1, 2, 3], tag: 1 }
          ]
        },
        {
          kind: 'component',
          faces: [
            { loops: [[[0, 0, 0], [6, 0, 0], [0, 6, 0]]], tris: [[0, 1, 2]], normal: [0, 0, 1],
              front: nil, back: 1, tag: nil, hidden: false, uv_front: nil, uv_back: nil }
          ],
          extra_edges: [],
          nodes: []
        },
        {
          kind: 'group',
          faces: [
            { loops: [[[0, 0, 0], [20, 0, 0], [20, 20, 0], [0, 20, 0]], [[5, 5, 0], [15, 5, 0], [15, 15, 0], [5, 15, 0]]],
              tris: [[0, 1, 5], [1, 2, 6], [2, 3, 7], [3, 0, 4]], normal: [0, 0, 1],
              front: nil, back: nil, tag: 0, hidden: true, uv_front: nil, uv_back: nil }
          ],
          extra_edges: [],
          nodes: []
        }
      ]
    }
  end

  # Canonical SHA of the colorized (displayed) image of a fixture texture.
  def output_sha(t)
    SibamboModelTruthV1::Canonical.canonical_rgba_sha(width: t[:w], height: t[:h], bits_per_pixel: 24, row_padding: 0,
                                                      data: t[:bgr_true].pack('C*'), platform: :win)[:sha256]
  end

  def t16_m(t)
    [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, m(t[0]), m(t[1]), m(t[2]), 1.0]
  end

  # Every closed loop of every face contributes its boundary edges (as SketchUp
  # does), then the definition's extra edges.
  def edge_list(defn)
    list = []
    defn[:faces].each do |f|
      f[:loops].each do |lp|
        lp.each_with_index do |p, i|
          list << { a: p, b: lp[(i + 1) % lp.length], tag: f[:tag], hidden: f[:hidden], soft: false, smooth: false }
        end
      end
    end
    list + defn[:extra_edges]
  end

  def decoded(spec = self.spec)
    materials = spec[:materials].map do |mat|
      {
        name: mat[:name], color: { r: mat[:color][0], g: mat[:color][1], b: mat[:color][2], a: mat[:color][3] },
        opacity: (mat[:opacity] * 65_535).round / 65_535.0, texture: mat[:texture],
        texture_width_m: mat[:texture] ? m(mat[:tex_w_in]) : nil, texture_height_m: mat[:texture] ? m(mat[:tex_h_in]) : nil,
        material_type: mat[:type], semantic_colorize_active: !mat[:semantic].nil?,
        colorize_type: mat[:semantic] && mat[:semantic][:type],
        colorize_deltas: mat[:semantic] && { h: mat[:semantic][:deltas][0], l: mat[:semantic][:deltas][1], s: mat[:semantic][:deltas][2] },
        colorize_output_sha256: mat[:semantic] && output_sha(spec[:textures][mat[:texture]])
      }
    end
    tags = spec[:tags].each_with_index.map { |t, i| { id: "tag:#{i}", name: t[:name], visible: t[:visible] } }
    textures = spec[:textures].map do |t|
      bytes = JSON.generate('w' => t[:w], 'h' => t[:h], 'bgr' => t[:bgr_false] || t[:bgr_true]).b
      { media_type: t[:media], image_width_px: t[:w], image_height_px: t[:h], sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes }
    end

    transforms = [t16_m([0, 0, 0])]
    meshes = []
    definitions = []
    instances = [{ kind: 'root', owner_definition: nil, definition: 0, transform: 0, material: nil, tag: nil, visible: true, fallback: false, name: 'root' }]
    node_ids = Hash.new { |h, k| h[k] = [] }

    spec[:defs].each_with_index do |defn, di|
      positions = []
      index = {}
      intern = lambda do |p|
        key = p.map { |v| m(v) }
        index[key] ||= begin
          positions.concat(key)
          index.size
        end
      end
      faces = defn[:faces].map do |f|
        all_pts = f[:loops].flatten(1)
        point_idx = all_pts.map { |p| intern.call(p) }
        cursor = 0
        loop_idx = f[:loops].map { |lp| r = point_idx[cursor, lp.length]; cursor += lp.length; r }
        uv = nil
        uv = { front_outer: f[:uv_front]&.map(&:dup), front_holes: [], back_outer: f[:uv_back]&.map(&:dup), back_holes: [] } if f[:uv_front] || f[:uv_back]
        {
          outer: loop_idx[0], holes: loop_idx[1..-1], triangles: f[:tris].flatten.map { |i| point_idx[i] },
          normal: f[:normal].map(&:to_f), area_m2: 0.0, front_material: f[:front], back_material: f[:back], tag: f[:tag],
          hidden: f[:hidden], fallback: false, has_front_uv: !f[:uv_front].nil?, has_back_uv: !f[:uv_back].nil?, uv: uv
        }
      end
      edges = edge_list(defn).map do |e|
        { vertices: [intern.call(e[:a]), intern.call(e[:b])], tag: e[:tag], hidden: e[:hidden], soft: e[:soft], smooth: e[:smooth] }
      end
      mesh_idx = nil
      unless faces.empty? && edges.empty?
        meshes << { positions: positions, faces: faces, edges: edges }
        mesh_idx = meshes.length - 1
      end
      kind = { 'root' => 'model_definition', 'component' => 'component_definition', 'group' => 'group_definition' }.fetch(defn[:kind])
      definitions << { kind: kind, name: "def#{di}", mesh: mesh_idx, nodes: [] }
      defn[:nodes].each do |n|
        transforms << t16_m(n[:t])
        inst = { owner_definition: di, transform: transforms.length - 1, material: n[:material], tag: n[:tag], visible: true, fallback: false, name: nil }
        case n[:type]
        when :component then inst.merge!(kind: 'component_instance', definition: n[:def])
        when :group then inst.merge!(kind: 'group_instance', definition: n[:def])
        when :image then inst.merge!(kind: 'image', definition: nil)
        when :text then inst.merge!(kind: 'text', definition: nil, name: n[:text])
        end
        instances << inst
        node_ids[di] << instances.length - 1
      end
    end
    node_ids.each { |di, ids| definitions[di][:nodes] = ids }

    {
      materials: materials, tags: tags, transforms: transforms, meshes: meshes, definitions: definitions, instances: instances,
      root_node: 0, textures: textures, fallback: [],
      encoding_contract: { profile: :exact, position_max_error_m: 0.0, normal_max_error_deg: 0.0, uv_max_error: 0.0,
                           transform_max_error: 0.0, texture_policy: :pixel_lossless }
    }
  end

  def corpus_row(skp_sha = 'a' * 64)
    {
      'model' => 'Fixture Model', 'skpSha256' => skp_sha, 'skp' => { 'path' => 'D:/fixture.skp' },
      'exact' => { 'path' => 'D:/fixture.bomc', 'sha256' => 'b' * 64, 'producerSourceSha256' => '3f2d314a3a0147ce56914537ef98fd0b77068bb680bcb0000f4b554d44f523a1', 'sourceSha256' => skp_sha }
    }
  end
end
