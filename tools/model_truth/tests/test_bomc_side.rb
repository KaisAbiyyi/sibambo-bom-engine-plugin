# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'stringio'
require 'zlib'
require 'tmpdir'
require 'fileutils'
require_relative '../bomc_side'
require_relative 'support/fixture'
require_relative 'support/harness'

class TestBomcSide < Test::Unit::TestCase
  BS = SibamboModelTruthV1::BomcSide
  Err = SibamboModelTruthV1::ModelTruthError

  def run_core(decoded)
    io = StringIO.new
    [BS.core(decoded, writer: io), io.string]
  end

  def test_core_counts_dfs_and_shared_definition
    result, out = run_core(MTFixture.decoded)
    recs = result[:records]
    assert_equal 3, recs.length
    assert_equal [0, 1, 2], recs.map { |r| r[:dfs] }
    assert_equal %w[root component group], recs.map { |r| r[:kind] }
    # root: 1 face, 4 boundary edges + 1 extra, 3 instances (comp, comp, group), 1 image, 1 text
    assert_equal({ faces: 1, edges: 5, instances: 3, images: 1, texts: 1 }, recs[0][:counts])
    assert_equal [1, 1, 2], recs[0][:children_dfs]
    assert_equal({ faces: 1, edges: 3, instances: 0, images: 0, texts: 0 }, recs[1][:counts])
    assert_equal({ faces: 1, edges: 8, instances: 0, images: 0, texts: 0 }, recs[2][:counts])
    assert_equal 3, result[:counts][:faces]
    assert_equal 0, result[:unreachable_definitions_bomc]
    assert_equal recs[0][:digest], result[:root_digest]
    # the shared component is one record and its items are written once
    lines = out.lines.map { |l| JSON.parse(l) }
    assert_equal 1, lines.count { |l| l['d'] == 1 && l['c'] == 'F' }
    assert_equal 2, lines.count { |l| l['d'] == 0 && l['c'] == 'I' && l['i'][1] == 'component' }
    assert_equal 'G', lines.find { |l| l['c'] == 'G' }['i'][0]
    text = lines.find { |l| l['c'] == 'X' }['i']
    assert_equal ["X", "Hello \u00e9", [25_400_000, 50_800_000, 76_200_000], 'Hidden'], text
    face = lines.find { |l| l['d'] == 0 && l['c'] == 'F' }['i']
    assert_equal 'Brick', face[1]
    assert_nil face[2]
    assert_equal [true, false], face.last
  end

  def test_core_is_deterministic_and_order_of_nodes_matters_not_for_digest_of_leaf
    a, out_a = run_core(MTFixture.decoded)
    b, out_b = run_core(MTFixture.decoded)
    assert_equal out_a, out_b
    assert_equal a[:root_digest], b[:root_digest]
    assert_equal a[:records], b[:records]
  end

  def test_core_detects_leaf_change_in_shared_definition
    base, = run_core(MTFixture.decoded)
    d = MTFixture.decoded
    d[:meshes][1][:faces][0][:back_material] = nil
    changed, = run_core(d)
    assert_not_equal base[:root_digest], changed[:root_digest]
    assert_not_equal base[:records][1][:local_digest], changed[:records][1][:local_digest]
    # root local digest is unchanged: only the child digest propagated
    assert_equal base[:records][0][:local_digest], changed[:records][0][:local_digest]
    assert_not_equal base[:records][0][:digest], changed[:records][0][:digest]
  end

  def test_core_raises_on_non_identity_root_transform
    d = MTFixture.decoded
    d[:transforms][0][12] = 1.0
    assert_raise(Err) { run_core(d) }
  end

  def test_core_raises_on_unknown_kinds
    d = MTFixture.decoded
    d[:instances][1][:kind] = 'mystery'
    err = assert_raise(Err) { run_core(d) }
    assert_match(/unknown_kind/, err.message)
    d = MTFixture.decoded
    d[:definitions][2][:kind] = 'weird_definition'
    assert_raise(Err) { run_core(d) }
  end

  def test_core_depth_limit
    d = MTFixture.decoded
    # chain of 70 nested component definitions
    parent = 0
    70.times do |i|
      d[:definitions] << { kind: 'component_definition', name: "n#{i}", mesh: nil, nodes: [] }
      d[:instances] << { kind: 'component_instance', owner_definition: parent, definition: d[:definitions].length - 1,
                         transform: 0, material: nil, tag: nil, visible: true, fallback: false, name: nil }
      d[:definitions][parent][:nodes] << d[:instances].length - 1
      parent = d[:definitions].length - 1
    end
    err = assert_raise(Err) { run_core(d) }
    assert_equal 'depth_limit', err.message
  end

  def test_core_counts_unreachable_definitions
    d = MTFixture.decoded
    d[:definitions] << { kind: 'component_definition', name: 'orphan', mesh: nil, nodes: [] }
    result, = run_core(d)
    assert_equal 1, result[:unreachable_definitions_bomc]
  end

  def test_inherited_paint_exposure_counts_textured_instance_paint_over_default_faces
    base, = run_core(MTFixture.decoded)
    assert_equal({ faces_definition_level: 0, pairs: 0 }, base[:diagnostics][:inherited_paint_exposure])
    d = MTFixture.decoded
    d[:instances].each { |i| i[:material] = 0 if i[:kind] == 'component_instance' && i[:material] == 1 }
    result, = run_core(d)
    # component def has 1 face with front_material nil, painted via the textured instance material
    assert_equal({ faces_definition_level: 1, pairs: 1 }, result[:diagnostics][:inherited_paint_exposure])
  end

  def test_tables
    d = MTFixture.decoded
    mats = BS.material_rows(d)
    assert_equal 'Brick', mats[0][:name]
    assert_equal [200, 100, 50, 255], mats[0][:color]
    assert_equal 65_535, mats[0][:opacity_u16]
    assert_equal 32_768, mats[1][:opacity_u16]
    assert_equal SibamboModelTruthV1::Canonical.float_hex(1.016), mats[0][:texture_width_m_hex]
    assert_nil mats[1][:texture_width_m_hex]
    assert_equal [{ name: 'Walls', visible: true }, { name: 'Hidden', visible: false }], BS.tag_rows(d)
  end

  def test_run_writes_complete_run_dir_and_manifest
    root = TestTmp.dir('bomc')
    run_dir = File.join(root, 'model', '20261117T000000Z')
    manifest = BS.run(corpus_row: MTFixture.corpus_row, run_dir: run_dir, dwebp_path: 'unused', ffmpeg_path: 'unused', decoder: -> { MTFixture.decoded })
    assert_equal true, manifest[:complete]
    bdir = File.join(run_dir, 'bomc')
    %w[manifest.json tables.json diagnostics.json definitions.ndjson items.ndjson.gz textures/0.jpg].each do |f|
      assert File.exist?(File.join(bdir, f)), f
    end
    saved = JSON.parse(File.read(File.join(bdir, 'manifest.json')))
    assert_equal true, saved['complete']
    assert_equal 'bomc', saved['side']
    assert_equal '20261117T000000Z', saved['run_id']
    assert_equal 3, saved['definition_count']
    assert_equal saved['files']['items.ndjson.gz'], Digest::SHA256.file(File.join(bdir, 'items.ndjson.gz')).hexdigest
    gz = Zlib::GzipReader.open(File.join(bdir, 'items.ndjson.gz'), &:read)
    assert_equal saved['items_ndjson_decompressed_sha256'], Digest::SHA256.hexdigest(gz)
    tables = JSON.parse(File.read(File.join(bdir, 'tables.json')))
    assert_equal 'PENDING_SKETCHUP', tables['textures'][0]['pixel']['status']
    assert_equal 0, Dir.children(File.join(bdir, 'tmp')).length
    assert_raise(Err) { BS.run(corpus_row: MTFixture.corpus_row, run_dir: run_dir, dwebp_path: 'x', ffmpeg_path: 'x', decoder: -> { MTFixture.decoded }) }
  end

  def test_run_is_deterministic
    root = TestTmp.dir('det')
    m = 2.times.map do |i|
      BS.run(corpus_row: MTFixture.corpus_row, run_dir: File.join(root, "m#{i}", 'r'), dwebp_path: 'x', ffmpeg_path: 'x', decoder: -> { MTFixture.decoded })
    end
    assert_equal m[0][:root_digest], m[1][:root_digest]
    assert_equal m[0][:items_ndjson_decompressed_sha256], m[1][:items_ndjson_decompressed_sha256]
    assert_equal m[0][:files]['definitions.ndjson'], m[1][:files]['definitions.ndjson']
    assert_equal m[0][:files]['items.ndjson.gz'], m[1][:files]['items.ndjson.gz']
  end

  def test_run_rejects_non_d_run_dir_and_writes_failure_manifest_for_bad_contract
    assert_raise(Err) { BS.run(corpus_row: MTFixture.corpus_row, run_dir: 'C:/mt-should-not-exist/x', dwebp_path: 'x', ffmpeg_path: 'x', decoder: -> { MTFixture.decoded }) }
    refute File.exist?('C:/mt-should-not-exist')
    root = TestTmp.dir('bad')
    d = MTFixture.decoded
    d[:encoding_contract][:profile] = :visual
    run_dir = File.join(root, 'm', 'r')
    assert_raise(Err) { BS.run(corpus_row: MTFixture.corpus_row, run_dir: run_dir, dwebp_path: 'x', ffmpeg_path: 'x', decoder: -> { d }) }
    saved = JSON.parse(File.read(File.join(run_dir, 'bomc', 'manifest.json')))
    assert_equal false, saved['complete']
    assert_equal 'not_exact_contract', saved['error']['message']
  end

  def test_run_restores_temp_env
    before = [ENV['TEMP'], ENV['TMP']]
    root = TestTmp.dir('env')
    BS.run(corpus_row: MTFixture.corpus_row, run_dir: File.join(root, 'm', 'r'), dwebp_path: 'x', ffmpeg_path: 'x', decoder: -> { MTFixture.decoded })
    assert_equal before, [ENV['TEMP'], ENV['TMP']]
  end

  def test_textures_step_media_routes
    root = TestTmp.dir('tex')
    FileUtils.mkdir_p(File.join(root, 'textures'))
    FileUtils.mkdir_p(File.join(root, 'tmp'))
    d = { textures: [
      { media_type: :png, image_width_px: 1, image_height_px: 1, bytes: 'png-bytes'.b },
      { media_type: :binary, image_width_px: 1, image_height_px: 1, bytes: 'zzz'.b },
      { media_type: :jpeg_color_map, image_width_px: 1, image_height_px: 1, bytes: 'not a color map'.b },
      { media_type: :webp, image_width_px: 1, image_height_px: 1, bytes: 'RIFFxxxxWEBPVP8X'.b }
    ] }
    rows = BS.textures_step(d, root, dwebp_path: 'unused', ffmpeg_path: 'unused')
    assert_equal 'PENDING_SKETCHUP', rows[0][:pixel][:status]
    assert_equal '0.png', rows[0][:file]
    assert_equal 'unsupported_media', rows[1][:pixel][:code]
    assert_equal 'jcm_parse_error', rows[2][:pixel][:code]
    assert_equal 'FAIL', rows[3][:pixel][:status]
    assert_equal 'webp_not_riff', rows[3][:pixel][:code]
  end
end
