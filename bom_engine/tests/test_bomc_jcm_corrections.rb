# frozen_string_literal: true
require 'minitest/autorun'
require 'zlib'
require_relative '../bomc_jpeg_color_map'

class TestBOMCJcmCorrections < Minitest::Test
  BASE = [10,20,30,255,40,50,60,255].pack('C*').freeze
  TARGET = [11,22,33,255,44,55,66,255].pack('C*').freeze
  JPEG = [255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*').freeze

  def codec
    BOMEngine::BOMCJpegColorMap
  end

  def test_legacy_stored_dictionary_round_trip
    bytes = codec.encode(jpeg: JPEG, base_rgba: BASE, target_rgba: TARGET, width: 2, height: 1)
    assert_equal codec::DICTIONARY_STORED, bytes.getbyte(10)
    assert_equal TARGET, codec.reconstruct(bytes, BASE)
  end

  def test_deflated_dictionary_round_trip
    raw = [10,20,30,11,22,33,255,40,50,60,44,55,66,255].pack('C*')
    compressed = Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)
    bytes = codec.send(
      :serialize,
      jpeg: JPEG, base_rgba: BASE, target_rgba: TARGET, width: 2, height: 1, count: 2,
      codec: codec::DICTIONARY_DEFLATE, correction: compressed
    )
    assert_equal codec::DICTIONARY_DEFLATE, bytes.getbyte(10)
    assert_equal TARGET, codec.reconstruct(bytes, BASE)
  end

  def test_conflicting_color_map_uses_exact_xor_residual
    jpeg = JPEG.dup
    jpeg[7,4] = [1,2].pack('n2')
    base = BASE.byteslice(0,4) * 2
    bytes = codec.encode(jpeg: jpeg, base_rgba: base, target_rgba: TARGET, width: 2, height: 1)
    assert_equal codec::XOR_RESIDUAL_DEFLATE, bytes.getbyte(10)
    assert_equal TARGET, codec.reconstruct(bytes, base)
  end

  def test_tampered_compressed_correction_fails_closed
    jpeg = JPEG.dup
    jpeg[7,4] = [1,2].pack('n2')
    base = BASE.byteslice(0,4) * 2
    bytes = codec.encode(jpeg: jpeg, base_rgba: base, target_rgba: TARGET, width: 2, height: 1)
    bytes.setbyte(bytes.bytesize - 1, bytes.getbyte(bytes.bytesize - 1) ^ 0xff)
    assert_raises(ArgumentError) { codec.reconstruct(bytes, base) }
  end
end
