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

  def test_three_active_version_items_route_to_format_dialog_or_e4
    Dir.mktmpdir('lineup-menu-') do |dir|
      %w[master_menu.rb lineup_dialog.rb].each { |name| FileUtils.cp(File.join(SOURCE, name), File.join(dir, name)) }
      slots = %w[canonical_v3 cleanpkg bomc_three_profile].each_with_index.map do |kind, i|
        name = "FakeE#{i + 2}"
        engine = File.join(dir, "e#{i + 2}")
        FileUtils.mkdir_p(engine)
        File.write(File.join(engine, 'entry.rb'), <<~RUBY)
          module SibamboHistory
            module #{name}
              def self.load_engine; self; end
              def self.export_current_model(_model, settings); $evolution_exported = settings; end
              def self.normalize_output_path(path, _profile); path; end
              module BOMCExtension
                def self.export_interactive; $e4_called = true; end
              end
            end
          end
        RUBY
        { 'id' => (i == 2 ? 'e4-bomc' : "e#{i + 2}"), 'engine' => "e#{i + 2}", 'title' => "E#{i + 2} — #{kind}", 'kind' => kind,
          'formatVersion' => 'test', 'profiles' => %w[exact visual], 'sha' => (i + 2).to_s * 64,
          'entry' => "e#{i + 2}/entry.rb", 'moduleName' => "SibamboHistory::#{name}" }
      end
      File.write(File.join(dir, 'engines.json'), JSON.generate(slots))
      load File.join(dir, 'master_menu.rb')

      submenu = UI.menu('Extensions').items.last.last
      # The three "Batch Ex Export..." items precede the version items (commit 6b2d459);
      # select each group by label, never by position.
      batch_items = submenu.items.select { |name, _| name.is_a?(String) && name.start_with?('Batch ') }
      assert_equal ['Batch E2 Export...', 'Batch E3 Export...', 'Batch E4 Export...'], batch_items.map(&:first)
      version_items = submenu.items.select { |name, _| name.is_a?(String) && name.start_with?('E') }
      labels = version_items.map(&:first)
      assert_equal 3, labels.length
      assert_equal %w[E2 E3 E4], labels.map { |label| label.split.first }
      assert labels.all? { |label| label.include?('·') }

      captured = nil
      SibamboHistory::EvolutionLab::LineupDialog.singleton_class.define_method(:show) do |slot:, model:, target:, &block|
        captured = [slot.fetch('id'), model, target, block]
      end
      version_items[0].last.call
      assert_equal 'e2', captured[0]
      assert_same Sketchup.active_model, captured[1]
      assert_nil $e4_called
      version_items[2].last.call
      assert_equal true, $e4_called
      assert_equal [], UI.messages

      batch_engines = []
      SibamboHistory::FakeE4.singleton_class.send(:remove_method, :load_engine)
      batch_runtime = Module.new
      batch_runtime.const_set(:OvernightBatch, Module.new)
      batch_runtime::OvernightBatch.const_set(:Dialog, Module.new)
      batch_runtime::OvernightBatch::Dialog.define_singleton_method(:show) { |engine:| batch_engines << engine }
      SibamboHistory::FakeE4.define_singleton_method(:load_engine) { batch_runtime }
      batch_items.each { |_, action| action.call }
      assert_equal %w[e2 e3 e4], batch_engines
      assert_equal [], UI.messages

      SibamboHistory::EvolutionLab.open_engine('e3', Sketchup.active_model)
      captured.last.call(output_path: 'C:/out__E3__EXACT.cleanpkg', batch_size: 512, profile: :exact)
      assert_equal :exact, $evolution_exported.fetch(:profile)
    end
  end
end
