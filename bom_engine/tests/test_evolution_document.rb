# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'digest'
require_relative '../evolution_document'
require_relative '../capture_ir'

class TestEvolutionDocument < Test::Unit::TestCase
  def test_prepare_detaches_texture_bytes_and_deduplicates_by_hash
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'displayed.png')
      File.binwrite(path, 'portable-pixels')
      graph = {
        source: { file_path: 'C:/private/model.skp', file_name: 'model.skp' },
        materials: [
          { id: 'm1', texture: { source_path: path, filename: 'a.png' } },
          { id: 'm2', texture: { source_path: path, filename: 'b.png' } }
        ],
        meshes: [], definitions: [], nodes: [], transforms: [], scenes: [], clip_planes: []
      }
      document = BOMEngine::EvolutionDocument.prepare(
        graph, engine: :e2, profile: :exact,
        source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40
      )
      assert_equal 1, document['assets'].length
      asset = document['assets'].first
      assert_equal Digest::SHA256.hexdigest('portable-pixels'), asset['sha256']
      assert_equal asset['id'], document.dig('graph', 'materials', 0, 'texture', 'asset_id')
      assert_equal asset['id'], document.dig('graph', 'materials', 1, 'texture', 'asset_id')
      assert_nil document.dig('graph', 'materials', 0, 'texture', 'source_path')
      assert_nil document.dig('graph', 'source', 'file_path')
      json_assets = BOMEngine::EvolutionDocument.json_asset_table(document)
      assert_equal ['portable-pixels'].pack('m0'), json_assets.first['data_base64']
    end
  end

  def test_prepare_consumes_capture_owned_texture_bytes_without_staging_file
    bytes = 'capture-owned-portable-pixels'.b.freeze
    sha = Digest::SHA256.hexdigest(bytes)
    graph = {
      materials: [{
        id: 'm1',
        texture: {
          source_path: 'Z:/missing/capture-texture.png',
          filename: 'capture-texture.png',
          bytes: bytes,
          byte_length: bytes.bytesize,
          sha256: sha,
          displayed_rgba_sha256: 'c' * 64
        }
      }],
      meshes: [], definitions: [], nodes: [], transforms: [], scenes: [], clip_planes: []
    }

    document = BOMEngine::EvolutionDocument.prepare(
      graph, engine: :e3, profile: :exact,
      source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40
    )

    asset = document.fetch('assets').first
    assert_equal bytes, asset.fetch('bytes')
    assert_equal sha, asset.fetch('sha256')
    assert_equal bytes.bytesize, asset.fetch('byte_length')
    assert_equal 'c' * 64, asset.fetch('displayed_rgba_sha256')
    assert_nil document.dig('graph', 'materials', 0, 'texture', 'bytes')
    assert_nil document.dig('graph', 'materials', 0, 'texture', 'source_path')
  end

  def test_prepare_trusts_capture_ir_digest_without_rehashing_texture_bytes
    bytes = 'capture-owned-portable-pixels'.b.freeze
    sha = Digest::SHA256.hexdigest(bytes)
    ir = BOMEngine::CaptureIR.wrap({
      materials: [{ id: 'm1', texture: {
        filename: 'capture.png', bytes: bytes, byte_length: bytes.bytesize, sha256: sha
      } }],
      meshes: [], definitions: [], nodes: [], transforms: [], scenes: [], clip_planes: []
    }, source_info: { sha256: 'd' * 64 }, profile: :exact, texture_representation: :portable)

    digest_class = Digest::SHA256.singleton_class
    original = Digest::SHA256.method(:hexdigest)
    digest_class.define_method(:hexdigest) { |_value| raise 'capture texture was rehashed' }
    document = BOMEngine::EvolutionDocument.prepare(
      ir, engine: :e1, profile: :exact,
      source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40
    )
    assert_equal sha, document.dig('assets', 0, 'sha256')
  ensure
    digest_class.define_method(:hexdigest, original) if digest_class && original
  end

  def test_prepare_normalizes_only_proven_lossless_infinite_psnr
    graph = {
      materials: [{ texture: { staging_evidence: { quality: {
        psnr_db: Float::INFINITY, mean_squared_error: 0.0, max_channel_error: 0, alpha_preserved: true
      } } } }],
      meshes: [], definitions: [], nodes: [], transforms: [], scenes: [], clip_planes: []
    }
    document = BOMEngine::EvolutionDocument.prepare(
      graph, engine: :e1, profile: :visual,
      source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40
    )
    quality = document.dig('graph', 'materials', 0, 'texture', 'staging_evidence', 'quality')
    assert_nil quality['psnr_db']
    assert_equal true, quality['pixel_lossless']
  end

  def test_prepare_rejects_nonfinite_geometry_and_host_objects
    base = { meshes: [], definitions: [], nodes: [], transforms: [], scenes: [], clip_planes: [] }
    assert_raise(ArgumentError) do
      BOMEngine::EvolutionDocument.prepare(
        base.merge(meshes: [{ positions_m: [Float::NAN, 0.0, 0.0] }]),
        engine: :e3, profile: :research, source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40
      )
    end
    assert_raise(ArgumentError) do
      BOMEngine::EvolutionDocument.prepare(
        base.merge(metadata: { unexpected: Object.new }),
        engine: :e3, profile: :research, source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40
      )
    end
  end

  def test_prepare_rejects_cycles
    graph = { meshes: [], definitions: [], nodes: [], transforms: [], scenes: [], clip_planes: [] }
    graph[:cycle] = graph
    assert_raise(ArgumentError) do
      BOMEngine::EvolutionDocument.prepare(
        graph, engine: :e1, profile: :visual,
        source_tree_sha256: 'a' * 64, historical_baseline_sha: 'b' * 40
      )
    end
  end
end
