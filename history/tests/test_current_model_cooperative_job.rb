# frozen_string_literal: true

class JobDialog
  STYLE_DIALOG = 0

  attr_reader :scripts

  def initialize(**_options)
    @scripts = []
  end

  def set_html(_html); end
  def add_action_callback(_name, &_block); end
  def set_on_closed(&_block); end
  def execute_script(script); @scripts << script; end
  def show; end
  def close; end
end

module UI
  HtmlDialog = JobDialog

  class << self
    attr_reader :timers, :messages

    def start_timer(_interval, _repeat, &callback)
      @timers ||= []
      @timers << callback
      @timers.length
    end

    def stop_timer(_id); end

    def messagebox(message)
      @messages ||= []
      @messages << message
    end
  end
end

job_file = File.expand_path(
  '../generated/SBE-2026.05.11-01/staged/evolution_cooperative_job.rb',
  __dir__
)
raise "cooperative job missing: #{job_file}" unless File.file?(job_file)

load job_file
job = SibamboHistory::V20260511_01::EvolutionCooperativeJob
events = []
job.start(title: 'Exporter [01]', batch_size: 96) do |progress|
  events << :before
  progress.call(stage: 'Traversal', processed: 96)
  events << :middle
  progress.call(stage: 'Traversal', processed: 192)
  events << :after
end

tick = UI.timers.last
tick.call
raise "first checkpoint did not yield: #{events.inspect}" unless events == [:before]
tick.call
raise "second checkpoint did not yield: #{events.inspect}; #{UI.messages.inspect}" unless events == %i[before middle]
tick.call
raise "job did not finish after final slice: #{events.inspect}" unless events == %i[before middle after]

puts 'current-model cooperative job: PASS (Fiber yields between selected batches)'
