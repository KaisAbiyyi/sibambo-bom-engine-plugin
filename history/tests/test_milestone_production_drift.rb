# frozen_string_literal: true

require 'digest'

root = File.expand_path('../..', __dir__)
prod_dir = File.join(root, 'bom_engine')
staged_dir = File.join(root, 'history', 'generated', 'SBE-2026.08.26-01', 'staged', 'bom_engine')

protected_files = [
  'scene_visibility_resolver.rb',
  'bomc_writer.rb',
  'bomc_decoder.rb',
  'canonical_graph_builder.rb',
  'bomc_format.rb',
  'bomc_model_adapter.rb',
  'bomc_extension.rb'
]

def normalize_code(code)
  c = code.dup
  c.gsub!(/module\s+SibamboHistory\s*\n\s*module\s+V20260826_01/, 'module BOMEngine')
  c.gsub!(/SibamboHistory::V20260826_01::/, 'BOMEngine::')
  c.gsub!(/\nend # SibamboHistory\s*\z/, '')
  c.gsub!(/SETTINGS_KEY = "Sibambo_History_SBE_2026_08_26_01_Settings"/, 'SETTINGS_KEY = "BOMEngine_Settings"')
  c.gsub!(/__SBE-2026\.08\.26-01/, '')
  c.gsub!(/unless defined\?\(SibamboHistory::EVOLUTION_LAB_EMBEDDED\) \|\| file_loaded\?\(__FILE__\)/, 'unless file_loaded?(__FILE__)')
  c.strip
end

puts "=== Testing SBE-2026.08.26-01 milestone drift from production ==="

protected_files.each do |f|
  prod_path = File.join(prod_dir, f)
  staged_path = File.join(staged_dir, f)

  raise "Production file missing: #{prod_path}" unless File.exist?(prod_path)
  raise "Staged milestone file missing: #{staged_path}" unless File.exist?(staged_path)

  prod_src = File.read(prod_path, encoding: 'UTF-8')
  staged_src = File.read(staged_path, encoding: 'UTF-8')

  norm_prod = normalize_code(prod_src)
  norm_staged = normalize_code(staged_src)

  if norm_prod != norm_staged
    raise "DRIFT DETECTED: staged milestone #{f} does not match production #{f}!"
  end
  puts "  OK: #{f} matches production semantics"
end

puts "[SUCCESS] Milestone SBE-2026.08.26-01 is perfectly synchronized with production runtime."
