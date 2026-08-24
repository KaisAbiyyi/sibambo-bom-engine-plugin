# frozen_string_literal: true

require 'json'

root = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'history', 'versions.json')))

missing = []
manifest.fetch('versions').each do |version|
  key = version.fetch('display_version').gsub(/[^A-Za-z0-9_]/, '_').downcase
  entry = File.join(
    root, 'history', 'generated', version.fetch('display_version'),
    'staged', "entry_#{key}.rb"
  )
  load entry

  target = version.fetch('isolated_module').split('::').inject(Object) do |scope, name|
    scope.const_get(name)
  end
  missing << version.fetch('display_version') unless target.const_defined?(:PLUGIN_VERSION, false)
end

raise "entry points missing PLUGIN_VERSION: #{missing.join(', ')}" unless missing.empty?

puts "entry runtime constants: PASS (#{manifest.fetch('versions').length} isolated engines)"
