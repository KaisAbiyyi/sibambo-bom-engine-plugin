# frozen_string_literal: true

require 'json'

class WindowsPathDialog
  STYLE_DIALOG = 0

  attr_reader :callbacks, :scripts

  def initialize(**_options)
    @callbacks = {}
    @scripts = []
    UI.last_dialog = self
  end

  def set_file(_path); end

  def add_action_callback(name, &block)
    @callbacks[name] = block
  end

  def execute_script(script)
    @scripts << script
  end

  def show
    @callbacks.fetch('onReady').call(nil)
  end

  def close; end
end

module UI
  class << self
    attr_accessor :last_dialog, :savepanel_result

    def savepanel(*_args)
      savepanel_result
    end
  end

  HtmlDialog = WindowsPathDialog
end

module Sketchup
  Model = Struct.new(:path)
  MODEL = Model.new('D:\\projects\\sibambo\\model-eval\\skps\\PROJECT SBOOST 1.skp')

  def self.active_model
    MODEL
  end
end

def decoded_argument(script, function_name)
  match = script.match(/\A#{Regexp.escape(function_name)}\((.*)\)\z/)
  raise "unexpected JavaScript call: #{script}" unless match

  JSON.parse(match[1])
rescue JSON::ParserError => error
  raise "#{function_name} argument is not a JSON-safe JavaScript string: #{error.message}"
end

dialog_file = File.expand_path(
  '../generated/SBE-2026.05.11-01/staged/bom_engine/ui_dialog.rb',
  __dir__
)
load dialog_file

SibamboHistory::V20260511_01::UIDialog.show
dialog = UI.last_dialog
default_call = dialog.scripts.find { |script| script.start_with?('setDefaultPath(') }
expected_default = 'D:\\projects\\sibambo\\model-eval\\skps\\PROJECT SBOOST 1__SBE-2026.05.11-01_bom.json'
actual_default = decoded_argument(default_call, 'setDefaultPath')
raise "default Windows path changed: #{actual_default.inspect}" unless actual_default == expected_default

UI.savepanel_result = "D:\\Exports\\Kais's Project\\[01] output.json"
dialog.callbacks.fetch('browse').call(nil)
browse_call = dialog.scripts.reverse.find { |script| script.start_with?('setPath(') }
actual_browse = decoded_argument(browse_call, 'setPath')
raise "browsed Windows path changed: #{actual_browse.inspect}" unless actual_browse == UI.savepanel_result

puts 'Windows dialog paths: PASS (backslashes, spaces, apostrophes preserved)'
