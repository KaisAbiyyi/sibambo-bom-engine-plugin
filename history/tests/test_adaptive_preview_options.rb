# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../bom_engine/bomc_processing'
require_relative '../../tools/history/adaptive_preview/capture'

module UI
  class HtmlDialog
    STYLE_DIALOG = 0
    class << self; attr_reader :last; end
    attr_reader :callbacks, :file, :scripts, :centered
    def initialize(**_options)
      @callbacks = {}
      @scripts = []
      self.class.instance_variable_set(:@last, self)
    end
    def set_file(path); @file = path; end
    def add_action_callback(name, &block); @callbacks[name] = block; end
    def execute_script(script); @scripts << script; end
    def center; @centered = true; end
    def show; end
    def close; end
  end
end

class AdaptivePreviewOptionsTest < Minitest::Test
  def test_preview_options_center_and_pass_manual_batch_to_actual_capture
    item = { 'id' => '2-small-textured', 'source' => { 'path' => 'D:/house2.skp' } }
    engine = Module.new
    engine.const_set(:SOURCE_TREE_SHA256, 'a' * 64)
    engine.const_set(:BOMCProcessing, BOMEngine::BOMCProcessing)
    args = nil
    AdaptivePreviewCapture.stub(:start, ->(*positional, **keywords) { args = [positional, keywords] }) do
      AdaptivePreviewCapture.show_options('D:/kit', engine, 'D:/installed', item)
      dialog = UI::HtmlDialog.last
      assert dialog.centered
      assert_equal 'capture_options.html', File.basename(dialog.file)
      dialog.callbacks.fetch('ready').call(nil)
      assert dialog.scripts.any? { |script| script.include?('house2.skp') }
      dialog.callbacks.fetch('start').call(nil, JSON.generate(batch_mode: 'manual', batch_size: 8192))
    end
    assert_equal [8192, 'manual'], [args[1][:batch_size], args[1][:batch_mode]]
  end
end
