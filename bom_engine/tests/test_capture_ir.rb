# frozen_string_literal: true

require 'test/unit'
require 'digest'
require_relative '../capture_ir'
require_relative '../bomc_model_adapter'

class TestCaptureIR < Test::Unit::TestCase
  def test_wrap_carries_source_identity_and_owns_frozen_texture_bytes
    bytes = +'texture-payload'.b
    graph = {
      materials: [{
        id: 'mat:1',
        texture: {
          filename: 'texture.png',
          bytes: bytes,
          byte_length: bytes.bytesize,
          sha256: 'b' * 64
        }
      }],
      meshes: [], definitions: [], nodes: [], transforms: [], scenes: []
    }
    ir = BOMEngine::CaptureIR.wrap(
      graph,
      source_info: { path: 'model.skp', bytes: 123, sha256: 'a' * 64, available: true },
      profile: :exact,
      texture_representation: :portable,
      texture_evidence: [{ material_id: 'mat:1', sha256: 'b' * 64 }]
    )

    assert_kind_of BOMEngine::CaptureIR, ir
    assert_equal 'a' * 64, ir.source_digest
    assert_equal 123, ir.source_info[:bytes]
    assert_equal 'exact', ir.profile
    assert_equal 'portable', ir.texture_representation
    assert_equal 'b' * 64, ir.texture_evidence.first[:sha256]
    assert_equal 'texture-payload', ir.dig(:materials, 0, :texture, :bytes)
    assert_true ir.dig(:materials, 0, :texture, :bytes).frozen?
    assert_true ir.detached?
  end

  def test_detached_detects_capture_only_entity_handle
    ir = BOMEngine::CaptureIR.wrap({ nodes: [{ id: 'node:1', _entity: Object.new }] })
    assert_false ir.detached?
  end

  def test_model_adapter_consumes_capture_owned_texture_digest_without_rehashing
    bytes = "\x89PNG\r\n\x1a\nowned-payload".b.freeze
    sha = Digest::SHA256.hexdigest(bytes)
    ir = BOMEngine::CaptureIR.wrap({
      materials: [{ id: 'mat:1', name: 'Owned', texture: {
        filename: 'owned.png', bytes: bytes, byte_length: bytes.bytesize, sha256: sha,
        image_width_px: 1, image_height_px: 1
      } }],
      tags: [], meshes: [],
      definitions: [{ id: 'def:root', kind: 'root', node_ids: [] }],
      nodes: [{ id: 'node:root', kind: 'root', definition_id: 'def:root', transform_id: 0 }],
      transforms: [BOMEngine::BOMC::ModelAdapter::IDENTITY], scenes: [], clip_planes: []
    }, source_info: { sha256: 'a' * 64 })

    digest_class = Digest::SHA256.singleton_class
    original = Digest::SHA256.method(:hexdigest)
    digest_class.define_method(:hexdigest) { |_value| raise 'capture texture was rehashed' }
    normalized = BOMEngine::BOMC::ModelAdapter.normalize(ir)
    assert_equal sha, normalized.dig(:materials, 0, :texture, :sha256)
    assert_equal bytes, normalized.dig(:materials, 0, :texture, :bytes)
  ensure
    digest_class.define_method(:hexdigest, original) if digest_class && original
  end
end
