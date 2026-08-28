# frozen_string_literal: true

require 'json'

EXPECTED = {
  '01' => :legacy_json,
  '02' => :tiered_json,
  '03' => :minified_visual_json,
  '04' => :canonical_v3,
  '05' => :model_eval_json,
  '06' => :bome2,
  '07' => :cleanpkg,
  '08' => :bomc_v1,
  '09' => :bomc_scene,
  '10' => :bomc_scene,
  '11' => :bomc_scene,
  '12' => :bomc_scene,
  '13' => :bomc_scene,
  '14' => :bomc_scene,
  '15' => :bomc_scene,
  '16' => :bomc_scene,
  '17' => :bomc_scene
}.freeze

root = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'history', 'versions.json')))
actual = {}

manifest.fetch('versions').each do |version|
  id = version.fetch('label')[/\A\[(\d{2})\]/, 1]
  next unless id

  key = version.fetch('display_version').gsub(/[^A-Za-z0-9_]/, '_').downcase
  entry = File.join(root, 'history', 'generated', version.fetch('display_version'), 'staged', "entry_#{key}.rb")
  load entry
  target = version.fetch('isolated_module').split('::').inject(Object) { |scope, name| scope.const_get(name) }
  actual[id] = target.const_get(:EXPORT_KIND)
end

raise "wrong version exporter mapping: #{actual.inspect}" unless actual == EXPECTED

puts 'version export kinds: PASS ([01]-[09] map to distinct format adapters)'
