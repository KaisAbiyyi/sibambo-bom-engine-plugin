# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'tmpdir'
require 'fileutils'

module Sketchup
  MODEL = Object.new
  def self.active_model; MODEL; end
end

module UI
  class FakeMenu
    attr_reader :items
    def initialize; @items = []; end
    def add_submenu(title)
      child = FakeMenu.new
      @items << [title, child]
      child
    end
    def add_item(title, &action); @items << [title, action]; end
    def add_separator; @items << [:separator, nil]; end
  end
  def self.menu(_name); @menu ||= FakeMenu.new; end
  def self.messages; @messages ||= []; end
  def self.messagebox(message, _flags); messages << message; end
end

class TestEvolutionLineupMenu < Test::Unit::TestCase
  SOURCE = File.expand_path('../../tools/history/evolution_lineup', __dir__)

  def test_four_version_items_route_to_format_dialog_or_e4
    Dir.mktmpdir('lineup-menu-') do |dir|
      %w[master_menu.rb lineup_dialog.rb historical_preflight.rb].each { |name| FileUtils.cp(File.join(SOURCE, name), File.join(dir, name)) }
      slots = %w[tiered_json canonical_v3 cleanpkg bomc_three_profile].each_with_index.map do |kind, i|
        name = "FakeE#{i + 1}"
        engine = File.join(dir, "e#{i + 1}")
        FileUtils.mkdir_p(engine)
        File.write(File.join(engine, 'entry.rb'), <<~RUBY)
          module SibamboHistory
            module #{name}
              def self.load_engine; self; end
              def self.export_current_model(_model, _settings); $historical_exported = true; end
              module BOMCExtension
                def self.export_interactive; $e4_called = true; end
              end
            end
          end
        RUBY
        { 'id' => "e#{i + 1}", 'title' => "E#{i + 1} — #{kind}", 'kind' => kind,
          'sha' => (i + 1).to_s * 64, 'entry' => "e#{i + 1}/entry.rb", 'moduleName' => "SibamboHistory::#{name}" }
      end
      File.write(File.join(dir, 'engines.json'), JSON.generate(slots))
      load File.join(dir, 'master_menu.rb')

      submenu = UI.menu('Extensions').items.last.last
      labels = submenu.items.select { |name, _| name.is_a?(String) && name.start_with?('E') }.map(&:first)
      assert_equal 4, labels.length
      assert_equal %w[E1 E2 E3 E4], labels.map { |label| label.split.first }
      assert labels.all? { |label| label.include?('·') }

      captured = nil
      SibamboHistory::EvolutionLab::LineupDialog.singleton_class.define_method(:show) do |slot:, model:, target:, &block|
        captured = [slot.fetch('id'), model, target, block]
      end
      submenu.items[0].last.call
      assert_equal 'e1', captured[0]
      assert_same Sketchup.active_model, captured[1]
      assert_nil $e4_called
      submenu.items[3].last.call
      assert_equal true, $e4_called
      assert_equal [], UI.messages

      projective = [1.0, 0.0, 0.0, 0.1, 0.0, 1.0, 0.0, 0.0,
                    0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
      entity = Struct.new(:transformation, :name, :definition).new(Struct.new(:values) { def to_a; values; end }.new(projective), 'Unsupported', nil)
      model = Struct.new(:entities).new([entity])
      SibamboHistory::EvolutionLab.open_engine('e3', model)
      $historical_exported = false
      error = assert_raise(ArgumentError) { captured.last.call(output_path: 'C:/out.cleanpkg', batch_size: 512) }
      assert_equal false, $historical_exported, 'E3 never starts an export that silently loses projective transform terms'
      assert_match(/CleanPKG/, error.message)
    end
  end
end
