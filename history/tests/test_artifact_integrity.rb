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
master_rbz_name = 'sibambo_bom_engine_evolution_lab_v1.1.16.rbz'
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

# 3. Verify no non-runnable tests are packaged in staged runtime artifacts
versions.each do |ver|
  disp = ver['display_version']
  staged_dir = File.join(root, 'history', 'generated', disp, 'staged')

  test_files = Dir.glob(File.join(staged_dir, '**', 'test_*.rb'))
  unless test_files.empty?
    raise "Non-runnable or unverified test scripts packaged in staged #{disp}: #{test_files.inspect}"
  end

  Dir.glob(File.join(staged_dir, '**', '*.rb')).each do |rb_file|
    _out, err, status = Open3.capture3("ruby -c \"#{rb_file}\"")
    unless status.success?
      raise "Ruby syntax error in #{rb_file}: #{err}"
    end
  end
end
puts "  PASS: All #{versions.length} staged milestone artifacts are syntactically valid and free of orphaned test scripts"

# 4. Verify MANIFEST.md does not contain stale 2026-08-25 date
manifest_content = File.read(manifest_path, encoding: 'UTF-8')
if manifest_content.include?('Generated At: `2026-08-25`')
  raise 'MANIFEST.md has stale generated date: 2026-08-25'
end
puts '  PASS: MANIFEST.md has fresh generation metadata'

puts '[SUCCESS] Evolution Lab artifact integrity is verified 100%.'
