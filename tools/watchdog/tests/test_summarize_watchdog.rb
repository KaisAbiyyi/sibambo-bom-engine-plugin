# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'securerandom'
require 'time'

class TestSummarizeWatchdog < Minitest::Test
  RUBY_EXE = 'C:/Ruby25-x64/bin/ruby.exe'
  SUMMARIZER = File.expand_path('../summarize_watchdog.rb', __dir__)
  TMP_ROOT = 'D:/projects/sibambo/scratch/watchdog/tmp'
  D36_FORBIDDEN = /\b(?:responsive|smooth|non-blocking|faster)|responsive|smooth|non-blocking|faster/i.freeze

  def setup
    FileUtils.mkdir_p(TMP_ROOT)
    @created_dirs = []
  end

  def teardown
    @created_dirs.each { |d| FileUtils.rm_rf(d) }
  end

  def make_session_dir(tag)
    dir = File.join(TMP_ROOT, "sum-test-#{tag}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(dir)
    @created_dirs << dir
    dir
  end

  def utc_for(mono_ms)
    base = Time.utc(2026, 11, 24, 0, 0, 0) + (mono_ms / 1000.0)
    base.utc.strftime('%Y-%m-%dT%H:%M:%S.') + format('%03dZ', (mono_ms % 1000).to_i)
  end

  def session_start_line
    {
      'type' => 'session_start',
      'utc' => utc_for(0.0),
      'mono_ms' => 0.0,
      'schema' => 'sibambo-skp-watchdog-v1',
      'ps_version' => '5.1.26100.9818',
      'poll_interval_ms' => 250,
      'probe_timeout_ms' => 500,
      'heartbeat_seconds' => 5,
      'target' => { 'process_name' => 'SketchUp', 'pid' => 0 },
      'watch' => { 'beacon_file' => '', 'model_truth_root' => '', 'batch_root' => '' },
      'out_dir' => 'D:/projects/sibambo/scratch/watchdog/tmp'
    }
  end

  def process_started_line(pid: 1001, mono_ms: 10.0)
    {
      'type' => 'process_started',
      'utc' => utc_for(mono_ms),
      'mono_ms' => mono_ms.round(1),
      'pid' => pid,
      'creation_utc' => utc_for(0.0),
      'image_path' => 'C:/Program Files/SketchUp/SketchUp.exe'
    }
  end

  def tick_line(mono_ms:, pid: 1001, phase_group: 'skp_capture', phase_source: 'beacon',
                model: 'house2', stall: false, is_hung: false, ghost: false, title_nr: false,
                modal: [], children: [], probe_latency_ms: 1.5, working_set_mib: 512.0, main_hwnd: '0x1000')
    {
      'type' => 'tick',
      'utc' => utc_for(mono_ms),
      'mono_ms' => mono_ms.to_f.round(1),
      'pid' => pid,
      'main_hwnd' => main_hwnd,
      'probe_ok' => !stall,
      'probe_latency_ms' => probe_latency_ms,
      'probe_win32_error' => stall ? 1460 : nil,
      'is_hung' => is_hung,
      'ghost' => ghost,
      'title' => title_nr ? 'house2.skp - SketchUp (Not Responding)' : 'house2.skp - SketchUp',
      'title_nr' => title_nr,
      'modal' => modal,
      'stall' => stall,
      'phase_group' => phase_group,
      'phase_source' => phase_source,
      'model' => model,
      'working_set_mib' => working_set_mib,
      'private_mib' => 600.0,
      'cpu_user_ms' => 1000,
      'cpu_kernel_ms' => 200,
      'handles' => 500,
      'gdi' => 100,
      'user' => 80,
      'children' => children
    }
  end

  def process_exited_line(mono_ms:, pid: 1001, exit_code: 0, exit_code_readable: true)
    {
      'type' => 'process_exited',
      'utc' => utc_for(mono_ms),
      'mono_ms' => mono_ms.to_f.round(1),
      'pid' => pid,
      'exit_code' => exit_code,
      'exit_code_readable' => exit_code_readable
    }
  end

  def session_end_line(mono_ms:, reason: 'target_exited', ticks_total: 10, ticks_written: 10)
    {
      'type' => 'session_end',
      'utc' => utc_for(mono_ms),
      'mono_ms' => mono_ms.to_f.round(1),
      'reason' => reason,
      'ticks_total' => ticks_total,
      'ticks_written' => ticks_written,
      'watcher_cpu_ms' => 15
    }
  end

  def write_ndjson(dir, lines)
    text = lines.map { |l| l.is_a?(String) ? l : JSON.generate(l) }.join("\n") + "\n"
    File.binwrite(File.join(dir, 'events.ndjson'), text)
  end

  def run_summarizer(dir, extra_args = [])
    env = { 'TEMP' => TMP_ROOT, 'TMP' => TMP_ROOT }
    stdout, stderr, status = Open3.capture3(env, RUBY_EXE, SUMMARIZER, '--session', dir, *extra_args)
    summary_path = File.join(dir, 'watchdog-summary.json')
    episodes_path = File.join(dir, 'episodes.json')
    md_path = File.join(dir, 'watchdog-summary.md')
    summary = File.file?(summary_path) ? JSON.parse(File.binread(summary_path)) : nil
    episodes = File.file?(episodes_path) ? JSON.parse(File.binread(episodes_path)) : nil
    md = File.file?(md_path) ? File.binread(md_path) : nil
    { exit_code: status.exitstatus, stdout: stdout, stderr: stderr, summary: summary, episodes: episodes, md: md }
  end

  def add_ticks(lines, start_ms:, count:, step_ms: 250, **kwargs)
    count.times do |i|
      lines << tick_line(mono_ms: start_ms + i * step_ms, **kwargs)
    end
  end

  def assert_no_d36_words(res)
    [res[:summary] ? JSON.generate(res[:summary]) : nil,
     res[:episodes] ? JSON.generate(res[:episodes]) : nil,
     res[:md]].compact.each do |blob|
      refute_match D36_FORBIDDEN, blob, 'Output violated D36 forbidden wording'
    end
  end

  # T1: 60 s healthy skp_capture -> exit 0, 0 episodes
  def test_t01_healthy_capture
    dir = make_session_dir('t01')
    lines = [session_start_line, process_started_line]
    add_ticks(lines, start_ms: 250, count: 240, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 60_250)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 'PASS', res[:summary]['verdict']
    assert_equal 0, res[:episodes].length
    assert_no_d36_words(res)
  end

  # T2: 3,500 ms skp_capture stall (no OS flag) -> exit 0; listed in gates.B
  def test_t02_work_stall_warn
    dir = make_session_dir('t02')
    lines = [session_start_line, process_started_line]
    add_ticks(lines, start_ms: 1000, count: 14, phase_group: 'skp_capture', stall: true, is_hung: false)
    add_ticks(lines, start_ms: 4500, count: 2, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 5000)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 1, res[:summary]['gates']['B'].length
    assert_equal 3500.0, res[:summary]['gates']['B'][0]['duration_ms']
    assert_equal 'stall', res[:summary]['gates']['B'][0]['severity']
    assert_no_d36_words(res)
  end

  # T3: 8,500 ms skp_capture hung -> exit 0; in gates.B; severity hung
  def test_t03_work_hung_under_limit
    dir = make_session_dir('t03')
    lines = [session_start_line, process_started_line]
    add_ticks(lines, start_ms: 1000, count: 34, phase_group: 'skp_capture', stall: true, is_hung: true)
    add_ticks(lines, start_ms: 9500, count: 2, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 10_000)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 1, res[:summary]['gates']['B'].length
    assert_equal 'hung', res[:summary]['gates']['B'][0]['severity']
    assert_equal 8500.0, res[:summary]['gates']['B'][0]['duration_ms']
    assert_no_d36_words(res)
  end

  # T4: 11,200 ms skp_capture hung -> exit 1; reason G-RT4'-A
  def test_t04_work_hung_breach
    dir = make_session_dir('t04')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 1000, phase_group: 'skp_capture', stall: true, is_hung: true)
    lines << tick_line(mono_ms: 12_200, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 12_450, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 12_500)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 1, res[:exit_code]
    assert_equal 'FAIL', res[:summary]['verdict']
    assert_includes res[:summary]['reasons'], "G-RT4'-A"
    assert_no_d36_words(res)
  end

  # T5: 10,500 ms batch_export hung, children ["cwebp.exe"] -> exit 1; children_union has cwebp.exe
  def test_t05_batch_export_hung_with_child
    dir = make_session_dir('t05')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 1000, phase_group: 'batch_export', phase_source: 'batch', stall: true, is_hung: true, children: ['cwebp.exe'])
    lines << tick_line(mono_ms: 11_500, phase_group: 'batch_export', phase_source: 'batch', stall: false, children: [])
    lines << tick_line(mono_ms: 11_750, phase_group: 'batch_export', phase_source: 'batch', stall: false, children: [])
    lines << session_end_line(mono_ms: 12_000)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 1, res[:exit_code]
    assert_includes res[:summary]['reasons'], "G-RT4'-A"
    assert_includes res[:episodes][0]['children_union'], 'cwebp.exe'
    assert_no_d36_words(res)
  end

  # T6: 25,000 ms open_file hung, then healthy skp_capture -> exit 0; open_hung_count 1, max_open_hung_ms 25000.0
  def test_t06_open_hung_disclosed
    dir = make_session_dir('t06')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 1000, phase_group: 'open_file', stall: true, is_hung: true)
    lines << tick_line(mono_ms: 26_000, phase_group: 'open_file', stall: false)
    lines << tick_line(mono_ms: 26_250, phase_group: 'open_file', stall: false)
    lines << tick_line(mono_ms: 26_500, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 27_000)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 1, res[:summary]['gates']['C']['open_hung_count']
    assert_equal 25_000.0, res[:summary]['gates']['C']['max_open_hung_ms']
    assert_no_d36_words(res)
  end

  # T7: stall, 1 healthy tick, stall -> one episode
  def test_t07_single_healthy_tick_merges
    dir = make_session_dir('t07')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 1000, phase_group: 'skp_capture', stall: true)
    lines << tick_line(mono_ms: 1250, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 1500, phase_group: 'skp_capture', stall: true)
    lines << tick_line(mono_ms: 1750, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 2000, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 2250)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 1, res[:episodes].length
    assert_equal 750.0, res[:episodes][0]['duration_ms']
    assert_no_d36_words(res)
  end

  # T8: stall, 2 healthy ticks, stall -> two episodes; first ends at first healthy tick
  def test_t08_two_healthy_ticks_split
    dir = make_session_dir('t08')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 1000, phase_group: 'skp_capture', stall: true)
    lines << tick_line(mono_ms: 1250, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 1500, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 1750, phase_group: 'skp_capture', stall: true)
    lines << tick_line(mono_ms: 2000, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 2250, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 2500)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 2, res[:episodes].length
    assert_equal 1250.0, res[:episodes][0]['end_mono_ms']
    assert_equal 1750.0, res[:episodes][1]['start_mono_ms']
    assert_no_d36_words(res)
  end

  # T9: 1,000 ms stall with ghost true -> severity hung
  def test_t09_ghost_sets_hung
    dir = make_session_dir('t09')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 1000, phase_group: 'skp_capture', stall: true, ghost: true)
    lines << tick_line(mono_ms: 2000, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 2250, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 2500)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 'hung', res[:episodes][0]['severity']
    assert_equal true, res[:episodes][0]['ghost_seen']
    assert_no_d36_words(res)
  end

  # T10: #32770 35,000 ms in skp_capture -> exit 1 (G-RT4'-D); same in open_file -> exit 0 disclosed
  def test_t10_modal_work_vs_open
    dir1 = make_session_dir('t10a')
    modal = [{ 'class' => '#32770', 'title' => 'Confirm' }]
    lines1 = [session_start_line, process_started_line]
    lines1 << tick_line(mono_ms: 1000, phase_group: 'skp_capture', modal: modal)
    lines1 << tick_line(mono_ms: 36_000, phase_group: 'skp_capture', modal: [])
    lines1 << tick_line(mono_ms: 36_250, phase_group: 'skp_capture', modal: [])
    lines1 << session_end_line(mono_ms: 36_500)
    write_ndjson(dir1, lines1)

    res1 = run_summarizer(dir1)
    assert_equal 1, res1[:exit_code]
    assert_includes res1[:summary]['reasons'], "G-RT4'-D"
    assert_no_d36_words(res1)

    dir2 = make_session_dir('t10b')
    lines2 = [session_start_line, process_started_line]
    lines2 << tick_line(mono_ms: 1000, phase_group: 'open_file', modal: modal)
    lines2 << tick_line(mono_ms: 36_000, phase_group: 'open_file', modal: [])
    lines2 << tick_line(mono_ms: 36_250, phase_group: 'open_file', modal: [])
    lines2 << tick_line(mono_ms: 36_500, phase_group: 'skp_capture', modal: [])
    lines2 << session_end_line(mono_ms: 37_000)
    write_ndjson(dir2, lines2)

    res2 = run_summarizer(dir2)
    assert_equal 0, res2[:exit_code]
    assert_equal 1, res2[:summary]['gates']['D']['disclosed_modals'].length
    assert_no_d36_words(res2)
  end

  # T11: BsSndRpt.exe child; exit (code 0) during skp_capture; exit code 1 during idle
  def test_t11_bugsplat_and_exits
    dir1 = make_session_dir('t11a')
    lines1 = [session_start_line, process_started_line]
    lines1 << tick_line(mono_ms: 1000, phase_group: 'skp_capture', children: ['BsSndRpt.exe'])
    lines1 << session_end_line(mono_ms: 1500)
    write_ndjson(dir1, lines1)
    res1 = run_summarizer(dir1)
    assert_equal 1, res1[:exit_code]
    assert_includes res1[:summary]['reasons'], "G-RT4'-D"
    assert_no_d36_words(res1)

    dir2 = make_session_dir('t11b')
    lines2 = [session_start_line, process_started_line]
    lines2 << tick_line(mono_ms: 1000, phase_group: 'skp_capture')
    lines2 << process_exited_line(mono_ms: 1250, exit_code: 0)
    lines2 << session_end_line(mono_ms: 1500)
    write_ndjson(dir2, lines2)
    res2 = run_summarizer(dir2)
    assert_equal 1, res2[:exit_code]
    assert_includes res2[:summary]['reasons'], "G-RT4'-D"
    assert_no_d36_words(res2)

    dir3 = make_session_dir('t11c')
    lines3 = [session_start_line, process_started_line]
    lines3 << tick_line(mono_ms: 1000, phase_group: 'skp_capture')
    lines3 << tick_line(mono_ms: 1250, phase_group: 'idle')
    lines3 << process_exited_line(mono_ms: 1500, exit_code: 1)
    lines3 << session_end_line(mono_ms: 1750)
    write_ndjson(dir3, lines3)
    res3 = run_summarizer(dir3)
    assert_equal 0, res3[:exit_code]
    assert_equal 1, res3[:summary]['gates']['D']['nonzero_exit_outside_work'].length
    assert_no_d36_words(res3)
  end

  # T12: no process_started -> exit 2 NO_TARGET_SEEN
  def test_t12_no_target_seen
    dir = make_session_dir('t12')
    write_ndjson(dir, [session_start_line, session_end_line(mono_ms: 1000)])
    res = run_summarizer(dir)
    assert_equal 2, res[:exit_code]
    assert_equal 'ERROR', res[:summary]['verdict']
    assert_includes res[:summary]['reasons'], 'NO_TARGET_SEEN'
    assert_no_d36_words(res)
  end

  # T13: no session_start; corrupt middle line; corrupt last line only
  def test_t13_ndjson_integrity
    dir1 = make_session_dir('t13a')
    write_ndjson(dir1, [process_started_line, tick_line(mono_ms: 500)])
    res1 = run_summarizer(dir1)
    assert_equal 2, res1[:exit_code]
    assert_no_d36_words(res1)

    dir2 = make_session_dir('t13b')
    write_ndjson(dir2, [session_start_line, process_started_line, '{corrupt', tick_line(mono_ms: 500), session_end_line(mono_ms: 750)])
    res2 = run_summarizer(dir2)
    assert_equal 2, res2[:exit_code]
    assert_no_d36_words(res2)

    dir3 = make_session_dir('t13c')
    write_ndjson(dir3, [session_start_line, process_started_line, tick_line(mono_ms: 500), session_end_line(mono_ms: 750), '{"type":"ti'])
    res3 = run_summarizer(dir3)
    assert_equal 0, res3[:exit_code]
    assert_equal true, res3[:summary]['truncated_tail_line']
    assert_no_d36_words(res3)
  end

  # T14: outputs of T1-T13 (and title_nr) contain no D36 forbidden words
  def test_t14_d36_wording_on_summary_and_md
    dir = make_session_dir('t14')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 1000, phase_group: 'skp_capture', stall: true, is_hung: true, title_nr: true)
    lines << tick_line(mono_ms: 13_000, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 13_250, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 13_500)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 1, res[:exit_code]
    assert_no_d36_words(res)
    assert_includes res[:md], '(Not Responding)'

    # Also verify a representative ERROR output (missing events.ndjson) has no D36 words
    err_dir = make_session_dir('t14-err')
    err_res = run_summarizer(err_dir)
    assert_equal 2, err_res[:exit_code]
    assert_no_d36_words(err_res)
  end

  # T15: one episode: 9,000 ms open_file then 11,000 ms skp_capture; and 24,000 + 1,000
  def test_t15_phase_split_episodes
    dir1 = make_session_dir('t15a')
    lines1 = [session_start_line, process_started_line]
    lines1 << tick_line(mono_ms: 1000, phase_group: 'open_file', stall: true, is_hung: true)
    lines1 << tick_line(mono_ms: 10_000, phase_group: 'skp_capture', stall: true, is_hung: true)
    lines1 << tick_line(mono_ms: 21_000, phase_group: 'skp_capture', stall: false)
    lines1 << tick_line(mono_ms: 21_250, phase_group: 'skp_capture', stall: false)
    lines1 << session_end_line(mono_ms: 21_500)
    write_ndjson(dir1, lines1)

    res1 = run_summarizer(dir1)
    assert_equal 1, res1[:exit_code]
    assert_equal 2, res1[:episodes].length
    assert_equal 9000.0, res1[:episodes][0]['duration_ms']
    assert_equal 11_000.0, res1[:episodes][1]['duration_ms']
    assert_no_d36_words(res1)

    dir2 = make_session_dir('t15b')
    lines2 = [session_start_line, process_started_line]
    lines2 << tick_line(mono_ms: 1000, phase_group: 'open_file', stall: true, is_hung: true)
    lines2 << tick_line(mono_ms: 25_000, phase_group: 'skp_capture', stall: true, is_hung: true)
    lines2 << tick_line(mono_ms: 26_000, phase_group: 'skp_capture', stall: false)
    lines2 << tick_line(mono_ms: 26_250, phase_group: 'skp_capture', stall: false)
    lines2 << session_end_line(mono_ms: 26_500)
    write_ndjson(dir2, lines2)

    res2 = run_summarizer(dir2)
    assert_equal 0, res2[:exit_code]
    assert_equal 24_000.0, res2[:episodes][0]['duration_ms']
    assert_equal 1000.0, res2[:episodes][1]['duration_ms']
    assert_no_d36_words(res2)
  end

  # T16: 12,000 ms unattributed hung after skp_capture -> exit 1 G-RT4'-U;
  #      20,000 ms startup hung then healthy work -> exit 0;
  #      only startup/idle ticks -> exit 2 NO_WORK_OBSERVED
  def test_t16_unknown_startup_and_no_work
    dir1 = make_session_dir('t16a')
    lines1 = [session_start_line, process_started_line]
    lines1 << tick_line(mono_ms: 500, phase_group: 'skp_capture', stall: false)
    lines1 << tick_line(mono_ms: 1000, phase_group: 'unattributed', phase_source: 'none', stall: true, is_hung: true)
    lines1 << tick_line(mono_ms: 13_000, phase_group: 'unattributed', phase_source: 'none', stall: false)
    lines1 << tick_line(mono_ms: 13_250, phase_group: 'unattributed', phase_source: 'none', stall: false)
    lines1 << session_end_line(mono_ms: 13_500)
    write_ndjson(dir1, lines1)
    res1 = run_summarizer(dir1)
    assert_equal 1, res1[:exit_code]
    assert_includes res1[:summary]['reasons'], "G-RT4'-U"
    assert_no_d36_words(res1)

    dir2 = make_session_dir('t16b')
    lines2 = [session_start_line, process_started_line]
    lines2 << tick_line(mono_ms: 1000, phase_group: 'startup', phase_source: 'startup', stall: true, is_hung: true)
    lines2 << tick_line(mono_ms: 21_000, phase_group: 'startup', phase_source: 'startup', stall: false)
    lines2 << tick_line(mono_ms: 21_250, phase_group: 'startup', phase_source: 'startup', stall: false)
    lines2 << tick_line(mono_ms: 21_500, phase_group: 'skp_capture', stall: false)
    lines2 << session_end_line(mono_ms: 22_000)
    write_ndjson(dir2, lines2)
    res2 = run_summarizer(dir2)
    assert_equal 0, res2[:exit_code]
    assert_equal 1, res2[:summary]['gates']['C']['startup_hung_count']
    assert_equal 20_000.0, res2[:summary]['gates']['C']['max_startup_hung_ms']
    assert_no_d36_words(res2)

    dir3 = make_session_dir('t16c')
    lines3 = [session_start_line, process_started_line]
    lines3 << tick_line(mono_ms: 1000, phase_group: 'startup', phase_source: 'startup', stall: false)
    lines3 << tick_line(mono_ms: 1250, phase_group: 'idle', phase_source: 'beacon', stall: false)
    lines3 << session_end_line(mono_ms: 1500)
    write_ndjson(dir3, lines3)
    res3 = run_summarizer(dir3)
    assert_equal 2, res3[:exit_code]
    assert_includes res3[:summary]['reasons'], 'NO_WORK_OBSERVED'
    assert_no_d36_words(res3)
  end

  # T17: no session_end, last ticks are stall -> episode closed_by "eof", session_end_missing true;
  #      same input twice -> byte-identical outputs
  def test_t17_eof_close_and_determinism
    dir = make_session_dir('t17')
    lines = [session_start_line, process_started_line]
    lines << tick_line(mono_ms: 500, phase_group: 'skp_capture', stall: false)
    lines << tick_line(mono_ms: 1000, phase_group: 'skp_capture', stall: true, is_hung: true)
    lines << tick_line(mono_ms: 1500, phase_group: 'skp_capture', stall: true, is_hung: true)
    write_ndjson(dir, lines)

    res1 = run_summarizer(dir)
    assert_equal 0, res1[:exit_code]
    assert_equal true, res1[:summary]['session_end_missing']
    assert_equal 1, res1[:episodes].length
    assert_equal 'eof', res1[:episodes][0]['closed_by']
    assert_equal 500.0, res1[:episodes][0]['duration_ms']

    ep_bytes_1 = File.binread(File.join(dir, 'episodes.json'))
    sum_bytes_1 = File.binread(File.join(dir, 'watchdog-summary.json'))

    res2 = run_summarizer(dir)
    assert_equal 0, res2[:exit_code]
    ep_bytes_2 = File.binread(File.join(dir, 'episodes.json'))
    sum_bytes_2 = File.binread(File.join(dir, 'watchdog-summary.json'))

    assert_equal ep_bytes_1, ep_bytes_2
    assert_equal sum_bytes_1, sum_bytes_2
    assert_no_d36_words(res2)
  end

  # R1 (P1 regression): session_end.reason == "error" -> ERROR (exit 2), deterministic JSON
  def test_r1_watchdog_session_end_error_is_error
    dir = make_session_dir('r1-err')
    lines = [session_start_line, process_started_line]
    add_ticks(lines, start_ms: 250, count: 8, phase_group: 'skp_capture', stall: false)
    lines << session_end_line(mono_ms: 2500, reason: 'error')
    write_ndjson(dir, lines)

    res1 = run_summarizer(dir)
    assert_equal 2, res1[:exit_code]
    assert_equal 'ERROR', res1[:summary]['verdict']
    assert_includes res1[:summary]['reasons'], 'WATCHDOG_SESSION_ERROR'
    assert_no_d36_words(res1)

    sum_bytes_1 = File.binread(File.join(dir, 'watchdog-summary.json'))
    res2 = run_summarizer(dir)
    assert_equal 2, res2[:exit_code]
    sum_bytes_2 = File.binread(File.join(dir, 'watchdog-summary.json'))
    assert_equal sum_bytes_1, sum_bytes_2
  end

  # R2 (P2 regression): null resource metrics stay nil (never coerced to 0.0)
  def test_r2_null_resource_metrics_handled
    dir = make_session_dir('r2-null-metrics')
    lines = [session_start_line, process_started_line]
    t1 = tick_line(mono_ms: 1000, phase_group: 'skp_capture', stall: true, is_hung: false)
    %w[working_set_mib private_mib cpu_user_ms cpu_kernel_ms handles gdi user].each { |k| t1[k] = nil }
    lines << t1
    t2 = tick_line(mono_ms: 5000, phase_group: 'skp_capture', stall: false)
    %w[working_set_mib private_mib cpu_user_ms cpu_kernel_ms handles gdi user].each { |k| t2[k] = nil }
    lines << t2
    t3 = tick_line(mono_ms: 5250, phase_group: 'skp_capture', stall: false)
    %w[working_set_mib private_mib cpu_user_ms cpu_kernel_ms handles gdi user].each { |k| t3[k] = nil }
    lines << t3
    lines << session_end_line(mono_ms: 5500)
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 1, res[:episodes].length
    assert_nil res[:episodes][0]['max_working_set_mib']
    assert_equal 1, res[:summary]['gates']['B'].length
    assert_nil res[:summary]['gates']['B'][0]['max_working_set_mib']
    assert_includes res[:md], '| - |'
    assert_no_d36_words(res)
  end

  # T18: sub-poll beacon_lifecycle open_file + skp_capture ticks + capture_terminal(complete:true) + idle exit 0 -> PASS
  def test_t18_beacon_lifecycle_and_capture_terminal_pass
    dir = make_session_dir('t18')
    lines = [
      session_start_line,
      process_started_line,
      {
        'type' => 'beacon_lifecycle', 'utc' => utc_for(50), 'mono_ms' => 50.0, 'pid' => 1001,
        'seq' => 1, 'phase_group' => 'open_file', 'status' => 'started', 'model' => 'house2',
        'started_utc' => utc_for(45), 'ended_utc' => nil, 'duration_ms' => nil
      },
      {
        'type' => 'beacon_lifecycle', 'utc' => utc_for(120), 'mono_ms' => 120.0, 'pid' => 1001,
        'seq' => 1, 'phase_group' => 'open_file', 'status' => 'completed', 'model' => 'house2',
        'started_utc' => utc_for(45), 'ended_utc' => utc_for(109), 'duration_ms' => 64.0
      },
      tick_line(mono_ms: 250, phase_group: 'skp_capture', stall: false),
      {
        'type' => 'capture_terminal', 'utc' => utc_for(4000), 'mono_ms' => 4000.0, 'pid' => 1001,
        'run_dir' => 'D:/tmp/run', 'complete' => true, 'manifest_path' => 'D:/tmp/run/skp/manifest.json', 'error' => nil
      },
      tick_line(mono_ms: 4250, phase_group: 'idle', stall: false),
      process_exited_line(mono_ms: 4500, exit_code: 0),
      session_end_line(mono_ms: 5000)
    ]
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 'PASS', res[:summary]['verdict']
    assert_equal 1, res[:summary]['lifecycle_phases_seen'].length
    assert_equal 'completed', res[:summary]['lifecycle_phases_seen'][0]['status']
    assert_equal 64.0, res[:summary]['lifecycle_phases_seen'][0]['duration_ms']
    assert_empty res[:summary]['gates']['D']['work_exits']
    assert_no_d36_words(res)
  end

  # T19: beacon_lifecycle open_file alone with zero WORK ticks -> exit 2 NO_WORK_OBSERVED
  def test_t19_lifecycle_alone_does_not_bypass_no_work_observed
    dir = make_session_dir('t19')
    lines = [
      session_start_line,
      process_started_line,
      {
        'type' => 'beacon_lifecycle', 'utc' => utc_for(120), 'mono_ms' => 120.0, 'pid' => 1001,
        'seq' => 1, 'phase_group' => 'open_file', 'status' => 'completed', 'model' => 'house2',
        'started_utc' => utc_for(45), 'ended_utc' => utc_for(109), 'duration_ms' => 64.0
      },
      tick_line(mono_ms: 250, phase_group: 'idle', stall: false),
      session_end_line(mono_ms: 500)
    ]
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 2, res[:exit_code]
    assert_includes res[:summary]['reasons'], 'NO_WORK_OBSERVED'
    assert_no_d36_words(res)
  end

  # T20 (FI-5 / OD-2 Option A): capture_terminal(complete:false) fails G-RT4'-D with CAPTURE_FAILED
  def test_t20_capture_terminal_false_fails_gate_d
    dir = make_session_dir('t20')
    lines = [
      session_start_line,
      process_started_line,
      tick_line(mono_ms: 250, phase_group: 'skp_capture', stall: false),
      {
        'type' => 'capture_terminal', 'utc' => utc_for(1000), 'mono_ms' => 1000.0, 'pid' => 1001,
        'run_dir' => 'D:/tmp/run', 'complete' => false, 'manifest_path' => 'D:/tmp/run/skp/manifest.json',
        'error' => 'ModelTruthError: failed'
      },
      tick_line(mono_ms: 1250, phase_group: 'idle', stall: false),
      process_exited_line(mono_ms: 1500, exit_code: 0),
      session_end_line(mono_ms: 1600)
    ]
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 1, res[:exit_code]
    assert_includes res[:summary]['reasons'], "G-RT4'-D"
    assert_includes res[:summary]['reasons'], 'CAPTURE_FAILED'
    assert_equal 1, res[:summary]['gates']['D']['capture_failures'].length
    assert_no_d36_words(res)
  end

  # T21: capture_progress_stalled disclosed in summary JSON and Markdown
  def test_t21_capture_progress_stalled_disclosed
    dir = make_session_dir('t21')
    lines = [
      session_start_line,
      process_started_line,
      tick_line(mono_ms: 250, phase_group: 'skp_capture', stall: false),
      {
        'type' => 'capture_progress_stalled', 'utc' => utc_for(125_000), 'mono_ms' => 125_000.0, 'pid' => 1001,
        'run_dir' => 'D:/tmp/run', 'stale_seconds' => 120.5, 'last_progress_utc' => utc_for(4500)
      },
      session_end_line(mono_ms: 126_000)
    ]
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    assert_equal 1, res[:summary]['capture_progress_stalls'].length
    assert_includes res[:md], 'Capture Progress Stalls'
    assert_no_d36_words(res)
  end

  # T22: observer_overhead calculated deterministically from session_end
  def test_t22_observer_overhead_deterministic
    dir = make_session_dir('t22')
    lines = [
      session_start_line,
      process_started_line,
      tick_line(mono_ms: 250, phase_group: 'skp_capture', stall: false),
      {
        'type' => 'session_end', 'utc' => utc_for(10_000), 'mono_ms' => 10_000.0,
        'reason' => 'target_exited', 'ticks_total' => 40, 'ticks_written' => 1, 'watcher_cpu_ms' => 150
      }
    ]
    write_ndjson(dir, lines)

    res = run_summarizer(dir)
    assert_equal 0, res[:exit_code]
    ov = res[:summary]['observer_overhead']
    assert_equal 10_000.0, ov['wall_ms']
    assert_equal 150.0, ov['watcher_cpu_ms']
    assert_equal 1.5, ov['cpu_pct_core']
    assert_includes res[:md], 'Observer Overhead'
    assert_no_d36_words(res)
  end
end
