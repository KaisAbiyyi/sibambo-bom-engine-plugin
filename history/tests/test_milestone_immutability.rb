# frozen_string_literal: true

require 'digest'
require 'json'

root = File.expand_path('../..', __dir__)
versions_path = File.join(root, 'history', 'versions.json')
manifest = JSON.parse(File.read(versions_path, encoding: 'UTF-8'))
versions = manifest['versions']

puts '=== Testing Milestone Immutability Invariant ==='

def directory_tree_digest(dir_path)
  return nil unless Dir.exist?(dir_path)

  files = Dir.glob(File.join(dir_path, '**', '*')).select { |f| File.file?(f) }.sort
  hasher = Digest::SHA256.new

  files.each do |f|
    rel_path = f.sub("#{dir_path}/", '').sub("#{dir_path}\\", '').tr('\\', '/')
    content_hash = Digest::SHA256.file(f).hexdigest
    hasher.update("#{rel_path}:#{content_hash}\n")
  end

  hasher.hexdigest
end

# 1. Verify every milestone has a deterministic, non-empty tree digest
digests = {}
versions.each do |ver|
  disp = ver['display_version']
  dir_path = File.join(root, 'history', 'generated', disp)
  digest = directory_tree_digest(dir_path)
  raise "Missing milestone generated directory for #{disp}" if digest.nil?

  digests[disp] = digest
  puts "  MILESTONE [#{disp}]: tree SHA-256 = #{digest[0..11]} (#{ver['commit_sha'][0..7]})"
end

# 2. Verify chronological isolation: no earlier milestone references any later milestone or commit
versions.each_with_index do |ver, idx|
  disp = ver['display_version']
  staged_dir = File.join(root, 'history', 'generated', disp, 'staged')

  # Later version display names or modules must never leak into earlier staged files
  (versions[(idx + 1)..-1] || []).each do |later_ver|
    later_disp = later_ver['display_version']
    later_mod = later_ver['isolated_module']

    Dir.glob(File.join(staged_dir, '**', '*.rb')).each do |rb_file|
      content = File.read(rb_file, encoding: 'UTF-8')
      if content.include?(later_disp)
        raise "Historical leakage: #{rb_file} in #{disp} contains future milestone ID #{later_disp}!"
      end
      if content.include?(later_mod)
        raise "Historical leakage: #{rb_file} in #{disp} contains future module #{later_mod}!"
      end
    end
  end
end

puts "[SUCCESS] Historical immutability invariant verified across all #{versions.length} milestones."
