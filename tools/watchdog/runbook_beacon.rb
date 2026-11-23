# frozen_string_literal: true

require 'digest'
require 'json'

module SibamboWatchdogBeacon
  SCHEMA = 'sibambo-watchdog-beacon-v1'

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

  def utc_iso_now
    t = Time.now.utc
    t.strftime('%Y-%m-%dT%H:%M:%S.') + format('%03dZ', t.usec / 1000)
  end

  def write_beacon(beacon_path:, pid:, seq:, phase_group:, model:, run_dir:, skp_path:, **extra)
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
    File.rename(tmp_path, beacon_path)
    payload
  end

  def open_and_capture(skp_path:, run_dir:, expected_source_sha256:, beacon_path:, skp_side_path:, host: nil)
    host ||= SketchupHost.new

    raise BeaconError, "skp_path not found: #{skp_path}" unless File.file?(skp_path.to_s)
    raise BeaconError, "skp_side_path not found: #{skp_side_path}" unless File.file?(skp_side_path.to_s)

    bomc_manifest = File.join(run_dir.to_s, 'bomc', 'manifest.json')
    raise BeaconError, "bomc manifest missing: #{bomc_manifest}" unless File.file?(bomc_manifest)

    beacon_dir = File.dirname(beacon_path.to_s)
    raise BeaconError, "beacon directory missing: #{beacon_dir}" unless File.directory?(beacon_dir)
    raise BeaconError, "beacon_path must reside on D: (got #{beacon_path})" unless beacon_path.to_s.match?(/\Ad:/i)

    raise BeaconError, 'active model has unsaved changes' if host.active_model_modified?

    actual_sha = Digest::SHA256.file(skp_path).hexdigest.downcase
    if actual_sha != expected_source_sha256.to_s.downcase
      raise BeaconError, "SKP SHA-256 mismatch: expected #{expected_source_sha256}, got #{actual_sha}"
    end

    model_name = File.basename(skp_path, '.skp')
    pid = host.pid

    write_beacon(
      beacon_path: beacon_path,
      pid: pid,
      seq: 1,
      phase_group: 'open_file',
      model: model_name,
      run_dir: run_dir,
      skp_path: skp_path
    )

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = host.open_file(skp_path)
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

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
      write_beacon(
        beacon_path: beacon_path,
        pid: pid,
        seq: 2,
        phase_group: 'idle',
        model: model_name,
        run_dir: run_dir,
        skp_path: skp_path,
        error: err_msg
      )
      raise BeaconError, err_msg
    end

    open_status_val = status.is_a?(Integer) ? status : true
    open_duration_s = dt.round(3)

    write_beacon(
      beacon_path: beacon_path,
      pid: pid,
      seq: 2,
      phase_group: 'skp_capture',
      model: model_name,
      run_dir: run_dir,
      skp_path: skp_path,
      open_file_status: open_status_val,
      open_file_duration_s: open_duration_s
    )

    begin
      host.load_file(skp_side_path)
      host.capture(run_dir: run_dir, expected_source_sha256: expected_source_sha256)
    rescue StandardError => e
      write_beacon(
        beacon_path: beacon_path,
        pid: pid,
        seq: 3,
        phase_group: 'idle',
        model: model_name,
        run_dir: run_dir,
        skp_path: skp_path,
        error: "#{e.class}: #{e.message}"
      )
      raise
    end

    {
      open_file_status: open_status_val,
      open_file_duration_s: open_duration_s,
      beacon_path: beacon_path
    }
  end
end
