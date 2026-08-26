# frozen_string_literal: true

require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require_relative '../../tools/history/build_evolution_lab'

root = File.expand_path('../..', __dir__)
versions_path = File.join(root, 'history', 'versions.json')
manifest = JSON.parse(File.read(versions_path, encoding: 'UTF-8'))
versions = manifest['versions']

puts "=== Testing Evolution Lab Milestone Provenance & Immutability ==="

versions.each do |ver|
  disp = ver['display_version']
  sha = ver['commit_sha']
  mod_name = ver['isolated_module']
  key = disp.gsub(/[^A-Za-z0-9_]/, '_')
  staged_committed = File.join(root, 'history', 'generated', disp, 'staged')

  raise "Committed staged directory missing for #{disp}: #{staged_committed}" unless Dir.exist?(staged_committed)

  Dir.mktmpdir("provenance_test_#{key}") do |tmp_dir|
    raw_dir = File.join(tmp_dir, 'raw')
    staged_dir = File.join(tmp_dir, 'staged')
    FileUtils.mkdir_p(raw_dir)
    FileUtils.mkdir_p(staged_dir)

    # 1. Extract directly from the declared pinned commit SHA
    EvolutionLabBuilder.extract_git_snapshot(sha, raw_dir, ver)

    # 2. Transform into isolated namespace
    EvolutionLabBuilder.transform_snapshot(raw_dir, staged_dir, ver, key, mod_name)
    EvolutionLabBuilder.apply_runtime_hardening(staged_dir, ver)

    # 3. Compare transformed files against committed staged directory
    committed_files = Dir.glob(File.join(staged_committed, '**', '*')).select { |f| File.file?(f) }
    rebuilt_files = Dir.glob(File.join(staged_dir, '**', '*')).select { |f| File.file?(f) }

    committed_rel = committed_files.map { |f| f.sub("#{staged_committed}/", '').sub("#{staged_committed}\\", '').tr('\\', '/') }.sort
    rebuilt_rel = rebuilt_files.map { |f| f.sub("#{staged_dir}/", '').sub("#{staged_dir}\\", '').tr('\\', '/') }.sort

    if committed_rel != rebuilt_rel
      diff_missing = committed_rel - rebuilt_rel
      diff_extra = rebuilt_rel - committed_rel
      raise "File list mismatch for milestone #{disp} from pinned commit #{sha[0..7]}:\nMissing: #{diff_missing}\nExtra: #{diff_extra}"
    end

    committed_rel.each do |rel_path|
      committed_content = File.binread(File.join(staged_committed, rel_path))
      rebuilt_content = File.binread(File.join(staged_dir, rel_path))

      if committed_content != rebuilt_content
        raise "Content mismatch in #{rel_path} for milestone #{disp} from pinned commit #{sha[0..7]}!"
      end
    end

    puts "  PASS [#{disp}]: Pinned commit #{sha[0..7]} exactly reproduces committed staged files (#{committed_rel.length} files)"
  end
end

puts "[SUCCESS] All #{versions.length} historical milestones are immutable and reproducible from their declared git commits."
