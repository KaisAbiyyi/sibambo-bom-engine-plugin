# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'zlib'
require 'fileutils'
require_relative 'support/fixture'
require_relative 'support/sketchup_mock'
require_relative '../bomc_side'
require_relative '../skp_side'
require_relative 'support/harness'

module SkpHarness
  Setup = Struct.new(:root, :run_dir, :skp_path, :sha, :model)

  def self.setup(spec = MTFixture.spec)
    root = TestTmp.dir('skp')
    skp_path = File.join(root, 'fixture.skp')
    File.binwrite(skp_path, 'pretend skp bytes')
    sha = Digest::SHA256.file(skp_path).hexdigest
    run_dir = File.join(root, 'model', '20261117T000000Z')
    SibamboModelTruthV1::BomcSide.run(corpus_row: MTFixture.corpus_row(sha), run_dir: run_dir, dwebp_path: 'x', ffmpeg_path: 'x',
                                      decoder: -> { MTFixture.decoded(spec) })
    model = SketchupMock.build(spec, skp_path)
    Sketchup.active_model = model
    Setup.new(root, run_dir, skp_path, sha, model)
  end
end

class TestSkpSide < Test::Unit::TestCase
  SS = SibamboModelTruthV1::SkpSide
  Err = SibamboModelTruthV1::ModelTruthError

  def setup
    SS.quiet = true
    SS.reset!
    UI.instance_variable_set(:@callback, nil)
    Sketchup.version = '26.2.243'
    Sketchup.platform = :platform_win
  end

  def teardown
    SS.reset!
    UI.instance_variable_set(:@callback, nil)
    Sketchup.version = nil
  end

  def manifest(h)
    JSON.parse(File.read(File.join(h.run_dir, 'skp', 'manifest.json')))
  end

  def test_complete_capture_is_cooperative_and_read_only
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha, budget_records: 2)
    ticks = UI.run_until
    assert UI.stopped
    m = manifest(h)
    assert_equal true, m['complete']
    assert_operator m['runtime']['slice_count'], :>, 3
    assert_equal ticks, m['runtime']['slice_count']
    assert_equal 'skp', m['side']
    assert_equal 3, m['definition_count']
    %w[items.ndjson.gz definitions.ndjson tables.json exclusions.json bomc-texture-pixels.ndjson progress.json].each do |f|
      assert File.exist?(File.join(h.run_dir, 'skp', f)), f
    end
    assert_equal false, h.model.modified?
    tables = JSON.parse(File.read(File.join(h.run_dir, 'skp', 'tables.json')))
    assert_equal %w[Walls Hidden], tables['tags'].map { |t| t['name'] }
    assert_equal 'Brick', tables['materials'][0]['name']
    assert_equal %w[true false], tables['materials'][0]['pixels'].keys
    assert_nil tables['materials'][1]['pixels']
    pix = File.read(File.join(h.run_dir, 'skp', 'bomc-texture-pixels.ndjson')).lines.map { |l| JSON.parse(l) }
    assert_equal 1, pix.length
    assert_equal 'OK', pix[0]['status']
    # same digests as the BOMC side for identical content
    bm = JSON.parse(File.read(File.join(h.run_dir, 'bomc', 'manifest.json')))
    assert_equal bm['root_digest'], m['root_digest']
    assert_equal bm['tools']['canonical_rb_sha256'], m['tools']['canonical_rb_sha256']
  end

  def test_small_budget_resumes_the_fiber_many_times
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha, budget_records: 1)
    many = UI.run_until
    assert_operator many, :>, 20
  end

  def test_modified_mid_run_aborts
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha, budget_records: 2)
    3.times { UI.tick }
    h.model.modified = true
    UI.run_until
    m = manifest(h)
    assert_equal false, m['complete']
    assert_equal 'source model changed', m['error']['message']
    assert File.exist?(File.join(h.run_dir, 'skp', 'items.ndjson.gz'))
  end

  def test_cancel_stops_at_next_tick_and_keeps_outputs
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha, budget_records: 2)
    2.times { UI.tick }
    SS.cancel
    UI.run_until
    m = manifest(h)
    assert_equal false, m['complete']
    assert_equal 'cancelled', m['error']['message']
  end

  def test_timeout_ends_incomplete
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha, budget_records: 2, time_limit_s: 0)
    UI.run_until
    assert_equal 'timeout', manifest(h)['error']['message']
  end

  def test_wrong_version_raises_before_writing
    h = SkpHarness.setup
    Sketchup.version = '26.2.244'
    assert_raise(Err) { SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha) }
    refute File.exist?(File.join(h.run_dir, 'skp'))
    assert_nil UI.callback
  end

  def test_preconditions_raise_without_writing
    h = SkpHarness.setup
    assert_raise(Err) { SS.capture(run_dir: h.run_dir, expected_source_sha256: 'f' * 64) }
    h.model.modified = true
    assert_raise(Err) { SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha) }
    h.model.modified = false
    FileUtils.rm(File.join(h.run_dir, 'bomc', 'manifest.json'))
    assert_raise(Err) { SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha) }
    refute File.exist?(File.join(h.run_dir, 'skp'))
  end

  def test_second_capture_while_active_is_refused
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha, budget_records: 2)
    assert_raise(Err) { SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha) }
    UI.run_until
  end

  def test_counters_and_exclusions
    spec = MTFixture.spec
    h = SkpHarness.setup(spec)
    # an unsupported entity class, a text without point, a deleted edge
    guide = Class.new(Sketchup::Entity)
    Object.const_set(:MockGuideLine, guide) unless Object.const_defined?(:MockGuideLine)
    h.model.entities << MockGuideLine.new
    t = Sketchup::Text.new
    t.text = 'x'
    t.point = nil
    h.model.entities << t
    gone = Sketchup::Edge.new
    gone.deleted = true
    h.model.entities << gone
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha)
    UI.run_until
    ex = JSON.parse(File.read(File.join(h.run_dir, 'skp', 'exclusions.json')))
    assert_equal({ 'MockGuideLine' => 1 }, ex['excluded'])
    assert_equal 1, ex['counters']['texts_without_point']
    assert_equal 1, ex['counters']['deleted_skipped']
    assert_equal 0, ex['counters']['uv_q0_vertices']
    assert_equal true, manifest(h)['complete']
  end

  def test_each_image_rep_flag_is_recorded_on_its_own
    spec = MTFixture.spec
    spec[:textures][0][:bpp_false] = 8
    h = SkpHarness.setup(spec)
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha)
    UI.run_until
    assert_equal true, manifest(h)['complete']
    px = JSON.parse(File.read(File.join(h.run_dir, 'skp', 'tables.json')))['materials'][0]['pixels']
    assert_equal 24, px['true']['bpp']
    assert_nil px['true']['status']
    assert_equal 'FAIL', px['false']['status']
    assert_equal 'skp_image_rep_error', px['false']['code']
    assert_equal false, px['false']['flag']
    assert_equal 8, px['false']['bits_per_pixel']
    assert_match(/unsupported_bpp/, px['false']['message'])
  end

  def test_manifest_records_the_slowest_slices_with_context_and_untimed_costs
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha, budget_records: 3)
    UI.run_until
    rt = manifest(h)['runtime']
    slow = rt['slowest_slices']
    assert_operator slow.length, :<=, 5
    assert_operator slow.length, :>=, 1
    assert_equal slow.map { |s| -s['ruby_ms'] }, slow.map { |s| -s['ruby_ms'] }.sort
    assert_equal rt['max_ruby_slice_ms'], slow.first['ruby_ms']
    first = slow.first
    %w[slice phase slice_ms native_ms ruby_ms records ctx_start ctx_end untimed_ms].each { |k| assert first.key?(k), k }
    ctxs = slow.flat_map { |s| [s['ctx_start'], s['ctx_end']] }.compact
    assert ctxs.any? { |c| c['phase'] == 'definitions' && c['definition_dfs'].is_a?(Integer) && c['entity_class'] }
    totals = rt['untimed_totals_ms']
    %w[entities_each_start face_loops mesh_polygons].each { |k| assert totals.key?(k), k }
    slow.each do |sl|
      assert_kind_of Hash, sl['gc']
      %w[count major minor allocated].each { |k| assert_kind_of Integer, sl['gc'][k], k }
      assert_operator sl['gc']['allocated'], :>=, 0
    end
    assert_kind_of Integer, rt['gc_run']['count']
    assert_operator rt['gc_run']['allocated'], :>, 0
    refute rt.key?('max_gc_in_slice_ms')
    refute rt['gc_run'].key?('time_ms')
    # thread/process CPU evidence and slice histogram
    cpu = rt['cpu']
    assert_include %w[clock_gettime fiddle], cpu['source']
    %w[thread_ms process_ms native_thread_ms max_ruby_cpu_slice_ms max_off_cpu_slice_ms].each { |k| assert_kind_of Numeric, cpu[k], k }
    assert_operator cpu['max_off_cpu_slice_ms'], :>=, 0.0
    hist = rt['slice_histogram']
    assert_equal %w[20 50 100 250], hist['ruby_ms'].keys
    assert_equal %w[20 50 100 250], hist['off_cpu_ms'].keys
    assert_equal hist['ruby_ms'].values, hist['ruby_ms'].values.sort.reverse
    slow.each do |sl|
      %w[thread_cpu_ms native_cpu_ms ruby_cpu_ms off_cpu_ms].each { |k| assert_kind_of Numeric, sl['cpu'][k], k }
      assert_operator sl['cpu']['off_cpu_ms'], :<=, sl['ruby_ms'] + 0.001
    end
    # pixel phases keep their own context (material/texture, flag, size, row)
    ctx = SS.instance_variable_get(:@ctx)
    assert_equal 'bomc_pixels', ctx[0]
    assert_equal 0, ctx[3]
    assert_equal ['0.jpg', 2, 2, 24], ctx[5][1, 4]
    # instrumentation never changes the result
    bm = JSON.parse(File.read(File.join(h.run_dir, 'bomc', 'manifest.json')))
    assert_equal bm['root_digest'], manifest(h)['root_digest']
  end

  def test_failed_texture_load_is_recorded_not_fatal
    h = SkpHarness.setup
    File.binwrite(File.join(h.run_dir, 'bomc', 'textures', '0.jpg'), 'garbage')
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha)
    UI.run_until
    pix = File.read(File.join(h.run_dir, 'skp', 'bomc-texture-pixels.ndjson')).lines.map { |l| JSON.parse(l) }
    assert_equal 'FAIL', pix[0]['status']
    assert_equal 'bomc_imagerep_load_error', pix[0]['code']
    assert_equal true, manifest(h)['complete']
  end

  def test_temp_env_is_redirected_and_restored
    before = [ENV['TEMP'], ENV['TMP']]
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha)
    assert_match(/skp[\\\/]tmp\z/, ENV['TEMP'])
    UI.run_until
    assert_equal before, [ENV['TEMP'], ENV['TMP']]
  end

  # Static self-check of plan C4.2: no mutating API, no producer code.
  def test_source_uses_only_allowed_sketchup_api
    src = File.read(File.expand_path('../skp_side.rb', __dir__))
    forbidden = %w[start_operation commit_operation abort_operation add_face add_line add_edges add_group add_instance add_cpoint
                   erase! entityID Observer model.save .save( save_copy write_all bom_engine BOMEngine
                   remove_observer add_observer transform! explode set_attribute attribute_dictionary]
    forbidden.each { |tok| assert_no_match(/#{Regexp.escape(tok)}/, src, "skp_side.rb must not use #{tok}") }
    assert_match(/\Arequire|# frozen_string_literal: true/, src)
    requires = src.scan(/^\s*require(?:_relative)?\s+'([^']+)'/).flatten
    # fiddle is required lazily for read-only GetThreadTimes/GetProcessTimes timing (evidence only)
    assert_equal %w[digest fileutils json zlib canonical fiddle], requires
    assert_equal ['material.persistent_id'], src.scan(/\w+\.persistent_id\b/)
    assert_match(/GetThreadTimes/, src)
    %w[GetCurrentThread GetCurrentProcess GetThreadTimes GetProcessTimes].each { |f| assert_match(/#{f}/, src) }
    assert_equal 4, src.scan(/lib\['(\w+)'\]/).flatten.length
    assert_equal %w[GetCurrentThread GetCurrentProcess GetThreadTimes GetProcessTimes], src.scan(/lib\['(\w+)'\]/).flatten
  end

  def test_cpu_probe_reports_a_source_and_samples
    r = SS.cpu_probe
    assert_include %w[clock_gettime fiddle], r[:source]
    assert_operator r[:thread_ms_after], :>=, r[:thread_ms_before]
  end

  def test_missing_cpu_clocks_degrade_to_nil_not_failure
    SS.instance_variable_set(:@cpu_source, 'none')
    h = SkpHarness.setup
    SS.capture(run_dir: h.run_dir, expected_source_sha256: h.sha)
    UI.run_until
    m = manifest(h)
    assert_equal true, m['complete']
    assert_equal 'none', m['runtime']['cpu']['source']
    assert_equal 0.0, m['runtime']['cpu']['thread_ms']
    assert_equal 0, m['runtime']['slice_histogram']['off_cpu_ms']['20']
    assert_nil m['runtime']['slowest_slices'].first['cpu']
  ensure
    SS.instance_variable_set(:@cpu_source, nil)
  end
end
