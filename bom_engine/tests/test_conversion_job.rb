# Run with standalone Ruby/JRuby. SketchUp UI is replaced by a deterministic stub.

MB_OK = 0 unless defined?(MB_OK)

module UI
  class HtmlDialog
    STYLE_DIALOG = 0

    class << self
      attr_reader :last
    end

    attr_reader :scripts, :centered, :options, :size, :center_calls

    def initialize(**options)
      @options = options
      self.class.instance_variable_set(:@last, self)
      @callbacks = {}
      @scripts = []
    end

    def set_file(_path); end
    def set_on_closed(&callback); @on_closed = callback; end
    def add_action_callback(name, &callback); @callbacks[name] = callback; end
    def execute_script(script); @scripts << script; end
    def close; @on_closed.call if @on_closed; end
    def center; @centered = true; @center_calls = (@center_calls || 0) + 1; end
    def set_size(width, height); @size = [width, height]; end
    def show; @callbacks['ready'].call(nil); end
    def invoke(name); @callbacks.fetch(name).call(nil); end
  end

  class << self
    attr_reader :opened_url
    attr_accessor :beep_count, :beep_error
    def beep
      self.beep_count = beep_count.to_i + 1
      raise 'sound unavailable' if beep_error
    end
    def start_timer(_interval, _repeat, &callback)
      @timer_callback = callback
      1
    end

    def stop_timer(_timer_id)
      @timer_callback = nil
    end

    def tick
      callback = @timer_callback
      callback.call if callback
    end

    def messagebox(*_args); end
    def openURL(url); @opened_url = url; end
  end
end

module BOMEngine
  module Logger
    def self.error(_message); end
  end
end

require_relative '../conversion_job'
require_relative '../performance_trace'
require_relative '../bomc_export_job'

# A nested timer during a Logger/native callback must not resume an executing
# Fiber. Old code raises FiberError and marks this otherwise successful job failed.
reentry_runs = 0
reentry_job = BOMEngine::ConversionJob.start(title: 'Nested UI timer', output_path: 'D:/SibamboExports/reentry.json') do |progress|
  reentry_runs += 1
  UI.tick
  progress.call(stage: :SCAN_MODEL, processed: 1, total: 1)
  UI.tick
  { path: 'D:/SibamboExports/reentry.json', bytes: 0, validation: {} }
end
UI.tick while reentry_job.running?
raise 'Nested tick resumed an executing Fiber or failed the job' unless reentry_job.state == :completed && reentry_runs == 1
raise 'Nested tick failed to release the active job' unless BOMEngine::ConversionJob.active.nil?
scripts = UI::HtmlDialog.last.scripts
raise 'Nested timer triggered failure during a successful export' if scripts.any? { |script| script.include?('failConversion(') }
raise 'Nested timer dispatched duplicate terminal events' unless scripts.count { |script| script.include?('completeConversion(') } == 1
raise 'Successful single export must sound once' unless UI.beep_count == 1
UI.beep_error = true
sound_error_job = BOMEngine::ConversionJob.start(title: 'Sound error', output_path: 'D:/SibamboExports/test') { { path: 'D:/SibamboExports/test', validation: {} } }
UI.tick while sound_error_job.running?
raise 'Sound error must not fail export' unless sound_error_job.state == :completed
UI.beep_error = false

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
  puts "PASS: #{message}"
end

