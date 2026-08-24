# frozen_string_literal: true

require 'json'

class ScrollAuditDialog
  STYLE_DIALOG = 0

  attr_reader :options

  def initialize(**options)
    @options = options
    UI.dialogs << self
  end

  def set_file(_path); end
  def add_action_callback(_name, &_block); end
  def show; end
end

module UI
  class << self
    attr_accessor :dialogs
  end

  self.dialogs = []
  HtmlDialog = ScrollAuditDialog
end

module Sketchup
  Model = Struct.new(:path)
  MODEL = Model.new('D:\\projects\\sibambo\\model-eval\\skps\\RUMAH A.skp')

  def self.active_model
    MODEL
  end
end

root = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'history', 'versions.json')))

manifest.fetch('versions').each do |version|
  dialog_file = File.join(
    root, 'history', 'generated', version.fetch('display_version'),
    'staged', 'bom_engine', 'ui_dialog.rb'
  )
  next unless File.file?(dialog_file)

  load dialog_file
  target = version.fetch('isolated_module').split('::').inject(Object) do |scope, name|
    scope.const_get(name)
  end
  target.const_get(:UIDialog).show
end

expected = manifest.fetch('versions').count do |version|
  File.file?(File.join(root, 'history', 'generated', version.fetch('display_version'), 'staged', 'bom_engine', 'ui_dialog.rb'))
end
raise "expected #{expected} export dialogs, got #{UI.dialogs.length}" unless UI.dialogs.length == expected

blocked = UI.dialogs.reject { |dialog| dialog.options[:scrollable] == true }
raise "#{blocked.length} historical export dialogs disable scrolling" unless blocked.empty?

puts "scrollable export dialogs: PASS (#{expected} historical settings windows)"
