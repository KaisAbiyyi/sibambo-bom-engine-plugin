# Run with standalone Ruby/JRuby. SketchUp UI is replaced by a deterministic stub.

MB_OK = 0 unless defined?(MB_OK)

module UI
  class HtmlDialog
    STYLE_DIALOG = 0

    class << self
      attr_reader :last
    end

    attr_reader :scripts

    def initialize(**_options)
      self.class.instance_variable_set(:@last, self)
      @callbacks = {}
      @scripts = []
    end

    def set_file(_path); end
    def set_on_closed(&callback); @on_closed = callback; end
    def add_action_callback(name, &callback); @callbacks[name] = callback; end
    def execute_script(script); @scripts << script; end
    def close; @on_closed.call if @on_closed; end
    def show; @callbacks['ready'].call(nil); end
  end

  class << self
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
    def openURL(*_args); end
  end
end

module SibamboHistory
  module V20260825_02
  module Logger
    def self.error(_message); end
  end
end

require_relative '../conversion_job'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
  puts "PASS: #{message}"
end

job = SibamboHistory::V20260825_02::ConversionJob.start(title: 'Test conversion', output_path: 'C:/tmp/model.json') do |progress|
  3.times { |index| progress.call(stage: "Stage #{index}", processed: index + 1) }
  { path: 'C:/tmp/model.json', bytes: 42, validation: { nodes: 7, triangles: 11 } }
end
UI.tick while job.running?
scripts = UI::HtmlDialog.last.scripts
assert(scripts.any? { |script| script.include?('updateProgress') }, 'progress window receives cooperative updates')
assert(scripts.any? { |script| script.include?('completeConversion') }, 'progress window receives completion result')
assert(SibamboHistory::V20260825_02::ConversionJob.active.nil?, 'completed job releases global active slot')

cancelled_job = SibamboHistory::V20260825_02::ConversionJob.start(title: 'Cancel conversion', output_path: 'C:/tmp/model.json') do |progress|
  3.times { |index| progress.call(stage: "Stage #{index}", processed: index + 1) }
end
cancelled_job.cancel
UI.tick while cancelled_job.running?
assert(UI::HtmlDialog.last.scripts.any? { |script| script.include?('cancelledConversion') }, 'cancel request stops at cooperative checkpoint')
assert(SibamboHistory::V20260825_02::ConversionJob.active.nil?, 'cancelled job releases global active slot')

puts 'Conversion Job Tests: ALL PASSED'

end # SibamboHistory
