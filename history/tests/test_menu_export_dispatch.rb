# frozen_string_literal: true

# Regression: each historical version menu must export only the model that is
# already open. Folder batching belongs exclusively to the separate batch item.

class FakeMenu
  attr_reader :items, :submenus

  def initialize
    @items = {}
    @submenus = {}
  end

  def add_submenu(label)
    @submenus[label] = self.class.new
  end

  def add_item(label, &block)
    @items[label] = block
    label
  end

  def add_separator; end
end

module UI
  class << self
    attr_reader :extensions_menu

    def menu(_label)
      @extensions_menu ||= FakeMenu.new
    end

    def messagebox(*); end
  end
end

module Sketchup
  CURRENT_MODEL = Object.new

  def self.active_model
    CURRENT_MODEL
  end

  def self.set_status_text(*); end
end

MB_OK = 0 unless defined?(MB_OK)

root = File.expand_path('../..', __dir__)
menu_path = File.join(root, 'dist', 'history', 'staging', 'evolution_lab', 'master_menu.rb')
raise "master menu missing: #{menu_path}" unless File.file?(menu_path)

load menu_path

module SibamboHistory
  module EvolutionLab
    class << self
      attr_accessor :test_current_exports

      def export_current_model(format_id, model)
        self.test_current_exports ||= []
        self.test_current_exports << [format_id, model]
      end
    end
  end
end

runner = SibamboHistory::EvolutionLab::BatchRunner
runner.singleton_class.class_eval do
  attr_accessor :test_batch_starts

  define_method(:start_or_resume) do |*_args|
    self.test_batch_starts = test_batch_starts.to_i + 1
  end

  define_method(:start_for_format) do |_format_id|
    raise 'version menu incorrectly entered folder batch processing'
  end
end

lab = UI.extensions_menu.submenus.fetch('Sibambo BOM Engine Evolution Lab')
major = lab.submenus.fetch('Major & Release Versions')

version_items = major.items.select { |label, _callback| label.match?(/^\[\d{2}\]/) }
raise "expected 9 version items, got #{version_items.length}" unless version_items.length == 9

version_items.each_value(&:call)

expected_ids = (1..9).map { |number| format('%02d', number) }
actual = SibamboHistory::EvolutionLab.test_current_exports || []
actual_ids = actual.map(&:first)
raise "wrong current-model dispatch: #{actual_ids.inspect}" unless actual_ids == expected_ids
raise 'a version menu did not pass SketchUp.active_model' unless actual.all? { |_id, model| model.equal?(Sketchup::CURRENT_MODEL) }
raise 'version menu unexpectedly started folder batching' unless runner.test_batch_starts.to_i.zero?

batch_item = lab.items.fetch('Batch Export RUMAH + SBOOST ([01] to [09])')
batch_item.call
raise 'separate batch menu did not start folder batching' unless runner.test_batch_starts == 1

puts 'menu export dispatch: PASS (9 current-model entries; 1 separate folder batch entry)'
