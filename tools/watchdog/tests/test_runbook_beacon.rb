# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'securerandom'

require_relative '../runbook_beacon'

class TestRunbookBeacon < Minitest::Test
  TMP_ROOT = 'D:/projects/sibambo/scratch/watchdog/tmp'

  class FakeHost
    attr_reader :calls, :loaded_paths

    def initialize(pid: 4242, modified_before: false, modified_after: false,
                   open_result: true, active_path_override: nil, capture_error: nil,
                   on_open_file: nil)
      @pid = pid
      @modified_before = modified_before
      @modified_after = modified_after
      @open_result = open_result
      @active_path_override = active_path_override
      @capture_error = capture_error
      @on_open_file = on_open_file
      @calls = []
      @loaded_paths = []
      @opened_path = nil
      @open_checked = false
    end

    attr_reader :pid

    def active_model_modified?
      @calls << :active_model_modified?
      @open_checked ? @modified_after : @modified_before
    end

    def open_file(path)
      @calls << :open_file
      @on_open_file.call(path) if @on_open_file
      @opened_path = path
      @open_checked = true
      @open_result
    end

    def active_model_path
      @calls << :active_model_path
      @active_path_override || @opened_path.to_s
    end

    def defer_next_tick(&block)
      @calls << :defer_next_tick
      block.call
    end

    def load_file(path)
      @calls << :load_file
      @loaded_paths << path
      true
    end

    def capture(run_dir:, expected_source_sha256:)
      @calls << :capture
      raise @capture_error if @capture_error

      true
    end
  end

  def setup
    FileUtils.mkdir_p(TMP_ROOT)
    @work_dir = File.join(TMP_ROOT, "beacon-test-#{SecureRandom.hex(4)}")
    @run_dir = File.join(@work_dir, 'run')
    FileUtils.mkdir_p(File.join(@run_dir, 'bomc'))
    File.binwrite(File.join(@run_dir, 'bomc', 'manifest.json'), '{"complete":true}')

    @skp_path = File.join(@work_dir, 'sample.skp')
    File.binwrite(@skp_path, "SKP-DUMMY-BYTES-#{SecureRandom.hex(8)}")
    @skp_sha = Digest::SHA256.file(@skp_path).hexdigest

    @skp_side_path = File.join(@work_dir, 'skp_side.rb')
    @skp_side_bytes = "# dummy skp_side\nmodule DummySide; end\n"
    File.binwrite(@skp_side_path, @skp_side_bytes)

    @beacon_path = File.join(@work_dir, 'beacon.json')
  end

  def teardown
    FileUtils.rm_rf(@work_dir)
  end

  # B1: success -> seq 1 open_file then skp_capture with lifecycle + open_file_duration_s, no .tmp left
  def test_b1_success_sequence_and_no_tmp
    seen_during_open = nil
    host = FakeHost.new(
      open_result: 1,
      on_open_file: lambda { |_|
        seen_during_open = JSON.parse(File.binread(@beacon_path))
      }
    )

    res = SibamboWatchdogBeacon.open_and_capture(
      skp_path: @skp_path,
      run_dir: @run_dir,
      expected_source_sha256: @skp_sha,
      beacon_path: @beacon_path,
      skp_side_path: @skp_side_path,
      host: host
    )

    assert_equal 1, seen_during_open['seq']
    assert_equal 'open_file', seen_during_open['phase_group']
    assert_equal 'sample', seen_during_open['model']
    assert_equal 'started', seen_during_open['lifecycle'][0]['status']

    final_beacon = JSON.parse(File.binread(@beacon_path))
    assert_equal 'skp_capture', final_beacon['phase_group']
    assert final_beacon.key?('open_file_duration_s')
    assert_equal 1, final_beacon['open_file_status']
    assert_equal 'completed', final_beacon['lifecycle'][0]['status']
    assert_equal 'started', final_beacon['lifecycle'][1]['status']
    refute File.exist?("#{@beacon_path}.tmp")
    assert_equal @beacon_path, res[:beacon_path]
  end

  # B2: open_file returns nil -> beacon idle with error, capture never called
  def test_b2_open_file_nil_writes_idle_error
    host = FakeHost.new(open_result: nil)

    assert_raises(SibamboWatchdogBeacon::BeaconError) do
      SibamboWatchdogBeacon.open_and_capture(
        skp_path: @skp_path,
        run_dir: @run_dir,
        expected_source_sha256: @skp_sha,
        beacon_path: @beacon_path,
        skp_side_path: @skp_side_path,
        host: host
      )
    end

    beacon = JSON.parse(File.binread(@beacon_path))
    assert_equal 'idle', beacon['phase_group']
    assert_equal 'failed', beacon['lifecycle'][0]['status']
    assert beacon['error'] && !beacon['error'].empty?
    refute_includes host.calls, :capture
  end

  # B3: dirty model -> raises before any beacon write
  def test_b3_dirty_model_raises_before_beacon_write
    host = FakeHost.new(modified_before: true)

    assert_raises(SibamboWatchdogBeacon::BeaconError) do
      SibamboWatchdogBeacon.open_and_capture(
        skp_path: @skp_path,
        run_dir: @run_dir,
        expected_source_sha256: @skp_sha,
        beacon_path: @beacon_path,
        skp_side_path: @skp_side_path,
        host: host
      )
    end

    refute File.exist?(@beacon_path)
    assert_equal [:active_model_modified?], host.calls
  end

  # B4: SHA mismatch -> raises before open_file
  def test_b4_sha_mismatch_raises_before_open_file
    host = FakeHost.new

    assert_raises(SibamboWatchdogBeacon::BeaconError) do
      SibamboWatchdogBeacon.open_and_capture(
        skp_path: @skp_path,
        run_dir: @run_dir,
        expected_source_sha256: '0' * 64,
        beacon_path: @beacon_path,
        skp_side_path: @skp_side_path,
        host: host
      )
    end

    refute File.exist?(@beacon_path)
    refute_includes host.calls, :open_file
  end

  # B5: skp_side_path bytes identical before/after and loaded once
  def test_b5_skp_side_untouched_and_loaded_once
    host = FakeHost.new
    before_bytes = File.binread(@skp_side_path)

    SibamboWatchdogBeacon.open_and_capture(
      skp_path: @skp_path,
      run_dir: @run_dir,
      expected_source_sha256: @skp_sha,
      beacon_path: @beacon_path,
      skp_side_path: @skp_side_path,
      host: host
    )

    after_bytes = File.binread(@skp_side_path)
    assert_equal before_bytes, after_bytes
    assert_equal [@skp_side_path], host.loaded_paths
  end

  # B6: exact host call sequence (including defer_next_tick, no save), beacon remains skp_capture
  def test_b6_exact_call_order_and_beacon_remains_skp_capture
    host = FakeHost.new

    SibamboWatchdogBeacon.open_and_capture(
      skp_path: @skp_path,
      run_dir: @run_dir,
      expected_source_sha256: @skp_sha,
      beacon_path: @beacon_path,
      skp_side_path: @skp_side_path,
      host: host
    )

    assert_equal %i[
      active_model_modified?
      open_file
      active_model_path
      active_model_modified?
      defer_next_tick
      load_file
      capture
    ], host.calls

    final_beacon = JSON.parse(File.binread(@beacon_path))
    assert_equal 'skp_capture', final_beacon['phase_group']
  end

  # B7: stage_timings_ms and lifecycle duration_ms recorded
  def test_b7_stage_timings_and_lifecycle_recorded
    host = FakeHost.new
    res = SibamboWatchdogBeacon.open_and_capture(
      skp_path: @skp_path,
      run_dir: @run_dir,
      expected_source_sha256: @skp_sha,
      beacon_path: @beacon_path,
      skp_side_path: @skp_side_path,
      host: host
    )

    final_beacon = JSON.parse(File.binread(@beacon_path))
    timings = final_beacon['stage_timings_ms']
    %w[pre_open_sha_ms open_file_ms post_open_settle_ms load_skp_side_ms capture_call_ms].each do |k|
      assert timings.key?(k), "Missing stage timing #{k}"
      assert_kind_of Numeric, timings[k]
    end
    assert_equal timings, res[:stage_timings_ms]
    assert_kind_of Numeric, final_beacon['lifecycle'][0]['duration_ms']
  end

  # B8 (FI-1 transient): injected Errno::EACCES x3 succeeds on attempt 4
  def test_b8_rename_retry_recovers_from_transient_eacces
    attempts = 0
    tmp = "#{@beacon_path}.tmp"
    File.binwrite(tmp, '{"ok":true}')
    sleeps = []

    rename_stub = lambda do |src, dst|
      attempts += 1
      raise Errno::EACCES, 'simulated AV/watcher lock' if attempts <= 3

      File.binwrite(dst, File.binread(src))
      File.delete(src)
    end

    File.stub(:rename, rename_stub) do
      SibamboWatchdogBeacon.rename_with_retry(tmp, @beacon_path, sleep_fn: ->(s) { sleeps << s })
    end

    assert_equal 4, attempts
    assert_equal 3, sleeps.length
    assert File.file?(@beacon_path)
  end

  # B9 (FI-1 exhausted): persistent Errno::EACCES raises BeaconError after bounded retries
  def test_b9_rename_retry_exhaustion_raises_beacon_error
    attempts = 0
    tmp = "#{@beacon_path}.tmp"
    File.binwrite(tmp, '{"ok":true}')
    sleeps = []

    rename_stub = lambda do |_src, _dst|
      attempts += 1
      raise Errno::EACCES, 'persistent lock'
    end

    File.stub(:rename, rename_stub) do
      assert_raises(SibamboWatchdogBeacon::BeaconError) do
        SibamboWatchdogBeacon.rename_with_retry(tmp, @beacon_path, sleep_fn: ->(s) { sleeps << s })
      end
    end

    assert_equal SibamboWatchdogBeacon::RENAME_BACKOFF_S.length + 1, attempts
    assert_equal SibamboWatchdogBeacon::RENAME_BACKOFF_S.length, sleeps.length
  end
end
