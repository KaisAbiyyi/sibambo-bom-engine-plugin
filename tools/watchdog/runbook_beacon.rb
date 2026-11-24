# frozen_string_literal: true

require 'digest'
require 'json'

module SibamboWatchdogBeacon
  SCHEMA = 'sibambo-watchdog-beacon-v1'
  RENAME_BACKOFF_S = [0.005, 0.010, 0.020, 0.040, 0.080, 0.100, 0.100, 0.100].freeze

  class BeaconError < StandardError; end

  class SketchupHost
    def pid
      Process.pid
    end

    def active_model_modified?
      m = Sketchup.active_model
      m ? (m.modified? ? true : false) : false
    end

    def open_file(path)
      Sketchup.open_file(path, with_status: true)
    end

    def active_model_path
      m = Sketchup.active_model
      m ? m.path.to_s : ''
    end

    def defer_next_tick(&block)
      UI.start_timer(0.05, false) { block.call }
    end

    def load_file(path)
      Kernel.load(path)
    end

    def capture(run_dir:, expected_source_sha256:)
      SibamboModelTruthV1::SkpSide.capture(run_dir: run_dir, expected_source_sha256: expected_source_sha256)
    end
  end

  module_function

  def canonical_path(path)
    path.to_s.tr('\\', '/').downcase
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def utc_iso_now
    t = Time.now.utc
    t.strftime('%Y-%m-%dT%H:%M:%S.') + format('%03dZ', t.usec / 1000)
  end

  def rename_with_retry(src, dst, sleep_fn: nil)
    sleep_fn ||= ->(sec) { Kernel.sleep(sec) }
    attempts = 0
    begin
      File.rename(src, dst)
    rescue Errno::EACCES, Errno::EPERM => e
      if attempts < RENAME_BACKOFF_S.length
        sleep_fn.call(RENAME_BACKOFF_S[attempts])
        attempts += 1
        retry
      end
      raise BeaconError, "atomic beacon rename failed after #{attempts} retries: #{e.class}: #{e.message}"
    end
  end

  def write_beacon(beacon_path:, pid:, seq:, phase_group:, model:, run_dir:, skp_path:, sleep_fn: nil, **extra)
    payload = {
      'schema' => SCHEMA,
      'pid' => pid,
      'seq' => seq,
      'phase_group' => phase_group,
      'model' => model,
      'run_dir' => run_dir,
      'skp_path' => skp_path,
      'updated_utc' => utc_iso_now
    }
    extra.each { |k, v| payload[k.to_s] = v }

    tmp_path = "#{beacon_path}.tmp"
    File.open(tmp_path, 'wb') { |f| f.write(JSON.generate(payload) + "\n") }
    rename_with_retry(tmp_path, beacon_path, sleep_fn: sleep_fn)
    payload
  end

  def open_and_capture(skp_path:, run_dir:, expected_source_sha256:, beacon_path:, skp_side_path:, host: nil, sleep_fn: nil)
    host ||= SketchupHost.new

    raise BeaconError, "skp_path not found: #{skp_path}" unless File.file?(skp_path.to_s)
    raise BeaconError, "skp_side_path not found: #{skp_side_path}" unless File.file?(skp_side_path.to_s)

    bomc_manifest = File.join(run_dir.to_s, 'bomc', 'manifest.json')
    raise BeaconError, "bomc manifest missing: #{bomc_manifest}" unless File.file?(bomc_manifest)

    beacon_dir = File.dirname(beacon_path.to_s)
    raise BeaconError, "beacon directory missing: #{beacon_dir}" unless File.directory?(beacon_dir)
    raise BeaconError, "beacon_path must reside on D: (got #{beacon_path})" unless beacon_path.to_s.match?(/\Ad:/i)

    raise BeaconError, 'active model has unsaved changes' if host.active_model_modified?

    t_sha = monotonic
    actual_sha = Digest::SHA256.file(skp_path).hexdigest.downcase
    pre_open_sha_ms = ((monotonic - t_sha) * 1000.0).round(1)
    if actual_sha != expected_source_sha256.to_s.downcase
      raise BeaconError, "SKP SHA-256 mismatch: expected #{expected_source_sha256}, got #{actual_sha}"
    end

    model_name = File.basename(skp_path, '.skp')
    pid = host.pid
    stage_timings_ms = { 'pre_open_sha_ms' => pre_open_sha_ms }
    lifecycle = [
      {
        'seq' => 1,
        'phase_group' => 'open_file',
        'status' => 'started',
        'started_utc' => utc_iso_now,
        'ended_utc' => nil,
        'duration_ms' => nil
      }
    ]

    write_beacon(
      beacon_path: beacon_path,
      pid: pid,
      seq: 1,
      phase_group: 'open_file',
      model: model_name,
      run_dir: run_dir,
      skp_path: skp_path,
      skp_sha256: expected_source_sha256.to_s.downcase,
      lifecycle: lifecycle,
      stage_timings_ms: stage_timings_ms,
      sleep_fn: sleep_fn
    )

    t0 = monotonic
    status = host.open_file(skp_path)
    open_file_ms = ((monotonic - t0) * 1000.0).round(1)
    stage_timings_ms['open_file_ms'] = open_file_ms

    open_ok = !status.nil? && status != false
    if open_ok
      actual_model_path = host.active_model_path
      modified_after = host.active_model_modified?
      if canonical_path(actual_model_path) != canonical_path(skp_path)
        open_ok = false
        err_msg = "active model path mismatch after open_file: #{actual_model_path}"
      elsif modified_after
        open_ok = false
        err_msg = 'active model became modified after open_file'
      end
    else
      err_msg = "open_file failed with status=#{status.inspect}"
    end

    unless open_ok
      lifecycle[0]['status'] = 'failed'
      lifecycle[0]['ended_utc'] = utc_iso_now
      lifecycle[0]['duration_ms'] = open_file_ms
      lifecycle[0]['error'] = err_msg
      write_beacon(
        beacon_path: beacon_path,
        pid: pid,
        seq: 2,
        phase_group: 'idle',
        model: model_name,
        run_dir: run_dir,
        skp_path: skp_path,
        skp_sha256: expected_source_sha256.to_s.downcase,
        error: err_msg,
        lifecycle: lifecycle,
        stage_timings_ms: stage_timings_ms,
        sleep_fn: sleep_fn
      )
      raise BeaconError, err_msg
    end

    open_status_val = status.is_a?(Integer) ? status : true
    open_duration_s = (open_file_ms / 1000.0).round(3)
    t_settle = monotonic

    host.defer_next_tick do
      post_open_settle_ms = ((monotonic - t_settle) * 1000.0).round(1)
      stage_timings_ms['post_open_settle_ms'] = post_open_settle_ms
      lifecycle[0]['status'] = 'completed'
      lifecycle[0]['ended_utc'] = utc_iso_now
      lifecycle[0]['duration_ms'] = (open_file_ms + post_open_settle_ms).round(1)
      lifecycle << {
        'seq' => 2,
        'phase_group' => 'skp_capture',
        'status' => 'started',
        'started_utc' => utc_iso_now,
        'ended_utc' => nil,
        'duration_ms' => nil
      }

      write_beacon(
        beacon_path: beacon_path,
        pid: pid,
        seq: 2,
        phase_group: 'skp_capture',
        model: model_name,
        run_dir: run_dir,
        skp_path: skp_path,
        skp_sha256: expected_source_sha256.to_s.downcase,
        open_file_status: open_status_val,
        open_file_duration_s: open_duration_s,
        lifecycle: lifecycle,
        stage_timings_ms: stage_timings_ms,
        sleep_fn: sleep_fn
      )

      begin
        t_load = monotonic
        host.load_file(skp_side_path)
        stage_timings_ms['load_skp_side_ms'] = ((monotonic - t_load) * 1000.0).round(1)

        t_cap = monotonic
        host.capture(run_dir: run_dir, expected_source_sha256: expected_source_sha256)
        stage_timings_ms['capture_call_ms'] = ((monotonic - t_cap) * 1000.0).round(1)

        write_beacon(
          beacon_path: beacon_path,
          pid: pid,
          seq: 3,
          phase_group: 'skp_capture',
          model: model_name,
          run_dir: run_dir,
          skp_path: skp_path,
          skp_sha256: expected_source_sha256.to_s.downcase,
          open_file_status: open_status_val,
          open_file_duration_s: open_duration_s,
          lifecycle: lifecycle,
          stage_timings_ms: stage_timings_ms,
          sleep_fn: sleep_fn
        )
      rescue StandardError => e
        lifecycle[1]['status'] = 'failed'
        lifecycle[1]['ended_utc'] = utc_iso_now
        lifecycle[1]['error'] = "#{e.class}: #{e.message}"
        write_beacon(
          beacon_path: beacon_path,
          pid: pid,
          seq: 3,
          phase_group: 'idle',
          model: model_name,
          run_dir: run_dir,
          skp_path: skp_path,
          skp_sha256: expected_source_sha256.to_s.downcase,
          error: "#{e.class}: #{e.message}",
          lifecycle: lifecycle,
          stage_timings_ms: stage_timings_ms,
          sleep_fn: sleep_fn
        )
        raise
      end
    end

    {
      open_file_status: open_status_val,
      open_file_duration_s: open_duration_s,
      beacon_path: beacon_path,
      stage_timings_ms: stage_timings_ms
    }
  end
end
