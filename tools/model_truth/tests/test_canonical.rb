# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'digest'
require_relative '../canonical'

class TestCanonical < Test::Unit::TestCase
  C = SibamboModelTruthV1::Canonical
  Err = SibamboModelTruthV1::ModelTruthError
  PixErr = SibamboModelTruthV1::PixelError
  Pt = Struct.new(:x, :y, :z)

  def test_skp_pos_inches_to_grid
    assert_equal [25_400_000, 0, 0], C.skp_pos(Pt.new(1.0, -0.0, 0.0))
    # 2.5e-8 inch = 6.35e-10 m -> rounds to 1e-9 -> 1 on the grid
    assert_equal [1, 0, 0], C.skp_pos(Pt.new(2.5e-8, 0.0, 0.0))
    assert_equal [-50_800_000, 25_400_000, 0], C.skp_pos(Pt.new(-2.0, 1.0, 0.0))
  end

  def test_grid_rejects_nonfinite
    assert_raise(Err) { C.grid(Float::NAN) }
    assert_raise(Err) { C.grid(Float::INFINITY) }
    assert_raise(Err) { C.grid('1') }
    assert_equal 0, C.grid(-0.0)
  end

  def test_t16_translation_in_metres_rotation_unitless
    ident = Struct.new(:a) { def to_a; a; end }.new([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 20, 30, 1])
    t = C.skp_t16(ident)
    assert_equal [1_000_000_000, 0, 0, 0, 0, 1_000_000_000, 0, 0, 0, 0, 1_000_000_000, 0, 254_000_000, 508_000_000, 762_000_000, 1_000_000_000], t
    assert_equal t.size, 16
    assert_equal C::IDENTITY_T16, C.bomc_t16([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0])
    assert_raise(Err) { C.bomc_t16([1.0]) }
  end

  def test_uv_conversion_and_q0
    counters = { uv_q0_vertices: 0 }
    uv = Struct.new(:x, :y, :z)
    assert_equal [500_000_000, 250_000_000], C.skp_uv(uv.new(1.0, 0.5, 2.0), counters)
    assert_equal 0, counters[:uv_q0_vertices]
    assert_equal [0, 0], C.skp_uv(uv.new(1.0, 1.0, 0.0), counters)
    assert_equal 1, counters[:uv_q0_vertices]
    assert_equal %w[NaN NaN], C.skp_uv(uv.new(Float::NAN, 1.0, 1.0), counters)
  end

  def square
    [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]]
  end

  def test_rotate_loop_start_vertex_invariant_and_winding_kept
    sq = square
    outs = (0..3).map { |k| C.rotate_loop(sq[k..-1] + sq[0...k]) }
    assert_equal 1, outs.uniq.size
    assert_equal [0, 0, 0], outs.first.first
    reversed = C.rotate_loop(sq.reverse)
    assert_not_equal outs.first, reversed
    assert_raise(Err) { C.rotate_loop([[0, 0, 0], [1, 0, 0]]) }
  end

  def test_rotate_loop_keeps_uv_with_its_vertex
    loop4 = [[0, 0, 0, 1, 1], [10, 0, 0, 2, 2], [10, 10, 0, 3, 3], [0, 10, 0, 4, 4]]
    rotated = C.rotate_loop(loop4[2..-1] + loop4[0...2])
    assert_equal loop4, rotated
    assert_equal [[0, 0, 0, 1, 1], [10, 0, 0, 2, 2], [10, 10, 0, 3, 3], [0, 10, 0, 4, 4]], rotated
  end

  def test_rotate_loop_duplicate_min_position_picks_smallest_whole_sequence
    pinched = [[0, 0, 0, 5, 5], [1, 0, 0, 0, 0], [0, 0, 0, 3, 3], [0, 1, 0, 0, 0]]
    out = C.rotate_loop(pinched)
    assert_equal [0, 0, 0, 3, 3], out.first
  end

  def test_mset_order_independent_and_counts
    items = %w[a b c d e].map { |s| C.canon_json(['I', s]) }
    a = C::MSet.new
    b = C::MSet.new
    items.each { |i| a.add(i) }
    items.reverse.each { |i| b.add(i) }
    assert_equal a.to_a, b.to_a
    assert_equal 5, a.count
    before = a.to_a
    a.add(items.first)
    assert_equal 6, a.count
    assert_not_equal before[1], a.to_a[1]
    assert_equal 64, a.to_a[1].length
  end

  def test_item_validation_rejects_floats_and_symbols
    assert_raise(Err) { C.canon_json(['F', 1.5]) }
    assert_raise(Err) { C.canon_json([:sym]) }
    assert_raise(Err) { C.canon_json({ 'a' => 1 }) }
    assert_raise(Err) { C.canon_json(["bad\xff".dup.force_encoding('UTF-8')]) }
  end

  def test_canon_json_exact_bytes_and_roundtrip
    value = ['a"b', 'c\\d', "e\tf", 'é', " ", [nil, true, false, -3, 0, [[]]], '']
    expected = '["a\\"b","c\\\\d","e\\u0009f","é","' + " " + '",[null,true,false,-3,0,[[]]],""]'
    got = C.canon_json(value)
    assert_equal expected, got
    assert_equal Encoding::UTF_8, got.encoding
    assert_equal value, JSON.parse(got)
    assert_no_match(/ /, C.canon_json(['x', 1, [2]]))
    assert_no_match(/\\u00e9/, got)
    assert_equal '"\u001f"', C.canon_json("\x1f")
    assert_equal 'null', C.canon_json(nil)
  end

  def test_face_and_edge_items
    outer = [[0, 0, 0], [10, 0, 0], [10, 10, 0]]
    item = C.face_item(front: nil, back: 'M', tag: 'T', hidden: nil, normal: [0, 0, 1_000_000_000],
                       outer: outer.reverse.rotate(1), holes: [], triangles: [outer], uv_front: false, uv_back: true)
    assert_equal 'F', item[0]
    assert_equal false, item[4]
    assert_equal [false, true], item.last
    assert_equal C.rotate_loop(outer.reverse.rotate(1)), item[6]
    e = C.edge_item(tag: nil, hidden: true, soft: false, smooth: nil, a: [2, 0, 0], b: [1, 0, 0])
    assert_equal ['E', nil, true, false, false, [[1, 0, 0], [2, 0, 0]]], e
    local = C.instance_local_item(kind: 'component', t16: C::IDENTITY_T16, material: nil, tag: 'L')
    assert_equal ['J', 'component', C::IDENTITY_T16, nil, 'L', 'abc'], C.instance_merkle_item(local, 'abc')
  end

  def test_definition_digests_change_with_content
    f = C::MSet.new
    e = C::MSet.new
    z = C::MSet.new
    f.add(C.canon_json(['F']))
    l1, d1 = C.definition_digests('root', f, e, z, z, z, z)
    f.add(C.canon_json(['F2']))
    l2, d2 = C.definition_digests('root', f, e, z, z, z, z)
    assert_not_equal l1, l2
    assert_not_equal d1, d2
    _l3, d3 = C.definition_digests('root', f, e, z, z, z, [1, 'f' * 64])
    assert_not_equal d2, d3
  end

  def bgr_data
    row0 = [1, 2, 3, 4, 5, 6, 7, 8, 9].pack('C*') + "\xEE\xEE\xEE".b
    row1 = [10, 11, 12, 13, 14, 15, 16, 17, 18].pack('C*') + "\xEE\xEE\xEE".b
    row0 + row1
  end

  def test_pixels_bgr_with_row_padding
    rows = []
    res = C.canonical_rgba_sha(width: 3, height: 2, bits_per_pixel: 24, row_padding: 3, data: bgr_data, keep: true, platform: :win) { |y| rows << y }
    expected = [3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 255, 15, 14, 13, 255, 18, 17, 16, 255].pack('C*')
    assert_equal Digest::SHA256.hexdigest(expected), res[:sha256]
    assert_equal expected, res[:bytes]
    assert_equal 24, res[:bytes].bytesize
    assert_equal [0, 1], rows
  end

  def test_pixels_bgra
    data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16].pack('C*')
    res = C.canonical_rgba_sha(width: 2, height: 2, bits_per_pixel: 32, row_padding: 0, data: data, platform: :win)
    expected = [3, 2, 1, 4, 7, 6, 5, 8, 11, 10, 9, 12, 15, 14, 13, 16].pack('C*')
    assert_equal Digest::SHA256.hexdigest(expected), res[:sha256]
    assert_nil res[:bytes]
  end

  def test_pixels_errors
    short = bgr_data.byteslice(0, 20)
    err = assert_raise(PixErr) { C.canonical_rgba_sha(width: 3, height: 2, bits_per_pixel: 24, row_padding: 3, data: short, platform: :win) }
    assert_equal 'short_data', err.message
    err = assert_raise(PixErr) { C.canonical_rgba_sha(width: 2, height: 2, bits_per_pixel: 8, row_padding: 0, data: 'xxxx', platform: :win) }
    assert_equal 'unsupported_bpp', err.message
    err = assert_raise(PixErr) { C.canonical_rgba_sha(width: 1, height: 1, bits_per_pixel: 32, row_padding: 0, data: 'xxxx', platform: :linux) }
    assert_equal 'unsupported_platform', err.message
  end

  def pam(w, h, depth: 4, data: nil)
    hdr = "P7\nWIDTH #{w}\nHEIGHT #{h}\nDEPTH #{depth}\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".b
    hdr + (data || ("\x01\x02\x03\x04".b * (w * h)))
  end

  def test_parse_pam
    r = C.parse_pam(pam(2, 1))
    assert_equal [2, 1], [r[:width], r[:height]]
    assert_equal 8, r[:rgba].bytesize
    err = assert_raise(PixErr) { C.parse_pam(pam(2, 1, depth: 3)) }
    assert_equal 'pam_invalid', err.message
    err = assert_raise(PixErr) { C.parse_pam(pam(2, 1, data: "\x01".b * 7)) }
    assert_equal 'pam_invalid', err.message
    assert_raise(PixErr) { C.parse_pam('P6') }
  end

  def riff(chunks)
    body = 'WEBP'.b + chunks
    'RIFF'.b + [body.bytesize].pack('V') + body
  end

  def chunk(fourcc, payload)
    pad = payload.bytesize.odd? ? "\x00".b : ''.b
    fourcc.b + [payload.bytesize].pack('V') + payload.b + pad
  end

  def test_webp_container
    assert_equal :vp8l_simple, C.webp_container!(riff(chunk('VP8L', "\x2f\x00\x00\x00")))
    assert_equal :vp8l_simple, C.webp_container!(riff(chunk('VP8L', "\x2f\x00\x00")))
    assert_equal 'webp_extended_container', assert_raise(PixErr) { C.webp_container!(riff(chunk('VP8X', "\x00" * 10))) }.message
    assert_equal 'webp_lossy', assert_raise(PixErr) { C.webp_container!(riff(chunk('VP8 ', "\x00" * 4))) }.message
    assert_equal 'webp_unexpected_chunks', assert_raise(PixErr) { C.webp_container!(riff(chunk('VP8L', "\x2f\x00\x00\x00") + chunk('EXIF', "\x00" * 4))) }.message
    assert_equal 'webp_not_riff', assert_raise(PixErr) { C.webp_container!('not a webp file at all....') }.message
    broken = riff(chunk('VP8L', "\x2f\x00\x00\x00")) + 'xx'
    assert_equal 'webp_size_mismatch', assert_raise(PixErr) { C.webp_container!(broken) }.message
  end

  def test_model_key_and_float_hex
    assert_equal '2LT_-_2._RUMAH_10X14_M', C.model_key('2LT - 2. RUMAH 10X14 M')
    assert_equal '3ff0000000000000', C.float_hex(1.0)
    assert_equal 'a_b', C.model_key('a  /  b'.sub(/\s+\/\s+/, '  '))
  end

  def test_utf8
    assert_nil C.utf8!(nil)
    assert_equal 'é', C.utf8!("\xC3\xA9".b)
    assert_raise(Err) { C.utf8!("\xff".b) }
  end
end
