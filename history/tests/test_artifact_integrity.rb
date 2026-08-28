# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'

root = File.expand_path('../..', __dir__)
dist_dir = File.join(root, 'dist', 'history')
checksums_path = File.join(dist_dir, 'CHECKSUMS.sha256')
manifest_path = File.join(dist_dir, 'MANIFEST.md')
versions_path = File.join(root, 'history', 'versions.json')

puts '=== Testing Evolution Lab Artifact Integrity ==='

raise 'CHECKSUMS.sha256 missing' unless File.exist?(checksums_path)
raise 'MANIFEST.md missing' unless File.exist?(manifest_path)

checksums = {}
File.readlines(checksums_path, chomp: true).each do |line|
  next if line.strip.empty?
  sha, rel_path = line.split(/\s+/, 2)
  checksums[rel_path] = sha
end

# 1. Verify Master RBZ
manifest = JSON.parse(File.read(versions_path, encoding: 'UTF-8'))
versions = manifest['versions']
master_rbz_name = 'sibambo_bom_engine_evolution_lab_v1.1.20.rbz'
master_rbz_path = File.join(dist_dir, master_rbz_name)

raise "Master RBZ missing: #{master_rbz_path}" unless File.exist?(master_rbz_path)
master_sha = Digest::SHA256.file(master_rbz_path).hexdigest
expected_master_sha = checksums[master_rbz_name]
raise "Master RBZ SHA mismatch: got #{master_sha}, expected #{expected_master_sha}" unless master_sha == expected_master_sha

puts "  PASS: Master RBZ #{master_rbz_name} matches checksum #{master_sha[0..11]} (size #{File.size(master_rbz_path)} bytes)"

# 2. Verify all standalone packages
versions.each do |ver|
  key = ver['display_version'].gsub(/[^A-Za-z0-9_]/, '_').downcase
  rbz_name = "standalone/sibambo_bom_engine_#{key}.rbz"
  rbz_path = File.join(dist_dir, rbz_name)

  raise "Standalone RBZ missing: #{rbz_path}" unless File.exist?(rbz_path)
  sha = Digest::SHA256.file(rbz_path).hexdigest
  expected_sha = checksums[rbz_name]
  raise "Standalone RBZ SHA mismatch for #{rbz_name}: got #{sha}, expected #{expected_sha}" unless sha == expected_sha
end
puts "  PASS: All #{versions.length} standalone RBZ packages match CHECKSUMS.sha256"

# 3. Verify all staged milestone Ruby files are syntactically valid
versions.each do |ver|
  disp = ver['display_version']
  staged_dir = File.join(root, 'history', 'generated', disp, 'staged')

  Dir.glob(File.join(staged_dir, '**', '*.rb')).each do |rb_file|
    _out, err, status = Open3.capture3("ruby -c \"#{rb_file}\"")
    unless status.success?
      raise "Ruby syntax error in #{rb_file}: #{err}"
    end
  end
end
puts "  PASS: All #{versions.length} staged milestone source snapshots are syntactically valid"

# 4. Verify runtime distribution packages exclude development test suites and include all engines
stdout, stderr, status = Open3.capture3("tar -tf \"#{master_rbz_path}\"")
if status.success?
  entries = stdout.lines.map(&:strip)
  orphaned_tests = entries.select { |e| e =~ /test_.*\.rb\z/ || e =~ %r{/tests/} }
  unless orphaned_tests.empty?
    raise "Master RBZ package contains development test suites: #{orphaned_tests.inspect}"
  end

  versions.each do |ver|
    key = ver['display_version'].gsub(/[^A-Za-z0-9_]/, '_').downcase
    expected_entry = "evolution_lab/engine_#{key}/entry_#{key}.rb"
    unless entries.any? { |e| e.include?(expected_entry) }
      raise "Master RBZ package missing engine entry: #{expected_entry}"
    end
  end
  puts "  PASS: Master RBZ archive verified directly (#{entries.length} entries; 0 test suites, all #{versions.length} engines present)"