job = BOMEngine::ConversionJob.start(title: 'Test conversion', output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/model.json') do |progress|
  3.times { |index| progress.call(stage: "Stage #{index}", processed: index + 1) }
  { path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/model.json', bytes: 42, validation: { nodes: 7, triangles: 11 } }
end
UI.tick while job.running?
scripts = UI::HtmlDialog.last.scripts
assert(scripts.any? { |script| script.include?('updateProgress') }, 'progress window receives cooperative updates')
assert(scripts.any? { |script| script.include?('completeConversion') }, 'progress window receives completion result')
assert(UI::HtmlDialog.last.centered, 'progress window is centered relative to SketchUp')
assert(UI::HtmlDialog.last.options[:height] >= 520, 'active progress window has room for five visible phases')
assert(UI::HtmlDialog.last.size == [620, 650] && UI::HtmlDialog.last.center_calls >= 2,
  'completion window expands and re-centers relative to SketchUp')
assert(BOMEngine::ConversionJob.active.nil?, 'completed job releases global active slot')
first_generation = job.generation_id
metrics = job.performance_metrics
assert(first_generation.is_a?(Integer) && first_generation.positive?, 'conversion metrics are bound to a concrete job generation')
assert(metrics[:generation_id] == first_generation && metrics[:slice_count].to_i >= 1,
  'cooperative slice metrics stay associated with their job generation')
assert(metrics[:max_slice_ms].is_a?(Numeric) && metrics[:max_tick_delay_ms].is_a?(Numeric),
  'conversion job records slice duration and UI timer delay')
assert(job.state_history.map { |row| row[:state] } == [:created, :capturing, :compiling, :validating, :publishing, :completed],
  'successful conversion follows the explicit generation-owned lifecycle')
assert(metrics[:event_sequence].to_i >= 2 && metrics[:coalesced_ui_event_count].to_i >= 1,
  'rapid checkpoint events are sequenced and coalesced before UI delivery')
event_scripts = scripts.select { |script| script.include?('updateProgress') || script.include?('completeConversion') }
event_sequences = event_scripts.map { |script| script[/"sequence":(\d+)/, 1].to_i }
assert(event_sequences == event_sequences.sort.uniq,
  'all delivered progress/result events use one strictly monotonic sequence')

require 'tmpdir'
Dir.mktmpdir('conversion-job-performance') do |dir|
  receipt_path = File.join(dir, 'artifact.bomc.performance.json')
  BOMEngine::PerformanceTrace.write_receipt(receipt_path, {
    schema: BOMEngine::PerformanceTrace::SCHEMA, enabled: true, status: 'success',
    total_wall_ms: 1.0, metadata: { engine: 'e4' }, counters: {}, stages: []
  })
  receipt_job = BOMEngine::ConversionJob.start(title: 'Observed conversion', output_path: File.join(dir, 'artifact.bomc')) do |progress|
    progress.call(stage: 'Observed', processed: 1, total: 1)
    { path: File.join(dir, 'artifact.bomc'), bytes: 1, validation: {}, performance_receipt_path: receipt_path }
  end
  UI.tick while receipt_job.running?
  parsed = JSON.parse(File.read(receipt_path, encoding: 'UTF-8'))
  scheduler = parsed.dig('metadata', 'conversion_job')
  assert(scheduler && scheduler['generation_id'] == receipt_job.generation_id,
    'interactive scheduler metrics are persisted into the separate performance receipt')
  assert(scheduler['max_slice_ms'].is_a?(Numeric) && scheduler['max_checkpoint_gap_ms'].is_a?(Numeric),
    'persisted receipt includes UI-thread slice and checkpoint observability')
end

Dir.mktmpdir('capture result') do |capture_dir|
  capture_job = BOMEngine::ConversionJob.start(title: 'Capture', output_path: capture_dir, batch_size: 8192, kind: :capture) do
    { path: capture_dir, status: 'captured_pending_certification', source_info: { bytes: 440_016 },
      profiles: { visual: { bytes: 155_683 }, research: { bytes: 165_554 }, exact: { bytes: 219_674 } } }
  end
  UI.tick while capture_job.running?
  script = UI::HtmlDialog.last.scripts.find { |item| item.include?('completeConversion') }
  assert(script.include?('"capture":true'), 'capture completion is explicitly marked uncertified')
  assert(script.include?('"visual":{"bytes":155683}'), 'capture completion reports per-profile sizes, not a fake combined BOMC')
  UI::HtmlDialog.last.invoke('openFolder')
  assert(UI.opened_url.end_with?(File.basename(capture_dir).gsub(' ', '%20')) && !UI.opened_url.include?(' '),
    "open folder targets the capture result directory with URL-safe spaces: #{UI.opened_url.inspect}")
end

Dir.mktmpdir('capture-failure') do |capture_dir|
  failed_job = BOMEngine::ConversionJob.start(title: 'Failed capture', output_path: capture_dir, kind: :capture) do
    raise 'research export failed'
  end
  UI.tick while failed_job.running?
  script = UI::HtmlDialog.last.scripts.find { |item| item.include?('failConversion') }
  assert(script.include?('"capture":true'), 'failed capture is distinguished from single-file export')
  assert(script.include?(File.basename(capture_dir)), 'failed capture points to its preserved diagnostics')
  assert(failed_job.state == :failed && failed_job.state_history.last[:state] == :failed,
    'failed work terminates the state machine without entering completed')
end

Dir.mktmpdir('all-profile-result') do |parent|
  result_dir = File.join(parent, 'house__ALL-1')
  Dir.mkdir(result_dir)
  all_job = BOMEngine::ConversionJob.start(title: 'Export All', output_path: File.join(parent, 'house'), kind: :batch_export) do
    { path: result_dir, status: 'complete', profiles: { visual: { bytes: 10 }, research: { bytes: 20 }, exact: { bytes: 30 } } }
  end
  UI.tick while all_job.running?
  script = UI::HtmlDialog.last.scripts.find { |item| item.include?('completeConversion') }.to_s
  assert(script.include?('"batch_export":true') && script.include?('"visual":{"bytes":10}'),
    'Export All completion reports its three files as a distinct result kind')
  UI::HtmlDialog.last.invoke('openFolder')
  assert(UI.opened_url.include?('house__ALL-1'), 'Export All opens the new three-profile folder')
end

over_budget_job = BOMEngine::ConversionJob.start(title: 'Texture-heavy conversion', output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/model.bomc') do
  {
    path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/model.bomc', bytes: 110, candidate_bytes: 110,
    source_info: { bytes: 100 }, savings_bytes: -10,
    status: :over_budget, strategy: :maximum_lossless,
    validation: { nodes: 7, triangles: 11 }
  }
end
UI.tick while over_budget_job.running?
over_budget_script = UI::HtmlDialog.last.scripts.find { |script| script.include?('completeConversion') }.to_s
assert(over_budget_script.include?('"gate_status":"over_budget"'), 'over-budget lossless export completes instead of entering the failure UI')
assert(over_budget_script.include?('"savings_bytes":-10'), 'completion UI receives the exact signed SKP size delta')

cancelled_job = BOMEngine::ConversionJob.start(title: 'Cancel conversion', output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/model.json') do |progress|
  3.times { |index| progress.call(stage: "Stage #{index}", processed: index + 1) }
end
cancelled_job.cancel
UI.tick while cancelled_job.running?
assert(UI::HtmlDialog.last.scripts.any? { |script| script.include?('cancelledConversion') }, 'cancel request stops at cooperative checkpoint')
assert(BOMEngine::ConversionJob.active.nil?, 'cancelled job releases global active slot')
assert(cancelled_job.generation_id > first_generation, 'later jobs use a new generation instead of reusing stale progress metrics')
assert(cancelled_job.performance_metrics[:generation_id] == cancelled_job.generation_id,
  'cancelled job metrics cannot be mistaken for an earlier generation')
assert(cancelled_job.state_history.map { |row| row[:state] } == [:created, :capturing, :cancelling, :cancelled],
  'cancel transitions cannot pass through success publication states')

close_job = BOMEngine::ConversionJob.start(title: 'Close conversion', output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/close.json') do |progress|
  progress.call(stage: 'Waiting', processed: 1, total: 2)
  progress.call(stage: 'Waiting', processed: 2, total: 2)
end
UI::HtmlDialog.last.invoke('close')
UI.tick while close_job.running?
assert(close_job.state == :cancelled && BOMEngine::ConversionJob.active.nil?,
  'closing an active dialog routes through cancellation and releases the generation')

slow_job = BOMEngine::ConversionJob.start(title: 'Chunkable slow stage', output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/slow.json') do |progress|
  5.times do |index|
    sleep 0.02
    progress.call(phase: :compiling, stage: 'Synthetic chunk', processed: index + 1, total: 5)
  end
  { path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/slow.json', bytes: 5, validation: {} }
end
UI.tick while slow_job.running?
slow_metrics = slow_job.performance_metrics
assert(slow_metrics[:max_slice_ms] < 100.0,
  'cooperatively chunkable slow work stays inside the 100 ms main-thread ceiling')
assert(slow_metrics[:checkpoint_count] == 5 && slow_metrics[:state_history].any? { |row| row[:state] == :compiling },
  'slow-stage checkpoints keep backend phase and heartbeat telemetry current')
assert(slow_metrics[:ui_update_count].to_i >= 2,
  'cooperatively chunkable slow work still delivers bounded progress updates')

texture_job = BOMEngine::ConversionJob.start(title: 'Texture progress', output_path: 'D:/exports/texture.bomc') do |progress|
  progress.call(stage: :SNAPSHOT_TEXTURES, processed: 142, total: 159, operation_label: 'mtl', unit: 'material')
  progress.call(stage: :SNAPSHOT_TEXTURES, processed: 39, total: 159, operation_label: 'mtl', unit: 'material')
  {path: 'D:/exports/texture.bomc', bytes: 1, validation: {}}
end
UI.tick while texture_job.running?
texture_payload = UI::HtmlDialog.last.scripts.select { |script| script.include?('updateProgress') }.last.to_s
assert(texture_payload.include?('"phase_id":"textures"') && texture_payload.include?('"operation_label":"mtl"') &&
  texture_payload.include?('"unit":"material"') && texture_payload.include?('"pass_index":2'),
  'backend emits named texture phase, material, real unit and pass identity')

publish_calls = 0
publish_cancel_job = BOMEngine::ConversionJob.start(title: 'Cancel before publication', output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/publish.bomc') do |progress|
  context = {
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
    on_yield: progress,
    cancelled: -> { false },
    source_info: ->(_model) { { path: 'model.skp', bytes: 100, available: true } },
    snapshot: ->(_model, _checkpoint) { { marker: 'detached' } },
    compile: ->(_graph, _source, output, _checkpoint) { { path: output, bytes: 'compiled'.b, candidate_bytes: 8, savings_bytes: 92, status: :pass, strategy: :standard, metrics: {} } },
    validate: ->(_result, _graph) { { passed: true, report: { passed: true } } },
    publish: ->(_candidate, _validation, path) { publish_calls += 1; { path: path } },
    cleanup: -> {}
  }
  BOMEngine::BOMCExportJob.run(
    model: Struct.new(:path).new('model.skp'), output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/publish.bomc',
    settings: BOMEngine::BOMCProcessing.settings(:balanced), context: context
  )
end
while publish_cancel_job.running?
  UI.tick
  publish_cancel_job.cancel if publish_cancel_job.running? && publish_cancel_job.state == :publishing
end
assert(publish_calls == 0 && publish_cancel_job.state == :cancelled,
  'cancelling at the publication boundary prevents stale or partial publication')

# Deterministic clock: 25 resumes with one 500ms slice, plus completion.
fake_now = 0.0
telemetry_job = BOMEngine::ConversionJob.new(title: 'Slice attribution', output_path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/attribution.bomc') do |progress|
  25.times do |i|
    fake_now += (i == 7 ? 0.5 : 0.01)
    progress.call(stage: :snapshot_entities, operation_label: "scene_#{i}", processed: i)
  end
  {path: 'D:/projects/sibambo/scratch/sib-f1-readiness-20261024/conversion-job/attribution.bomc', bytes: 1, validation: {}}
end
telemetry_job.define_singleton_method(:monotonic_seconds) { fake_now }
telemetry_job.start
UI.tick while telemetry_job.running?
rows = telemetry_job.performance_metrics[:longest_slices]
assert(rows.length == 20, 'only twenty longest resumes are retained')
assert(rows == rows.sort_by { |r| [-r[:duration_ms], r[:started_ms]] }, 'longest slices use duration then earliest-start ordering')
assert(rows[0] == {started_ms: 70.0, finished_ms: 570.0, duration_ms: 500.0, entry_stage: 'snapshot_entities', entry_operation_label: 'scene_6', exit_stage: 'snapshot_entities', exit_operation_label: 'scene_7'}, 'known 500ms slice has exact entry exit checkpoint context')
assert(telemetry_job.performance_metrics[:max_slice_ms] == 500.0 && telemetry_job.performance_metrics[:slice_count] == 26, 'bounded slice attribution preserves original maxima and total count')
puts 'Conversion Job Tests: ALL PASSED'
