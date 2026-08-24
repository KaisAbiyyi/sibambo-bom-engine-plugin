# frozen_string_literal: true

require 'json'

root = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'history', 'versions.json')))
guard = 'unless defined?(SibamboHistory::EVOLUTION_LAB_EMBEDDED) || file_loaded?(__FILE__)'
failures = []

manifest.fetch('versions').each do |version|
  staged = File.join(root, 'history', 'generated', version.fetch('display_version'), 'staged')
  key = version.fetch('display_version').gsub(/[^A-Za-z0-9_]/, '_').downcase
  entry = File.read(File.join(staged, "entry_#{key}.rb"), encoding: 'UTF-8')
  core = File.read(File.join(staged, 'bom_engine', 'core.rb'), encoding: 'UTF-8')

  failures << "#{version.fetch('display_version')} missing embedded marker" unless entry.include?('EVOLUTION_LAB_EMBEDDED = true')
  failures << "#{version.fetch('display_version')} core menu is not isolated" unless core.include?(guard)

  bomc_path = File.join(staged, 'bom_engine', 'bomc_extension.rb')
  next unless File.file?(bomc_path)

  bomc = File.read(bomc_path, encoding: 'UTF-8')
  failures << "#{version.fetch('display_version')} BOMC menu is not isolated" unless bomc.include?(guard)
end

raise "embedded menu isolation failures:\n#{failures.join("\n")}" unless failures.empty?

puts 'embedded menu isolation: PASS (only the Evolution Lab master menu registers)'
