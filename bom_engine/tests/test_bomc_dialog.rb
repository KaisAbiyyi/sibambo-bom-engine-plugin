# frozen_string_literal: true

MB_OK = 0 unless defined?(MB_OK)

module UI
  class HtmlDialog
    STYLE_DIALOG = 0

    class << self
      attr_reader :last
    end

    attr_reader :callbacks, :options, :scripts, :file

    def initialize(**options)
      @options = options
      @callbacks = {}
      @scripts = []
      self.class.instance_variable_set(:@last, self)
    end

    def set_file(path); @file = path; end
    def add_action_callback(name, &callback); @callbacks[name] = callback; end
    def execute_script(script); @scripts << script; end
    def close; @closed = true; end
    def show; self; end
  end

  class << self
    attr_accessor :savepanel_result

    def savepanel(*_args)
      savepanel_result
    end
  end
end

require_relative '../bomc_dialog'

yielded = nil
BOMEngine::BOMCDialog.show(
  default_path: 'D:/exports/House__SIBAMBO-BOMC-v1.2.0.bomc'
) { |settings| yielded = settings }

dialog = UI::HtmlDialog.last
raise 'Dialog title missing product version.' unless dialog.options[:dialog_title] == 'Sibambo BOMC Engine 1.2.0 — Export BOMC 1.2'
raise 'BOMC dialog HTML was not loaded.' unless File.basename(dialog.file) == 'bomc_export_dialog.html'

dialog.callbacks.fetch('onReady').call(nil)
raise 'Default output path was not sent to dialog.' unless dialog.scripts.last.include?('House__SIBAMBO-BOMC-v1.2.0.bomc')

UI.savepanel_result = 'D:/exports/Renamed.bomc'
dialog.callbacks.fetch('browse').call(nil)
raise 'Browsed output path was not sent to dialog.' unless dialog.scripts.last.include?('Renamed.bomc')

dialog.callbacks.fetch('export').call(
  nil,
  '{"output_path":"D:/exports/Renamed.bomc","profile":"exact","batch_size":2048}'
)
expected = { output_path: 'D:/exports/Renamed.bomc', profile: 'exact', batch_size: 2048 }
raise "Dialog settings mismatch: #{yielded.inspect}" unless yielded == expected

puts 'BOMC HtmlDialog callback contract: PASS'
