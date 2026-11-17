# frozen_string_literal: true

require 'test/unit'
require 'open3'
require_relative 'support/harness'
require_relative '../summarize'

class TestCompare < Test::Unit::TestCase
  CMP = SibamboModelTruthV1::Compare
  RUBY = RbConfig.ruby

  def setup
    UI.instance_variable_set(:@callback, nil)
  end

  def teardown
    SibamboModelTruthV1::SkpSide.reset!
    Sketchup.version = nil
  end

  def tamper(run_dir, side)
    path = File.join(run_dir, side, 'manifest.json')
    m = JSON.parse(File.read(path))
    yield m
    File.write(path, JSON.pretty_generate(m))
  end

  def test_identical_pair_passes_all_categories
    r = E2E.capture(compare: false)
    d = CMP.build(r.run_dir)
    assert_equal 'PASS', d[:overall]
    assert_equal E2E::CATS, d[:categories].map { |c| c[:category] }
    assert(d[:categories].all? { |c| c[:verdict] == 'PASS' })
    assert_equal true, d[:root][:equal]
    refute File.exist?(File.join(r.run_dir, 'model-truth-diff.json')), 'build must not write; run writes'
  end

  def test_missing_skp_side_is_error
    root = TestTmp.dir('cmp')
    run_dir = File.join(root, 'm', 'r')
    SibamboModelTruthV1::BomcSide.run(corpus_row: MTFixture.corpus_row, run_dir: run_dir, dwebp_path: 'x', ffmpeg_path: 'x', decoder: -> { MTFixture.decoded })
    assert_equal 'manifest_missing', CMP.build(run_dir)[:error]
    assert_equal 'ERROR', CMP.build(run_dir)[:overall]
  end

  def test_incomplete_manifest_is_error
    r = E2E.capture(compare: false)
    tamper(r.run_dir, 'skp') { |m| m['complete'] = false }
    assert_equal 'manifest_incomplete', CMP.build(r.run_dir)[:error]
  end

  def test_tool_version_mismatch_is_error
    r = E2E.capture(compare: false)
    tamper(r.run_dir, 'skp') { |m| m['tools']['canonical_rb_sha256'] = '0' * 64 }
    d = CMP.build(r.run_dir)
    assert_equal 'tool_version_mismatch', d[:error]
    assert_equal 'ERROR', d[:overall]
  end

  def test_input_mismatch_is_error
    r = E2E.capture(compare: false)
    tamper(r.run_dir, 'skp') { |m| m['inputs']['skp_sha256'] = '1' * 64 }
    assert_equal 'input_mismatch', CMP.build(r.run_dir)[:error]
  end

  def test_opacity_rule_is_u16_with_point_six_tolerance
    assert_equal 'PASS', E2E.verdicts(E2E.capture.diff)['materials']
    d = E2E.capture(decoded_mutator: ->(h) { h[:materials][1][:opacity] = (32_768 + 1) / 65_535.0 }).diff
    assert_equal 'FAIL', E2E.verdicts(d)['materials']
    assert_equal ['opacity'], E2E.category(d, 'materials')[:firstMismatches].map { |m| m[:field] }
  end

  def test_texture_size_uses_float32_tolerance_not_exact
    # float32 storage: the wire value of 1.016 m is off by < 2**-23 relative
    f32 = [1.016].pack('e').unpack1('e')
    d = E2E.capture(decoded_mutator: ->(h) { h[:materials][0][:texture_width_m] = f32 }).diff
    assert_equal 'PASS', E2E.verdicts(d)['materials']
    d = E2E.capture(decoded_mutator: ->(h) { h[:materials][0][:texture_width_m] = 1.016 + 1e-6 }).diff
    assert_equal 'FAIL', E2E.verdicts(d)['materials']
    assert_equal ['texture_width_m'], E2E.category(d, 'materials')[:firstMismatches].map { |m| m[:field] }
  end

  def test_texture_image_dimensions_must_match_bomc_table
    d = E2E.capture(decoded_mutator: ->(h) { h[:textures][0][:image_width_px] = 3 }).diff
    assert_equal 'FAIL', E2E.verdicts(d)['materials']
    assert_include E2E.category(d, 'materials')[:firstMismatches].map { |m| m[:field] }, 'image_width'
  end

  def test_bomc_pixel_branches
    root = TestTmp.dir('pix')
    FileUtils.mkdir_p(File.join(root, 'bomc', 'textures'))
    FileUtils.mkdir_p(File.join(root, 'skp', 'jcm-base'))
    row = { 'index' => 0, 'media_type' => 'jpeg_color_map', 'width_px' => 2, 'height_px' => 2, 'pixel' => { 'status' => 'PENDING_SKETCHUP', 'jcm_jpeg' => '0.jcm.jpg' } }
    ok = { 0 => { 'status' => 'OK', 'sha256' => 'a', 'width' => 2, 'height' => 2 } }
    assert_equal 'pixels_missing', CMP.bomc_pixel(root, row, ok)[:code]
    File.binwrite(File.join(root, 'skp', 'jcm-base', '0.rgba'), 'x' * 16)
    File.binwrite(File.join(root, 'bomc', 'textures', '0.jcm'), 'not a container')
    assert_equal 'jcm_reconstruct_error', CMP.bomc_pixel(root, row, ok)[:code]
    assert_equal 'pixels_missing', CMP.bomc_pixel(root, { 'index' => 1, 'media_type' => 'jpeg', 'width_px' => 2, 'height_px' => 2, 'pixel' => { 'status' => 'PENDING_SKETCHUP' } }, {})[:code]
    assert_equal 'bomc_imagerep_load_error', CMP.bomc_pixel(root, { 'index' => 1, 'media_type' => 'png', 'width_px' => 2, 'height_px' => 2, 'pixel' => { 'status' => 'PENDING_SKETCHUP' } }, { 1 => { 'status' => 'FAIL' } })[:code]
    assert_equal 'dimension_mismatch', CMP.bomc_pixel(root, { 'index' => 1, 'media_type' => 'png', 'width_px' => 2, 'height_px' => 2, 'pixel' => { 'status' => 'PENDING_SKETCHUP' } }, { 1 => { 'status' => 'OK', 'sha256' => 'a', 'width' => 3, 'height' => 2 } })[:code]
    assert_equal 'decoder_disagreement', CMP.bomc_pixel(root, { 'media_type' => 'webp', 'pixel' => { 'status' => 'FAIL', 'code' => 'decoder_disagreement' } }, {})['code']
    assert_equal 'OK', CMP.bomc_pixel(root, { 'index' => 2, 'media_type' => 'webp', 'pixel' => { 'status' => 'OK', 'sha256' => 'z' } }, {})[:status]
    assert_equal 'unsupported_media', CMP.bomc_pixel(root, { 'index' => 3, 'media_type' => 'bin', 'pixel' => { 'status' => 'PENDING_SKETCHUP' } }, {})[:code]
  end

  def test_hex_float_roundtrip
    [0.0, -0.0, 1.016, 0.1, 2**-23].each { |v| assert_equal v, CMP.hex_float(SibamboModelTruthV1::Canonical.float_hex(v)) }
  end

  def test_run_compare_cli_exit_codes_and_line
    pass = E2E.capture(compare: false)
    out, st = Open3.capture2e(RUBY, File.expand_path('../run_compare.rb', __dir__), pass.run_dir)
    assert_equal 0, st.exitstatus
    assert_equal 'Fixture_Model PASS', out.strip
    fail_ = E2E.capture(compare: false, decoded_mutator: ->(h) { h[:meshes][0][:faces][0][:hidden] = true })
    out, st = Open3.capture2e(RUBY, File.expand_path('../run_compare.rb', __dir__), fail_.run_dir)
    assert_equal 1, st.exitstatus
    assert_match(/\AFixture_Model FAIL definitions,faces\z/, out.strip)
    err = E2E.capture(compare: false)
    FileUtils.rm_rf(File.join(err.run_dir, 'skp'))
    out, st = Open3.capture2e(RUBY, File.expand_path('../run_compare.rb', __dir__), err.run_dir)
    assert_equal 2, st.exitstatus
    assert_match(/ERROR manifest_missing/, out)
  end

  def test_summarize_lists_every_model_and_not_run
    out_root = TestTmp.dir('sum')
    ok = E2E.capture
    key = SibamboModelTruthV1::Canonical.model_key('Fixture Model')
    FileUtils.mkdir_p(File.join(out_root, key))
    FileUtils.cp_r(ok.run_dir, File.join(out_root, key, '20261117T000000Z'))
    corpus = { 'models' => [{ 'model' => 'Fixture Model', 'skpRank' => 2 }, { 'model' => 'Other Model', 'skpRank' => 1 }] }
    cpath = File.join(out_root, 'corpus.json')
    File.write(cpath, JSON.generate(corpus))
    md = SibamboModelTruthV1::Summarize.build(out_root: out_root, corpus_path: cpath)
    rows = md.lines.select { |l| l.start_with?('| M0') }
    assert_equal 2, rows.length
    assert_match(/\| M01 \| Other Model \| - \| NOT_RUN \|/, rows[0])
    assert_match(/\| M02 \| Fixture Model \| 20261117T000000Z \| PASS \|/, rows[1])
    assert_match(/Overall PASS: 1/, md)
    assert_match(/NOT_RUN: 1/, md)
    assert_match(/image entities in scope: 1/, md)
    assert_match(/Colorize limitation/, md)
    assert_match(/SketchUp build assumption/, md)
  end
end
