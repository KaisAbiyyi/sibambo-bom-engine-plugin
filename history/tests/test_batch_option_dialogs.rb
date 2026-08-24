# frozen_string_literal: true

require 'json'

root = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'history', 'versions.json')))
expected_sizes = %w[96 128 256 512 1024 2048 4096 8192]
missing = []

manifest.fetch('versions').each do |version|
  html_path = File.join(
    root, 'history', 'generated', version.fetch('display_version'),
    'staged', 'bom_engine', 'ui', 'export_dialog.html'
  )
  html = File.read(html_path, encoding: 'UTF-8')
  options = html.scan(/<option value="(\d+)"/).flatten
  wired = html.include?('settings.batch_size = selectedBatchSize();')
  missing << version.fetch('display_version') unless options == expected_sizes && wired
end

raise "missing or unwired batch selector: #{missing.join(', ')}" unless missing.empty?

puts "batch option dialogs: PASS (#{manifest.fetch('versions').length} identical selectors)"
