# frozen_string_literal: true

# Regression: each historical version menu must export only the model that is
# already open. Folder batching belongs exclusively to the separate batch item.

require 'json'

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
    attr_reader :extensions_menu, :last_message

    def menu(_label)
      @extensions_menu ||= FakeMenu.new
    end

    def messagebox(message, *)
      @last_message = message
    end
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
versions_path = File.join(root, 'history', 'versions.json')
raise "versions.json missing: #{versions_path}" unless File.file?(versions_path)

manifest = JSON.parse(File.read(versions_path, encoding: 'UTF-8'))
versions = manifest.fetch('versions')

release_versions = versions.reject { |v| v['classification'] == 'EXPERIMENT' }
experiment_versions = versions.select { |v| v['classification'] == 'EXPERIMENT' }

expected_ids = release_versions.map { |v| v['label'][/\A\[(\d{2})\]/, 1] }.compact
raise 'release version IDs must be non-empty' if expected_ids.empty?
raise 'duplicate release version IDs' unless expected_ids.uniq.length == expected_ids.length
raise 'every release version must have a 2-digit sequence ID in label' unless expected_ids.length == release_versions.length

menu_path = File.join(root, 'dist', 'history', 'staging', 'evolution_lab', 'master_menu.rb')
raise "master menu missing: #{menu_path}" unless File.file?(menu_path)

load menu_path

# 1. Verify CURRENT_MODEL_EXPORTERS table
exporters = SibamboHistory::EvolutionLab::CURRENT_MODEL_EXPORTERS
raise "exporters keys mismatch: #{exporters.keys.sort} vs #{expected_ids.sort}" unless exporters.keys.sort == expected_ids.sort

exporters.each do |format_id, info|
  entry_file = File.join(File.dirname(menu_path), info[:entry])
  raise "Historical exporter entry missing for [#{format_id}]: #{entry_file}" unless File.file?(entry_file)
end

# Negative test: unregistered ID lookup must fail
begin
  exporters.fetch('99')
  raise 'Expected KeyError for unregistered format_id 99'
rescue KeyError
  # Expected
end

# 2. Verify Menu structure and ordering
lab = UI.extensions_menu.submenus.fetch('Sibambo BOM Engine Evolution Lab')
major = lab.submenus.fetch('Major & Release Versions')
exp = lab.submenus.fetch('Experiments')

version_items = major.items.select { |label, _callback| label.match?(/^\[\d{2}\]/) }
raise "expected #{expected_ids.length} version items, got #{version_items.length}" unless version_items.length == expected_ids.length

# Assert chronological ordering and exact labels match catalog
release_versions.each_with_index do |ver, idx|
  actual_label = version_items.keys[idx]
  raise "menu order mismatch at #{idx}: expected #{ver['label']}, got #{actual_label}" unless actual_label == ver['label']
end

# Verify experiment items match catalog
exp_items = exp.items.select { |label, _callback| label.match?(/^\[EXP-\d{2}\]/) }
raise "expected #{experiment_versions.length} experiment items, got #{exp_items.length}" unless exp_items.length == experiment_versions.length

# 3. Verify Dispatch mechanism
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

version_items.each_value(&:call)

actual = SibamboHistory::EvolutionLab.test_current_exports || []
actual_ids = actual.map(&:first)
raise "wrong current-model dispatch: #{actual_ids.inspect}" unless actual_ids == expected_ids
raise 'a version menu did not pass SketchUp.active_model' unless actual.all? { |_id, model| model.equal?(Sketchup::CURRENT_MODEL) }

raise 'obsolete multi-model batch menu is still visible' if lab.items.key?('Batch Export RUMAH + SBOOST ([01] to [09])')

# 4. Verify About dialog
lab.items.fetch('About Evolution Lab').call
about = UI.last_message.to_s
latest_ver = versions.last
raise 'About dialog missing Evolution Lab version' unless about.include?('Evolution Lab version: v1.1.22')
raise "About dialog missing latest milestone #{latest_ver['display_version']}" unless about.include?(latest_ver['display_version'])
raise "About dialog missing total engines count #{versions.length}" unless about.include?("Total historical engines: #{versions.length}")

puts "menu export dispatch: PASS (#{version_items.length} current-model entries; all #{expected_ids.length} release versions verified against catalog)"
