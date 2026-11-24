# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'

module SibamboWatchdogSummarizer
  SCHEMA = 'sibambo-skp-watchdog-v1'
  SUMMARY_SCHEMA = 'sibambo-skp-watchdog-summary-v1'

  PHASE_CLASSES = {
    'open_file' => 'OPEN',
    'batch_open_skp' => 'OPEN',
    'skp_capture' => 'WORK',
    'batch_export' => 'WORK',
    'idle' => 'IDLE',
    'startup' => 'STARTUP',
    'unattributed' => 'UNKNOWN'
  }.freeze

  ALL_CLASSES = %w[OPEN WORK IDLE STARTUP UNKNOWN].freeze
  BUGSPLAT_RE = /bugsplat|bssndrpt/i.freeze
  HUNG_DURATION_THRESHOLD_MS = 5000.0

  module_function

  def phase_class_for(phase_group)
    PHASE_CLASSES.fetch(phase_group.to_s, 'UNKNOWN')
  end

  def parse_args(argv)
    opts = {
      session: nil,
      work_hung_limit_ms: 10_000.0,
      work_warn_ms: 3_000.0,
      modal_limit_ms: 30_000.0
    }
    parser = OptionParser.new do |o|
      o.on('--session DIR', String, 'Session directory containing events.ndjson') { |v| opts[:session] = v }
      o.on('--work-hung-limit-ms MS', Float, 'WORK/UNKNOWN hung limit in ms (default 10000)') { |v| opts[:work_hung_limit_ms] = v }
      o.on('--work-warn-ms MS', Float, 'WORK disclosure threshold in ms (default 3000)') { |v| opts[:work_warn_ms] = v }
      o.on('--modal-limit-ms MS', Float, 'WORK/UNKNOWN modal limit in ms (default 30000)') { |v| opts[:modal_limit_ms] = v }
    end
    parser.parse!(argv)
    opts
  end

  def modal_active?(tick)
    modals = tick['modal']
    return false unless modals.is_a?(Array) && !modals.empty?

    modals.any? do |m|
      if m.is_a?(Hash)
        cls = m['class']
        cls.nil? || cls.to_s == '#32770'
      else
        !m.nil?
      end
    end
  end

  def cut_phase_segments(ep)
    ticks = ep[:ticks]
    return [] if ticks.empty?

    groups = []
    current_group = [ticks[0]]
    current_pg = ticks[0]['phase_group'] || 'unattributed'

    ticks[1..-1].each do |t|
      pg = t['phase_group'] || 'unattributed'
      if pg == current_pg
        current_group << t
      else
        groups << current_group
        current_group = [t]
        current_pg = pg
      end
    end
    groups << current_group

    segments = []
    groups.each_with_index do |seg_ticks, idx|
      first_tick = seg_ticks[0]
      pg = first_tick['phase_group'] || 'unattributed'
      pc = phase_class_for(pg)
      start_mono = first_tick['mono_ms'].to_f.round(1)
      start_utc = first_tick['utc']

      if idx < groups.length - 1
        next_first = groups[idx + 1][0]
        end_mono = next_first['mono_ms'].to_f.round(1)
        end_utc = next_first['utc']
      else
        end_mono = ep[:end_mono_ms].to_f.round(1)
        end_utc = ep[:end_utc]
      end

      duration_ms = (end_mono - start_mono).round(1)
      duration_ms = 0.0 if duration_ms < 0.0

      os_hung_seen = seg_ticks.any? { |t| t['is_hung'] == true }
      ghost_seen = seg_ticks.any? { |t| t['ghost'] == true }
      title_nr_seen = seg_ticks.any? { |t| t['title_nr'] == true }
      lat_vals = seg_ticks.map { |t| t['probe_latency_ms'] }.compact.map(&:to_f)
      max_probe_latency_ms = lat_vals.empty? ? nil : lat_vals.max.round(1)
      ws_vals = seg_ticks.map { |t| t['working_set_mib'] }.compact.map(&:to_f)
      max_working_set_mib = ws_vals.empty? ? nil : ws_vals.max.round(1)
      children_union = seg_ticks.flat_map { |t| Array(t['children']) }.compact.map(&:to_s).uniq.sort
      model = seg_ticks.map { |t| t['model'] }.compact.last

      severity = if ep[:kind] == 'modal'
                   'modal'
                 elsif os_hung_seen || ghost_seen || title_nr_seen || duration_ms >= HUNG_DURATION_THRESHOLD_MS
                   'hung'
                 else
                   'stall'
                 end

      segments << {
        'id' => nil,
        'pid' => ep[:pid],
        'kind' => ep[:kind],
        'phase_group' => pg,
        'phase_class' => pc,
        'model' => model,
        'severity' => severity,
        'start_utc' => start_utc,
        'end_utc' => end_utc,
        'start_mono_ms' => start_mono,
        'end_mono_ms' => end_mono,
        'duration_ms' => duration_ms,
        'os_hung_seen' => os_hung_seen,
        'ghost_seen' => ghost_seen,
        'title_nr_seen' => title_nr_seen,
        'max_probe_latency_ms' => max_probe_latency_ms,
        'max_working_set_mib' => max_working_set_mib,
        'children_union' => children_union,
        'closed_by' => ep[:closed_by]
      }
    end

    segments
  end

  def update_episode_state(episodes_out, open_ep, tick, active, pid, kind)
    if active
      if open_ep.nil?
        return { pid: pid, kind: kind, ticks: [tick], pending_healthy: nil }
      end

      if open_ep[:pending_healthy]
        open_ep[:ticks] << open_ep[:pending_healthy]
        open_ep[:pending_healthy] = nil
      end
      open_ep[:ticks] << tick
      return open_ep
    end

    return nil if open_ep.nil?

    if open_ep[:pending_healthy].nil?
      open_ep[:pending_healthy] = tick
      return open_ep
    end

    open_ep[:end_mono_ms] = open_ep[:pending_healthy]['mono_ms']
    open_ep[:end_utc] = open_ep[:pending_healthy]['utc']
    open_ep[:closed_by] = 'healthy_pair'
    episodes_out << open_ep
    nil
  end

  def close_open_episode(episodes_out, open_ep, end_mono_ms, end_utc, closed_by)
    return nil if open_ep.nil?

    open_ep[:end_mono_ms] = end_mono_ms
    open_ep[:end_utc] = end_utc
    open_ep[:closed_by] = closed_by
    episodes_out << open_ep
    nil
  end

  def build_error_summary(reasons:, events_sha256:, limits:, truncated_tail_line: false, session_end_missing: false, processes_seen: [], ticks_by_class: nil, no_window_samples: 0)
    ticks_by_class ||= ALL_CLASSES.each_with_object({}) { |c, h| h[c] = 0 }
    {
      'schema' => SUMMARY_SCHEMA,
      'verdict' => 'ERROR',
      'exit_code' => 2,
      'reasons' => reasons,
      'gates' => {
        'A' => { 'passed' => false, 'limit_ms' => limits[:work_hung_limit_ms], 'breach_count' => 0, 'breaches' => [] },
        'B' => [],
        'C' => {
          'open_hung_count' => 0, 'max_open_hung_ms' => 0.0,
          'idle_hung_count' => 0, 'max_idle_hung_ms' => 0.0,
          'startup_hung_count' => 0, 'max_startup_hung_ms' => 0.0
        },
        'U' => { 'passed' => false, 'limit_ms' => limits[:work_hung_limit_ms], 'breach_count' => 0, 'breaches' => [] },
        'D' => {
          'passed' => false, 'modal_limit_ms' => limits[:modal_limit_ms],
          'bugsplat_children' => [], 'work_exits' => [],
          'modal_breaches' => [], 'disclosed_modals' => [],
          'nonzero_exit_outside_work' => [],
          'capture_failures' => []
        }
      },
      'processes_seen' => processes_seen,
      'ticks_by_class' => ticks_by_class,
      'no_window_samples' => no_window_samples,
      'lifecycle_phases_seen' => [],
      'capture_terminals' => [],
      'capture_progress_stalls' => [],
      'observer_overhead' => nil,
      'truncated_tail_line' => truncated_tail_line,
      'session_end_missing' => session_end_missing,
      'events_sha256' => events_sha256,
      'limits' => {
        'work_hung_limit_ms' => limits[:work_hung_limit_ms],
        'work_warn_ms' => limits[:work_warn_ms],
        'modal_limit_ms' => limits[:modal_limit_ms]
      }
    }
  end

  def render_markdown(summary, segments)
    lines = []
    lines << '# SketchUp Watchdog Summary'
    lines << ''
    lines << "**Verdict:** `#{summary['verdict']}` (exit #{summary['exit_code']})"
    if summary['reasons'] && !summary['reasons'].empty?
      lines << "**Reasons:** #{summary['reasons'].map { |r| "`#{r}`" }.join(', ')}"
    end
    lines << "**Events SHA-256:** `#{summary['events_sha256'] || 'none'}`"
    lines << ''

    gates = summary['gates']
    lines << '## Gate Table'
    lines << ''
    lines << '| Gate | Status | Detail |'
    lines << '|---|---|---|'
    a = gates['A']
    lines << "| `G-RT4'-A` | #{summary['verdict'] == 'ERROR' ? 'ERROR' : (a['passed'] ? 'PASS' : 'FAIL')} | WORK hung > #{a['limit_ms']} ms: #{a['breach_count']} |"
    lines << "| `G-RT4'-B` | INFO | WORK stall/hung segments >= #{summary['limits']['work_warn_ms']} ms: #{gates['B'].length} |"
    c = gates['C']
    lines << "| `G-RT4'-C` | INFO | OPEN hung #{c['open_hung_count']} (max #{c['max_open_hung_ms']} ms); IDLE hung #{c['idle_hung_count']} (max #{c['max_idle_hung_ms']} ms); STARTUP hung #{c['startup_hung_count']} (max #{c['max_startup_hung_ms']} ms) |"
    u = gates['U']
    lines << "| `G-RT4'-U` | #{summary['verdict'] == 'ERROR' ? 'ERROR' : (u['passed'] ? 'PASS' : 'FAIL')} | UNKNOWN hung > #{u['limit_ms']} ms: #{u['breach_count']} |"
    d = gates['D']
    cap_fail_count = (d['capture_failures'] || []).length
    d_detail = "bugsplat=#{d['bugsplat_children'].length}, work_exits=#{d['work_exits'].length}, modal_breaches=#{d['modal_breaches'].length}, capture_failures=#{cap_fail_count}"
    lines << "| `G-RT4'-D` | #{summary['verdict'] == 'ERROR' ? 'ERROR' : (d['passed'] ? 'PASS' : 'FAIL')} | #{d_detail} |"
    lines << ''

    lines << '## Ticks by Phase Class'
    lines << ''
    lines << '| Class | Ticks |'
    lines << '|---|---|'
    ALL_CLASSES.each do |cls|
      lines << "| `#{cls}` | #{summary['ticks_by_class'][cls] || 0} |"
    end
    lines << "| `no_window_samples` | #{summary['no_window_samples']} |"
    lines << ''

    lines << "## WORK Segments >= #{summary['limits']['work_warn_ms']} ms"
    lines << ''
    if gates['B'].empty?
      lines << 'None.'
    else
      lines << '| ID | PID | Phase | Model | Severity | Duration (ms) | Start UTC | End UTC | Max WS (MiB) | Signals | Children |'
      lines << '|---|---|---|---|---|---:|---|---|---:|---|---|'
      gates['B'].each do |seg|
        ep = segments.find { |s| s['id'] == seg['id'] }
        sigs = []
        if ep
          sigs << 'os_hung' if ep['os_hung_seen']
          sigs << 'ghost' if ep['ghost_seen']
          sigs << '(Not Responding)' if ep['title_nr_seen']
        end
        sig_str = sigs.empty? ? '-' : sigs.join(', ')
        ws_str = seg['max_working_set_mib'].nil? ? '-' : seg['max_working_set_mib']
        ch = seg['children_union'].empty? ? '-' : seg['children_union'].join(', ')
        lines << "| #{seg['id']} | #{seg['pid']} | #{seg['phase_group']} | #{seg['model'] || '-'} | #{seg['severity']} | #{seg['duration_ms']} | #{seg['start_utc']} | #{seg['end_utc']} | #{ws_str} | #{sig_str} | #{ch} |"
      end
    end
    lines << ''

    lines << '## OPEN / IDLE / STARTUP Hung Tallies'
    lines << ''
    lines << "- OPEN hung count: #{c['open_hung_count']}, max duration: #{c['max_open_hung_ms']} ms"
    lines << "- IDLE hung count: #{c['idle_hung_count']}, max duration: #{c['max_idle_hung_ms']} ms"
    lines << "- STARTUP hung count: #{c['startup_hung_count']}, max duration: #{c['max_startup_hung_ms']} ms"
    lines << ''

    lines << '## Dialogs (#32770)'
    lines << ''
    all_modals = segments.select { |s| s['kind'] == 'modal' }
    if all_modals.empty?
      lines << 'None.'
    else
      lines << '| ID | PID | Class | Phase | Duration (ms) | Start UTC | End UTC |'
      lines << '|---|---|---|---|---:|---|---|'
      all_modals.each do |m|
        lines << "| #{m['id']} | #{m['pid']} | #{m['phase_class']} | #{m['phase_group']} | #{m['duration_ms']} | #{m['start_utc']} | #{m['end_utc']} |"
      end
    end
    lines << ''

    lines << '## Process Exits & Children'
    lines << ''
    if summary['processes_seen'].empty?
      lines << 'No processes seen.'
    else
      summary['processes_seen'].each do |p|
        readable_str = p['exit_code_readable'].nil? ? 'null' : p['exit_code_readable']
        lines << "- PID #{p['pid']}: image=`#{p['image_path']}`, exit_code=`#{p['exit_code'].nil? ? 'null' : p['exit_code']}`, readable=`#{readable_str}`, exit_phase=`#{p['exit_phase_group'] || 'none'}`"
      end
    end
    unless d['bugsplat_children'].empty?
      lines << "- Crash-reporter children detected: #{d['bugsplat_children'].map { |b| "#{b['name']} (pid #{b['pid']} at #{b['utc']})" }.join(', ')}"
    end
    unless d['nonzero_exit_outside_work'].empty?
      lines << "- Non-zero exit outside WORK: #{d['nonzero_exit_outside_work'].map { |e| "pid #{e['pid']} code=#{e['exit_code']} class=#{e['phase_class']}" }.join(', ')}"
    end
    lines << ''

    lines << '## Flags'
    lines << ''
    lines << "- `truncated_tail_line`: #{summary['truncated_tail_line']}"
    lines << "- `session_end_missing`: #{summary['session_end_missing']}"
    lines << ''

    lc_seen = summary['lifecycle_phases_seen'] || []
    if !lc_seen.empty?
      lines << '## Lifecycle Phases'
      lines << ''
      lines << '| PID | Seq | Phase | Status | Duration (ms) | Started UTC | Ended UTC |'
      lines << '|---|---:|---|---|---:|---|---|'
      lc_seen.each do |lc|
        dur_str = lc['duration_ms'].nil? ? '-' : lc['duration_ms']
        lines << "| #{lc['pid']} | #{lc['seq']} | #{lc['phase_group']} | #{lc['status']} | #{dur_str} | #{lc['started_utc'] || '-'} | #{lc['ended_utc'] || '-'} |"
      end
      lines << ''
    end

    cap_terms = summary['capture_terminals'] || []
    if !cap_terms.empty?
      lines << '## Capture Terminal'
      lines << ''
      cap_terms.each do |ct|
        lines << "- PID #{ct['pid']}: complete=`#{ct['complete']}`, manifest=`#{ct['manifest_path']}`, error=`#{ct['error'] || 'none'}`"
      end
      lines << ''
    end

    cap_stalls = summary['capture_progress_stalls'] || []
    if !cap_stalls.empty?
      lines << '## Capture Progress Stalls'
      lines << ''
      cap_stalls.each do |cs|
        lines << "- PID #{cs['pid']}: stale_seconds=#{cs['stale_seconds']}, last_progress_utc=#{cs['last_progress_utc']}, at=#{cs['utc']}"
      end
      lines << ''
    end

    ov = summary['observer_overhead']
    if ov
      lines << '## Observer Overhead'
      lines << ''
      lines << "- wall_ms: #{ov['wall_ms']}, watcher_cpu_ms: #{ov['watcher_cpu_ms']}, cpu_pct_core: #{ov['cpu_pct_core']}%"
      lines << ''
    end

    lines.join("\n")
  end

  def write_outputs(session_dir, summary, segments)
    return unless session_dir && Dir.exist?(session_dir)

    if segments
      File.open(File.join(session_dir, 'episodes.json'), 'wb') do |f|
        f.write(JSON.pretty_generate(segments) + "\n")
      end
    end
    File.open(File.join(session_dir, 'watchdog-summary.json'), 'wb') do |f|
      f.write(JSON.pretty_generate(summary) + "\n")
    end
    File.open(File.join(session_dir, 'watchdog-summary.md'), 'wb') do |f|
      f.write(render_markdown(summary, segments || []))
    end
  end

  def summarize(opts)
    session_dir = opts[:session]
    limits = {
      work_hung_limit_ms: opts[:work_hung_limit_ms],
      work_warn_ms: opts[:work_warn_ms],
      modal_limit_ms: opts[:modal_limit_ms]
    }

    if session_dir.nil? || session_dir.empty? || !File.file?(File.join(session_dir, 'events.ndjson'))
      summary = build_error_summary(
        reasons: ['MISSING_EVENTS_FILE'],
        events_sha256: nil,
        limits: limits
      )
      write_outputs(session_dir, summary, nil)
      return summary
    end

    events_path = File.join(session_dir, 'events.ndjson')
    raw_bytes = File.binread(events_path)
    events_sha256 = Digest::SHA256.hexdigest(raw_bytes)
    raw_lines = raw_bytes.force_encoding('UTF-8').lines

    if raw_lines.empty?
      summary = build_error_summary(
        reasons: ['INVALID_SESSION_START'],
        events_sha256: events_sha256,
        limits: limits
      )
      write_outputs(session_dir, summary, nil)
      return summary
    end

    first_obj = begin
      JSON.parse(raw_lines[0])
    rescue JSON::ParserError, Encoding::InvalidByteSequenceError
      nil
    end

    unless first_obj.is_a?(Hash) && first_obj['type'] == 'session_start' && first_obj['schema'] == SCHEMA
      summary = build_error_summary(
        reasons: ['INVALID_SESSION_START'],
        events_sha256: events_sha256,
        limits: limits
      )
      write_outputs(session_dir, summary, nil)
      return summary
    end

    events = [first_obj]
    truncated_tail_line = false

    raw_lines[1..-1].each_with_index do |line, idx|
      actual_idx = idx + 1
      is_last = (actual_idx == raw_lines.length - 1)
      parsed = begin
        obj = JSON.parse(line)
        obj.is_a?(Hash) ? obj : nil
      rescue JSON::ParserError, Encoding::InvalidByteSequenceError
        nil
      end

      if parsed.nil?
        if is_last
          truncated_tail_line = true
        else
          summary = build_error_summary(
            reasons: ['CORRUPT_LINE'],
            events_sha256: events_sha256,
            limits: limits,
            truncated_tail_line: truncated_tail_line
          )
          write_outputs(session_dir, summary, nil)
          return summary
        end
      else
        events << parsed
      end
    end

    session_end_events = events.select { |e| e['type'] == 'session_end' }
    session_end_missing = session_end_events.empty?
    session_end_error = session_end_events.any? { |e| e['reason'] == 'error' }
    last_event = events.last
    last_line_mono_ms = last_event['mono_ms']
    last_line_utc = last_event['utc']

    ticks_by_class = ALL_CLASSES.each_with_object({}) { |c, h| h[c] = 0 }
    no_window_samples = 0
    processes = {}
    process_order = []
    last_phase_group = {}
    open_stall = {}
    open_modal = {}
    closed_episodes = []
    bugsplat_children = []
    work_exits = []
    nonzero_exit_outside_work = []
    lifecycle_by_key = {}
    lifecycle_order = []
    capture_terminals = []
    capture_progress_stalls = []

    events.each do |ev|
      type = ev['type']
      pid = ev['pid']

      case type
      when 'process_started'
        unless processes.key?(pid)
          process_order << pid
          processes[pid] = {
            'pid' => pid,
            'creation_utc' => ev['creation_utc'],
            'image_path' => ev['image_path'],
            'exit_code' => nil,
            'exit_code_readable' => nil,
            'exit_phase_group' => nil,
            'exit_phase_class' => nil
          }
        end
      when 'phase_changed'
        last_phase_group[pid] = ev['to']
      when 'beacon_lifecycle'
        key = [pid.to_i, ev['seq'].to_i]
        lifecycle_order << key unless lifecycle_by_key.key?(key)
        lifecycle_by_key[key] = {
          'pid' => pid,
          'seq' => ev['seq'],
          'phase_group' => ev['phase_group'],
          'status' => ev['status'],
          'model' => ev['model'],
          'started_utc' => ev['started_utc'],
          'ended_utc' => ev['ended_utc'],
          'duration_ms' => ev['duration_ms'],
          'stage_timings_ms' => ev['stage_timings_ms'],
          'error' => ev['error']
        }
      when 'capture_terminal'
        last_phase_group[pid] = 'idle' if ev['complete'] == true || ev['complete'] == false
        capture_terminals << {
          'pid' => pid,
          'run_dir' => ev['run_dir'],
          'complete' => ev['complete'],
          'manifest_path' => ev['manifest_path'],
          'error' => ev['error'],
          'utc' => ev['utc'],
          'mono_ms' => ev['mono_ms']
        }
      when 'capture_progress_stalled'
        capture_progress_stalls << {
          'pid' => pid,
          'run_dir' => ev['run_dir'],
          'stale_seconds' => ev['stale_seconds'],
          'last_progress_utc' => ev['last_progress_utc'],
          'utc' => ev['utc'],
          'mono_ms' => ev['mono_ms']
        }
      when 'children_changed'
        Array(ev['children']).each do |name|
          if name.to_s =~ BUGSPLAT_RE
            bugsplat_children << { 'pid' => pid, 'name' => name.to_s, 'utc' => ev['utc'], 'mono_ms' => ev['mono_ms'] }
          end
        end
      when 'tick'
        pg = ev['phase_group'] || 'unattributed'
        pc = phase_class_for(pg)
        last_phase_group[pid] = pg
        ticks_by_class[pc] = (ticks_by_class[pc] || 0) + 1
        no_window_samples += 1 if ev['main_hwnd'].nil?

        Array(ev['children']).each do |name|
          if name.to_s =~ BUGSPLAT_RE
            bugsplat_children << { 'pid' => pid, 'name' => name.to_s, 'utc' => ev['utc'], 'mono_ms' => ev['mono_ms'] }
          end
        end

        is_stall = (ev['stall'] == true)
        open_stall[pid] = update_episode_state(closed_episodes, open_stall[pid], ev, is_stall, pid, 'stall')

        is_modal = modal_active?(ev)
        open_modal[pid] = update_episode_state(closed_episodes, open_modal[pid], ev, is_modal, pid, 'modal')
      when 'process_exited'
        exit_pg = last_phase_group[pid]
        exit_pc = exit_pg ? phase_class_for(exit_pg) : nil
        if processes.key?(pid)
          processes[pid]['exit_code'] = ev['exit_code']
          processes[pid]['exit_code_readable'] = ev['exit_code_readable']
          processes[pid]['exit_phase_group'] = exit_pg
          processes[pid]['exit_phase_class'] = exit_pc
        end

        open_stall[pid] = close_open_episode(closed_episodes, open_stall[pid], ev['mono_ms'], ev['utc'], 'process_exited')
        open_modal[pid] = close_open_episode(closed_episodes, open_modal[pid], ev['mono_ms'], ev['utc'], 'process_exited')

        if exit_pc == 'WORK'
          work_exits << {
            'pid' => pid,
            'exit_code' => ev['exit_code'],
            'exit_code_readable' => ev['exit_code_readable'],
            'phase_group' => exit_pg,
            'utc' => ev['utc'],
            'mono_ms' => ev['mono_ms']
          }
        elsif !ev['exit_code'].nil? && ev['exit_code'] != 0
          nonzero_exit_outside_work << {
            'pid' => pid,
            'exit_code' => ev['exit_code'],
            'phase_group' => exit_pg,
            'phase_class' => exit_pc,
            'utc' => ev['utc'],
            'mono_ms' => ev['mono_ms']
          }
        end
      end
    end

    open_stall.each do |pid, ep|
      open_stall[pid] = close_open_episode(closed_episodes, ep, last_line_mono_ms, last_line_utc, 'eof')
    end
    open_modal.each do |pid, ep|
      open_modal[pid] = close_open_episode(closed_episodes, ep, last_line_mono_ms, last_line_utc, 'eof')
    end

    processes_seen = process_order.map { |pid| processes[pid] }

    error_reasons = []
    error_reasons << 'WATCHDOG_SESSION_ERROR' if session_end_error
    error_reasons << 'NO_TARGET_SEEN' if processes_seen.empty?
    error_reasons << 'NO_WORK_OBSERVED' if ticks_by_class['WORK'] == 0

    unless error_reasons.empty?
      summary = build_error_summary(
        reasons: error_reasons,
        events_sha256: events_sha256,
        limits: limits,
        truncated_tail_line: truncated_tail_line,
        session_end_missing: session_end_missing,
        processes_seen: processes_seen,
        ticks_by_class: ticks_by_class,
        no_window_samples: no_window_samples
      )
      write_outputs(session_dir, summary, nil)
      return summary
    end

    segments = closed_episodes.flat_map { |ep| cut_phase_segments(ep) }
    segments.sort_by! { |s| [s['start_mono_ms'], s['pid'].to_i, s['kind']] }
    segments.each_with_index { |s, idx| s['id'] = format('ep-%04d', idx + 1) }

    stall_segments = segments.select { |s| s['kind'] == 'stall' }
    modal_segments = segments.select { |s| s['kind'] == 'modal' }

    a_breaches = stall_segments.select do |s|
      s['phase_class'] == 'WORK' && s['severity'] == 'hung' && s['duration_ms'] > limits[:work_hung_limit_ms]
    end
    b_segments = stall_segments.select do |s|
      s['phase_class'] == 'WORK' && s['duration_ms'] >= limits[:work_warn_ms]
    end.map do |s|
      {
        'id' => s['id'],
        'pid' => s['pid'],
        'start_utc' => s['start_utc'],
        'end_utc' => s['end_utc'],
        'start_mono_ms' => s['start_mono_ms'],
        'end_mono_ms' => s['end_mono_ms'],
        'duration_ms' => s['duration_ms'],
        'severity' => s['severity'],
        'phase_group' => s['phase_group'],
        'model' => s['model'],
        'max_working_set_mib' => s['max_working_set_mib'],
        'children_union' => s['children_union']
      }
    end

    open_hungs = stall_segments.select { |s| s['phase_class'] == 'OPEN' && s['severity'] == 'hung' }
    idle_hungs = stall_segments.select { |s| s['phase_class'] == 'IDLE' && s['severity'] == 'hung' }
    startup_hungs = stall_segments.select { |s| s['phase_class'] == 'STARTUP' && s['severity'] == 'hung' }

    u_breaches = stall_segments.select do |s|
      s['phase_class'] == 'UNKNOWN' && s['severity'] == 'hung' && s['duration_ms'] > limits[:work_hung_limit_ms]
    end

    modal_breaches = modal_segments.select do |s|
      (s['phase_class'] == 'WORK' || s['phase_class'] == 'UNKNOWN') && s['duration_ms'] > limits[:modal_limit_ms]
    end
    disclosed_modals = modal_segments.reject do |s|
      s['phase_class'] == 'WORK' || s['phase_class'] == 'UNKNOWN'
    end

    lifecycle_phases_seen = lifecycle_order.map { |k| lifecycle_by_key[k] }
    capture_failures = capture_terminals.select { |c| c['complete'] == false }

    last_se = session_end_events.last
    observer_overhead = nil
    if last_se && last_se['mono_ms'].to_f > 0.0 && !last_se['watcher_cpu_ms'].nil?
      wall_ms = last_se['mono_ms'].to_f.round(1)
      cpu_ms = last_se['watcher_cpu_ms'].to_f.round(1)
      pct = ((cpu_ms / wall_ms) * 100.0).round(2)
      observer_overhead = { 'wall_ms' => wall_ms, 'watcher_cpu_ms' => cpu_ms, 'cpu_pct_core' => pct }
    end

    a_pass = a_breaches.empty?
    u_pass = u_breaches.empty?
    d_pass = bugsplat_children.empty? && work_exits.empty? && modal_breaches.empty? && capture_failures.empty?

    reasons = []
    reasons << "G-RT4'-A" unless a_pass
    reasons << "G-RT4'-U" unless u_pass
    reasons << "G-RT4'-D" unless d_pass
    reasons << 'CAPTURE_FAILED' unless capture_failures.empty?

    verdict = reasons.empty? ? 'PASS' : 'FAIL'
    exit_code = reasons.empty? ? 0 : 1

    summary = {
      'schema' => SUMMARY_SCHEMA,
      'verdict' => verdict,
      'exit_code' => exit_code,
      'reasons' => reasons,
      'gates' => {
        'A' => {
          'passed' => a_pass,
          'limit_ms' => limits[:work_hung_limit_ms],
          'breach_count' => a_breaches.length,
          'breaches' => a_breaches
        },
        'B' => b_segments,
        'C' => {
          'open_hung_count' => open_hungs.length,
          'max_open_hung_ms' => open_hungs.empty? ? 0.0 : open_hungs.map { |s| s['duration_ms'] }.max,
          'idle_hung_count' => idle_hungs.length,
          'max_idle_hung_ms' => idle_hungs.empty? ? 0.0 : idle_hungs.map { |s| s['duration_ms'] }.max,
          'startup_hung_count' => startup_hungs.length,
          'max_startup_hung_ms' => startup_hungs.empty? ? 0.0 : startup_hungs.map { |s| s['duration_ms'] }.max
        },
        'U' => {
          'passed' => u_pass,
          'limit_ms' => limits[:work_hung_limit_ms],
          'breach_count' => u_breaches.length,
          'breaches' => u_breaches
        },
        'D' => {
          'passed' => d_pass,
          'modal_limit_ms' => limits[:modal_limit_ms],
          'bugsplat_children' => bugsplat_children,
          'work_exits' => work_exits,
          'modal_breaches' => modal_breaches,
          'disclosed_modals' => disclosed_modals,
          'nonzero_exit_outside_work' => nonzero_exit_outside_work,
          'capture_failures' => capture_failures
        }
      },
      'processes_seen' => processes_seen,
      'ticks_by_class' => ticks_by_class,
      'no_window_samples' => no_window_samples,
      'lifecycle_phases_seen' => lifecycle_phases_seen,
      'capture_terminals' => capture_terminals,
      'capture_progress_stalls' => capture_progress_stalls,
      'observer_overhead' => observer_overhead,
      'truncated_tail_line' => truncated_tail_line,
      'session_end_missing' => session_end_missing,
      'events_sha256' => events_sha256,
      'limits' => {
        'work_hung_limit_ms' => limits[:work_hung_limit_ms],
        'work_warn_ms' => limits[:work_warn_ms],
        'modal_limit_ms' => limits[:modal_limit_ms]
      }
    }

    write_outputs(session_dir, summary, segments)
    summary
  end

  def run_cli(argv = ARGV)
    opts = parse_args(argv)
    summary = summarize(opts)
    exit(summary['exit_code'])
  end
end

SibamboWatchdogSummarizer.run_cli if $PROGRAM_NAME == __FILE__