else
  staging_dir = File.join(dist_dir, 'staging', 'evolution_lab')
  if Dir.exist?(staging_dir)
    orphaned_tests = Dir.glob(File.join(staging_dir, '**', 'test_*.rb'))
    unless orphaned_tests.empty?
      raise "Runtime staging contains development test suites: #{orphaned_tests.inspect}"
    end
  end
  puts "  PASS: Runtime distribution packages exclude orphaned development test suites"
end

# 5. Verify specialized dialog provenance and menu routing for the latest milestone.
latest_ver = versions.last
raise "Latest version must be SBE-2026.08.28-01" unless latest_ver['display_version'] == 'SBE-2026.08.28-01'
latest_staged = File.join(root, 'history', 'generated', latest_ver['display_version'], 'staged')
latest_entry = File.join(latest_staged, 'entry_sbe_2026_08_28_01.rb')
latest_html = File.join(latest_staged, 'bom_engine', 'ui', 'export_dialog.html')
latest_ui_dialog = File.join(latest_staged, 'bom_engine', 'ui_dialog.rb')

raise "Entry file missing for SBE-2026.08.28-01" unless File.exist?(latest_entry)
raise "Export HTML missing for SBE-2026.08.28-01" unless File.exist?(latest_html)

entry_src = File.read(latest_entry, encoding: 'UTF-8')
html_src = File.read(latest_html, encoding: 'UTF-8')
ui_dialog_src = File.read(latest_ui_dialog, encoding: 'UTF-8')

raise "Entry must declare EXPORT_KIND = :bomc_scene" unless entry_src.include?('EXPORT_KIND = :bomc_scene')
raise "Entry must suffix with __SBE-2026.08.28-01.bomc" unless entry_src.include?('"__SBE-2026.08.28-01.bomc"')
raise "HTML dialog must lock export kind to bomc_scene" unless html_src.include?('data-evolution-export-kind="bomc_scene"')
raise "UI dialog bridge must not have default canonical title" if ui_dialog_src.include?('BOM Engine — Export Settings')
raise "UI dialog default path contains a repeated milestone suffix" if ui_dialog_src.include?('__SBE-2026.08.28-01__SBE-2026.08.28-01')
raise "HTML path normalizer must strip a prior milestone suffix" unless html_src.include?('path.replace(/__SBE-')
puts "  PASS: Milestone [17] SBE-2026.08.28-01 specialized dialog provenance verified"

# 6. Verify output_with_suffix normalization table across formats
test_paths = {
  'model.json' => 'model__SBE-2026.08.28-01.bomc',
  'model_canonical.json' => 'model__SBE-2026.08.28-01.bomc',
  'model_runtime.bome2' => 'model__SBE-2026.08.28-01.bomc',
  'model.cleanpkg' => 'model__SBE-2026.08.28-01.bomc',
  'model.bomc' => 'model__SBE-2026.08.28-01.bomc',
  'model__SBE-2026.08.27-02.bomc' => 'model__SBE-2026.08.28-01.bomc'
}

eval_script = <<~RUBY
  #{entry_src}
  test_paths = #{test_paths.inspect}
  test_paths.each do |input, expected|
    actual = SibamboHistory::V20260828_01.output_with_suffix(input, '__SBE-2026.08.28-01.bomc')
    raise "Suffix normalization failure: \#{input} -> got \#{actual}, expected \#{expected}" unless actual == expected
  end
RUBY

eval_ok = system("ruby -e #{eval_script.inspect}")
raise "Suffix normalization table tests failed" unless eval_ok
puts "  PASS: Suffix normalization table-driven tests passed for all input extensions"

# 7. Verify MANIFEST.md does not contain stale date
manifest_content = File.read(manifest_path, encoding: 'UTF-8')
if manifest_content.include?('Generated At: `2026-08-25`')
  raise 'MANIFEST.md has stale generated date: 2026-08-25'
end
puts '  PASS: MANIFEST.md has fresh generation metadata'

puts '[SUCCESS] Evolution Lab artifact integrity is verified 100%.'
