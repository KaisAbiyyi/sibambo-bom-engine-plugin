# frozen_string_literal: true

require 'json'

EXPECTED = {
  '05' => ['model_eval_json', 'Model-Eval Compact JSON', '_model-eval.json'],
  '06' => ['bome2', 'BOME2 Binary Runtime', '_runtime.bome2'],
  '07' => ['cleanpkg', 'CleanPKG Binary Container', '.cleanpkg'],
  '08' => ['bomc_v1', 'First BOMC Compiled Format', '.bomc'],
  '09' => ['bomc_scene', 'Scene/Page-Preserving BOMC', '.bomc']
}.freeze

root = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'history', 'versions.json')))
failures = []

manifest.fetch('versions').each do |version|
  id = version.fetch('label')[/\A\[(\d{2})\]/, 1]
  next unless EXPECTED.key?(id)

  export_kind, title, suffix = EXPECTED.fetch(id)
  staged = File.join(root, 'history', 'generated', version.fetch('display_version'), 'staged')
  html = File.read(File.join(staged, 'bom_engine', 'ui', 'export_dialog.html'), encoding: 'UTF-8')
  dialog = File.read(File.join(staged, 'bom_engine', 'ui_dialog.rb'), encoding: 'UTF-8')

  failures << "[#{id}] missing locked export kind" unless html.include?(%{data-evolution-export-kind="#{export_kind}"})
  failures << "[#{id}] wrong title" unless html.include?(title)
  failures << "[#{id}] wrong output suffix" unless html.include?(suffix)
  failures << "[#{id}] still exposes format selector" if html.include?('id="outputFormat"')
  failures << "[#{id}] still defaults to canonical" if html.include?('canonical_v3')
  failures << "[#{id}] dialog title is generic" if dialog.include?('dialog_title: "BOM Engine — Export Settings"')
end

raise "format-locked dialog failures:\n#{failures.join("\n")}" unless failures.empty?

puts 'format-locked dialogs: PASS ([05]-[09] cannot fall back to canonical UI)'
