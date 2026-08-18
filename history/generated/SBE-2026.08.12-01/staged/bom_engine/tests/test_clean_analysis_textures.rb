# frozen_string_literal: true

require 'digest'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require 'zlib'

require_relative '../semantic_v2'
require_relative '../clean_analysis'
require_relative 'support/clean_analysis_completeness_fixture'

class CleanAnalysisTexturesTest < Minitest::Test
  include CleanAnalysisCompletenessFixture

  PNG_BYTES = "\x89PNG\r\n\x1a\nsynthetic-texture".b.freeze
  OTHER_BYTES = "\x89PNG\r\n\x1a\nsecond-texture".b.freeze

  def test_one_textured_face_emits_content_asset_and_indexed_front_uv
    material = textured_material(1, 'Brick', [255, 255, 255, 255])
    face = textured_face(uuid(1), uuid(20), material.source_uuid)
    bundle = texture_bundle
    asset = bundle.register_texture(
      material_uuid: material.source_uuid, bytes: PNG_BYTES, extension: 'png',
      width_m: 1.0, height_m: 0.5
    )
    bundle.register_uv(
      primitive_key: face.key,
      front: uv_mapping([[0, 0], [2, 0], [2, 1], [0, 1]])
    )

    result = compile_document([face], [material], bundle)

    assert_equal "assets/tex-#{Digest::SHA256.hexdigest(PNG_BYTES)}.png", asset
    assert_equal asset, result.dig('materials', 0, 'texture', 'asset')
    assert_equal [[0.0, 0.0], [2.0, 0.0], [2.0, 1.0], [0.0, 1.0]], result.fetch('uvs')
    assert_equal [0, 1, 2, 3], result.dig('surfaces', 0, 'front_uv', 'outer')
  end

  def test_identical_texture_bytes_used_by_many_faces_create_one_asset
    materials = 2.times.map { |index| textured_material(index + 1, "Shared #{index}", [255, 255, 255, 255]) }
    faces = 20.times.map do |index|
      textured_face(uuid(1), uuid(30 + index), materials.fetch(index % 2).source_uuid, x: index * 2)
    end
    bundle = texture_bundle
    materials.each do |material|
      bundle.register_texture(
        material_uuid: material.source_uuid, bytes: PNG_BYTES, extension: 'png',
        width_m: 1.0, height_m: 1.0
      )
    end

    result = compile_document(faces, materials, bundle)

    assert_equal 1, bundle.assets.length
    assert_equal 1, result.fetch('materials').map { |item| item.dig('texture', 'asset') }.uniq.length
  end

  def test_one_hundred_textured_instances_keep_one_definition_and_asset
    material = textured_material(1, 'Instance Fabric', [200, 200, 200, 255])
    face = textured_face(uuid(100), uuid(101), nil)
    shared = definition(uuid(100), [face])
    occurrences = 100.times.map do |index|
      occurrence(
        path: [uuid(200 + index)], definition_uuid: shared.source_uuid,
        translation: [index * 2, 0, 0], material_uuid: material.source_uuid
      )
    end
    snapshot_document = document(
      root_primitives: [], definitions: [shared], primitives: [face],
      occurrences: occurrences, materials: [material], evidence: []
    )
    bundle = texture_bundle
    bundle.register_texture(
      material_uuid: material.source_uuid, bytes: PNG_BYTES, extension: 'png',
      width_m: 0.5, height_m: 0.5
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(snapshot_document, texture_data: bundle)

    assert_equal 1, result.fetch('definitions').length
    assert_equal 1, result.dig('definitions', 0, 'geometry', 'surfaces').length
    assert_equal 100, result.fetch('instances').length
    assert_equal 1, bundle.assets.length
    assert_equal 1, result.fetch('instances').map { |item| item.fetch('material_id') }.uniq.length
  end

  def test_uv_rotation_and_scale_are_preserved_without_recalculation
    material = textured_material(1, 'Rotated', [255, 255, 255, 255])
    face = textured_face(uuid(1), uuid(60), material.source_uuid)
    bundle = texture_bundle
    bundle.register_texture(
      material_uuid: material.source_uuid, bytes: PNG_BYTES, extension: 'png',
      width_m: 2.0, height_m: 1.0
    )
    rotated_scaled = [[1.0, 2.0], [1.0, 4.0], [-3.0, 4.0], [-3.0, 2.0]]
    bundle.register_uv(primitive_key: face.key, front: uv_mapping(rotated_scaled))

    result = compile_document([face], [material], bundle)
    indices = result.dig('surfaces', 0, 'front_uv', 'outer')

    assert_equal rotated_scaled, indices.map { |index| result.fetch('uvs').fetch(index) }
  end

  def test_front_and_back_texture_uvs_remain_distinct
    front = textured_material(1, 'Front', [255, 255, 255, 255])
    back = textured_material(2, 'Back', [255, 255, 255, 128])
    face = textured_face(uuid(1), uuid(70), front.source_uuid, back_material_uuid: back.source_uuid)
    bundle = texture_bundle
    bundle.register_texture(material_uuid: front.source_uuid, bytes: PNG_BYTES, extension: 'png', width_m: 1, height_m: 1)
    bundle.register_texture(material_uuid: back.source_uuid, bytes: OTHER_BYTES, extension: 'png', width_m: 2, height_m: 2)
    bundle.register_uv(
      primitive_key: face.key,
      front: uv_mapping([[0, 0], [1, 0], [1, 1], [0, 1]]),
      back: uv_mapping([[0, 0], [0, 2], [2, 2], [2, 0]])
    )

    result = compile_document([face], [front, back], bundle)
    surface = result.fetch('surfaces').first

    refute_equal surface.fetch('front_material_id'), surface.fetch('back_material_id')
    refute_equal surface.dig('front_uv', 'outer'), surface.dig('back_uv', 'outer')
    assert_equal 0.501960784, result.fetch('materials').find { |item| item.fetch('name') == 'Back' }.fetch('opacity')
  end

  def test_missing_texture_asset_keeps_base_color_and_explicit_status
    material = textured_material(1, 'Unavailable', [10, 20, 30, 255])
    face = textured_face(uuid(1), uuid(80), material.source_uuid)
    bundle = texture_bundle
    bundle.register_missing(material_uuid: material.source_uuid, reason: 'texture_write_failed')

    result = compile_document([face], [material], bundle)
    emitted = result.fetch('materials').first

    assert_equal [0.039215686, 0.078431373, 0.117647059, 1.0], emitted.fetch('base_color_rgba')
    assert_equal 'missing', emitted.dig('texture', 'status')
    assert_equal 'texture_write_failed', emitted.dig('texture', 'reason')
  end

  def test_excluded_texture_is_not_packaged_and_json_contains_no_embedded_data
    kept = textured_material(1, 'Kept', [255, 255, 255, 255])
    excluded = textured_material(2, 'Excluded', [255, 255, 255, 255])
    kept_face = textured_face(uuid(1), uuid(90), kept.source_uuid)
    excluded_face = textured_face(uuid(120), uuid(121), excluded.source_uuid)
    excluded_path = [uuid(122)]
    snapshot_document = document(
      root_primitives: [kept_face],
      definitions: [definition(uuid(120), [excluded_face])], primitives: [excluded_face],
      occurrences: [occurrence(path: excluded_path, definition_uuid: uuid(120))],
      materials: [kept, excluded], evidence: [label(excluded_path, 'Sree Entourage')]
    )
    bundle = texture_bundle
    bundle.register_texture(material_uuid: kept.source_uuid, bytes: PNG_BYTES, extension: 'png', width_m: 1, height_m: 1)
    bundle.register_texture(material_uuid: excluded.source_uuid, bytes: OTHER_BYTES, extension: 'png', width_m: 1, height_m: 1)
    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(snapshot_document, texture_data: bundle)

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'fixture.clean.zip')
      stats = SibamboHistory::V20260812_01::CleanAnalysis::VisualPackage.write(path, result, bundle.assets)
      bytes = File.binread(path)

      assert_equal 1, stats.fetch(:unique_texture_count)
      assert_includes bytes, result.dig('materials', 0, 'texture', 'asset')
      refute_includes bytes, Digest::SHA256.hexdigest(OTHER_BYTES)
      refute_match(/data:image|;base64/i, SibamboHistory::V20260812_01::CleanAnalysis::Writer.generate(result))
    end
  end

  def test_model_json_and_asset_names_are_deterministic
    material = textured_material(1, 'Stable', [255, 255, 255, 255])
    face = textured_face(uuid(1), uuid(130), material.source_uuid)
    build = lambda do
      bundle = texture_bundle
      bundle.register_texture(material_uuid: material.source_uuid, bytes: PNG_BYTES, extension: '.PNG', width_m: 1, height_m: 1)
      bundle.register_uv(primitive_key: face.key, front: uv_mapping([[0, 0], [1, 0], [1, 1], [0, 1]]))
      result = compile_document([face], [material], bundle)
      [SibamboHistory::V20260812_01::CleanAnalysis::Writer.generate(result), bundle]
    end

    first_json, first_bundle = build.call
    second_json, second_bundle = build.call

    assert_equal first_json, second_json
    assert_equal first_bundle.assets.keys, second_bundle.assets.keys
    assert_match(%r{\Aassets/tex-[0-9a-f]{64}\.png\z}, first_bundle.assets.keys.first)
  end

  def test_json_only_mode_keeps_legacy_texture_reference_and_has_no_uv_pool
    material = textured_material(1, 'Legacy JSON', [255, 255, 255, 255])
    face = textured_face(uuid(1), uuid(140), material.source_uuid)
    snapshot_document = document(
      root_primitives: [face], definitions: [], primitives: [], occurrences: [],
      materials: [material], evidence: []
    )

    result = SibamboHistory::V20260812_01::CleanAnalysis.compile(snapshot_document)

    refute result.key?('uvs')
    assert_equal 'Legacy JSON.png', result.dig('materials', 0, 'texture', 'reference')
    refute result.fetch('surfaces').first.key?('front_uv')
  end

  def test_visual_zip_bytes_and_reported_reference_dedup_are_deterministic
    material = textured_material(1, 'Repeated', [255, 255, 255, 255])
    faces = 5.times.map { |index| textured_face(uuid(1), uuid(150 + index), material.source_uuid, x: index * 2) }
    bundle = texture_bundle
    bundle.register_texture(material_uuid: material.source_uuid, bytes: PNG_BYTES, extension: 'png', width_m: 1, height_m: 1)
    result = compile_document(faces, [material], bundle)

    Dir.mktmpdir do |directory|
      first = File.join(directory, 'first.zip')
      second = File.join(directory, 'second.zip')
      stats = SibamboHistory::V20260812_01::CleanAnalysis::VisualPackage.write(first, result, bundle.assets)
      SibamboHistory::V20260812_01::CleanAnalysis::VisualPackage.write(second, result, bundle.assets)

      assert_equal File.binread(first), File.binread(second)
      assert_equal 5, stats.fetch(:original_texture_references)
      assert_equal 5.0, stats.fetch(:dedup_ratio)
    end
  end

  def test_visual_package_deflates_minified_model_and_stores_png_assets
    material = textured_material(1, 'Compressed', [255, 255, 255, 255])
    face = textured_face(uuid(1), uuid(170), material.source_uuid)
    bundle = texture_bundle
    bundle.register_texture(material_uuid: material.source_uuid, bytes: PNG_BYTES, extension: 'png', width_m: 1, height_m: 1)
    result = compile_document([face], [material], bundle)
    expected_json = SibamboHistory::V20260812_01::CleanAnalysis::Writer.generate(result)

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'compressed.clean.zip')
      SibamboHistory::V20260812_01::CleanAnalysis::VisualPackage.write(path, result, bundle.assets)
      entries = read_zip_entries(path)
      model = entries.fetch('model.json')
      asset_path = bundle.assets.keys.first

      assert_equal 8, model.fetch(:method), 'model.json must use ZIP DEFLATE'
      assert_equal expected_json, model.fetch(:bytes)
      refute_includes model.fetch(:bytes), "\n"
      assert_equal Digest::SHA256.hexdigest(expected_json), Digest::SHA256.hexdigest(model.fetch(:bytes))
      assert_equal 0, entries.fetch(asset_path).fetch(:method), 'PNG assets should use ZIP STORE'
      assert_equal PNG_BYTES, entries.fetch(asset_path).fetch(:bytes)
      assert entries.keys.all? { |name| !name.start_with?('/', '\\') && !name.match?(/\A[A-Za-z]:/) }
      assert result.fetch('materials').map { |item| item.dig('texture', 'asset') }.compact.all? { |name| entries.key?(name) }
    end
  end

  private

  def texture_bundle
    SibamboHistory::V20260812_01::CleanAnalysis::TextureBundle.new
  end

  def textured_material(index, name, rgba)
    snapshot::Material.new(
      source_uuid: uuid(400 + index), name: name, rgba: rgba.freeze,
      texture: { filename: "#{name}.png", width_m: 1.0, height_m: 1.0 }.freeze
    )
  end

  def textured_face(definition_uuid, source_uuid, material_uuid, x: 0, back_material_uuid: nil)
    points = [[x, 0, 0], [x + 1, 0, 0], [x + 1, 0, 1], [x, 0, 1]]
    loop = snapshot::Loop.new(
      kind: 'outer', vertices: points.map { |point| point.map(&:to_f).freeze }.freeze,
      edge_source_uuids: 4.times.map { |index| uuid(700 + index) }.freeze,
      adjacent_primitive_keys: [].freeze
    )
    snapshot::PolygonFragment.new(
      key: [definition_uuid, source_uuid].freeze,
      definition_uuid: definition_uuid, source_uuid: source_uuid, loops: [loop].freeze,
      front_material_uuid: material_uuid, back_material_uuid: back_material_uuid,
      normal: [0.0, -1.0, 0.0].freeze, area_m2: 1.0, construction_hints: [].freeze
    )
  end

  def uv_mapping(outer)
    { outer: outer.map { |uv| uv.map(&:to_f).freeze }.freeze, holes: [].freeze }.freeze
  end

  def compile_document(faces, materials, bundle)
    snapshot_document = document(
      root_primitives: faces, definitions: [], primitives: [], occurrences: [],
      materials: materials, evidence: []
    )
    SibamboHistory::V20260812_01::CleanAnalysis.compile(snapshot_document, texture_data: bundle)
  end

  def read_zip_entries(path)
    archive = File.binread(path)
    entries = {}
    offset = 0
    while archive.byteslice(offset, 4)&.unpack('V')&.first == 0x04034b50
      header = archive.byteslice(offset, 30).unpack('VvvvvvVVVvv')
      method = header.fetch(3)
      compressed_size = header.fetch(7)
      name_size = header.fetch(9)
      extra_size = header.fetch(10)
      name = archive.byteslice(offset + 30, name_size)
      payload_offset = offset + 30 + name_size + extra_size
      payload = archive.byteslice(payload_offset, compressed_size)
      bytes = if method == 8
                inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
                begin
                  inflater.inflate(payload) + inflater.finish
                ensure
                  inflater.close
                end
              else
                payload
              end
      entries[name] = { method: method, bytes: bytes }
      offset = payload_offset + compressed_size
    end
    entries
  end
end
