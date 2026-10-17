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

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
  puts "PASS: #{message}"
end

job = BOMEngine::ConversionJob.start(title: 'Test conversion', output_path: 'C:/tmp/model.json') do |progress|
  3.times { |index| progress.call(stage: "Stage #{index}", processed: index + 1) }
  { path: 'C:/tmp/model.json', bytes: 42, validation: { nodes: 7, triangles: 11 } }
end
UI.tick while job.running?
scripts = UI::HtmlDialog.last.scripts
assert(scripts.any? { |script| script.include?('updateProgress') }, 'progress window receives cooperative updates')
assert(scripts.any? { |script| script.include?('completeConversion') }, 'progress window receives completion result')
assert(UI::HtmlDialog.last.centered, 'progress window is centered relative to SketchUp')
assert(UI::HtmlDialog.last.options[:height] <= 420, 'active progress window remains compact')
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

over_budget_job = BOMEngine::ConversionJob.start(title: 'Texture-heavy conversion', output_path: 'C:/tmp/model.bomc') do
  {
    path: 'C:/tmp/model.bomc', bytes: 110, candidate_bytes: 110,
    source_info: { bytes: 100 }, savings_bytes: -10,
    status: :over_budget, strategy: :maximum_lossless,
    validation: { nodes: 7, triangles: 11 }
  }
end
UI.tick while over_budget_job.running?
over_budget_script = UI::HtmlDialog.last.scripts.find { |script| script.include?('completeConversion') }.to_s
assert(over_budget_script.include?('"gate_status":"over_budget"'), 'over-budget lossless export completes instead of entering the failure UI')
assert(over_budget_script.include?('"savings_bytes":-10'), 'completion UI receives the exact signed SKP size delta')

cancelled_job = BOMEngine::ConversionJob.start(title: 'Cancel conversion', output_path: 'C:/tmp/model.json') do |progress|
  3.times { |index| progress.call(stage: "Stage #{index}", processed: index + 1) }
end
cancelled_job.cancel
UI.tick while cancelled_job.running?
assert(UI::HtmlDialog.last.scripts.any? { |script| script.include?('cancelledConversion') }, 'cancel request stops at cooperative checkpoint')
assert(BOMEngine::ConversionJob.active.nil?, 'cancelled job releases global active slot')
assert(cancelled_job.generation_id > first_generation, 'later jobs use a new generation instead of reusing stale progress metrics')
assert(cancelled_job.performance_metrics[:generation_id] == cancelled_job.generation_id,
  'cancelled job metrics cannot be mistaken for an earlier generation')

puts 'Conversion Job Tests: ALL PASSED'
