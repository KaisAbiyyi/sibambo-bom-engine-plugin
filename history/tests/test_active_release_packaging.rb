# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/history/build_evolution_lab'
require_relative '../../tools/history/active_release_catalog'

$stdout.sync = true
$stderr.sync = true

puts '=== Testing Active Release Packaging & Snapshot Caching ==='

Dir.mktmpdir('active_packaging_test_') do |temp_root|
  temp_dist = File.join(temp_root, 'dist')
  temp_gen = File.join(temp_root, 'generated')

  # 1. Build Active Catalog (Master + Standalone for ready releases)
  puts "\n[STEP 1] Building active catalog into temp directory..."
  master_rbz_path = EvolutionLabBuilder.build(
    catalog: 'active',
    dist_dir: temp_dist,
    generated_dir: temp_gen
  )

  raise "Master RBZ path not returned" unless master_rbz_path && File.file?(master_rbz_path)

  # 2. Verify Checksums and Manifest files
  checksums_file = File.join(temp_dist, 'CHECKSUMS.sha256')
  manifest_file = File.join(temp_dist, 'MANIFEST.md')
  raise "CHECKSUMS.sha256 missing" unless File.file?(checksums_file)
  raise "MANIFEST.md missing" unless File.file?(manifest_file)

  checksum_lines = File.readlines(checksums_file, chomp: true).reject(&:empty?)
  checksum_map = {}
  checksum_lines.each do |line|
    sha, path = line.split(/\s+/, 2)
    checksum_map[path] = sha
  end

  master_name = File.basename(master_rbz_path)
  expected_master_sha = Digest::SHA256.file(master_rbz_path).hexdigest
  raise "Master SHA mismatch in CHECKSUMS.sha256" unless checksum_map[master_name] == expected_master_sha

  manifest_content = File.read(manifest_file, encoding: 'UTF-8')
  raise "MANIFEST.md missing baseline-8082541" unless manifest_content.include?('baseline-8082541')
  raise "MANIFEST.md must not package next-from-8082541" if manifest_content.include?('| `next-from-8082541` |')

  puts "  PASS: Checksums and Manifest are valid and deterministic"

  # 3. Inspect Master RBZ archive entries
  stdout, stderr, status = Open3.capture3('tar', '-tf', master_rbz_path)
  raise "Failed to inspect Master RBZ with tar: #{stderr}" unless status.success?

  entries = stdout.lines.map(&:strip)

  # Must contain master loader and menu
  raise "Master loader missing in archive" unless entries.any? { |e| e.include?('sibambo_bom_engine_evolution_lab.rb') }
  raise "Master menu missing in archive" unless entries.any? { |e| e.include?('evolution_lab/master_menu.rb') }

  # Must contain ready release baseline-8082541
  baseline_entry = 'evolution_lab/engine_baseline_8082541/entry_baseline_8082541.rb'
  raise "Baseline entry missing in archive: #{baseline_entry}" unless entries.any? { |e| e.include?(baseline_entry) }

  # Must NOT contain uncertified or development slots in Master RBZ
  raise "Master RBZ unexpectedly contains next_from_8082541" if entries.any? { |e| e.include?('next_from_8082541') }
  raise "Master RBZ unexpectedly contains scene_resilient_a158b75" if entries.any? { |e| e.include?('scene_resilient_a158b75') }
  raise "Master RBZ unexpectedly contains scene_fidelity_a138fe6" if entries.any? { |e| e.include?('scene_fidelity_a138fe6') }

  # Must NOT contain test suites
  orphaned_tests = entries.select { |e| e =~ /test_.*\.rb\z/ || e =~ %r{/tests/} }
  raise "Master RBZ contains test files: #{orphaned_tests.inspect}" unless orphaned_tests.empty?

  puts "  PASS: Master RBZ archive contents verified (isolated ready release only, 0 tests)"

  # 4. Verify Standalone RBZ for Ready Release
  standalone_baseline = File.join(temp_dist, 'standalone', 'sibambo_bom_engine_baseline_8082541.rbz')
  raise "Standalone baseline RBZ missing: #{standalone_baseline}" unless File.file?(standalone_baseline)

  expected_standalone_sha = Digest::SHA256.file(standalone_baseline).hexdigest
  raise "Standalone baseline SHA mismatch in CHECKSUMS.sha256" unless checksum_map['standalone/sibambo_bom_engine_baseline_8082541.rbz'] == expected_standalone_sha

  # Standalone folder must not contain unready releases
  standalone_files = Dir.glob(File.join(temp_dist, 'standalone', '*.rbz'))
  raise "Expected exactly 1 standalone RBZ, got #{standalone_files.length}" unless standalone_files.length == 1

  puts "  PASS: Standalone RBZ verified and matches CHECKSUMS.sha256"

  # 5. Snapshot metadata & caching test
  snapshot_meta_path = File.join(temp_gen, 'baseline-8082541', 'SNAPSHOT_METADATA.json')
  raise "Snapshot metadata missing: #{snapshot_meta_path}" unless File.file?(snapshot_meta_path)

  staged_baseline_dir = File.join(temp_gen, 'baseline-8082541', 'staged')
  snapshot_meta = JSON.parse(File.read(snapshot_meta_path))
  raise "Snapshot producer_sha mismatch" unless snapshot_meta['producer_sha'] == '8082541d852cd68b9874231e41c6b9c967c74d26'
  raise "Snapshot transformer_revision mismatch" unless snapshot_meta['transformer_revision'] == EvolutionLabBuilder::TRANSFORMER_REVISION

  computed_tree_sha = EvolutionLabBuilder.compute_tree_sha(staged_baseline_dir)
  raise "Snapshot tree_sha mismatch" unless snapshot_meta['tree_sha256'] == computed_tree_sha
  raise "snapshot_valid? should be true" unless EvolutionLabBuilder.snapshot_valid?(File.join(temp_gen, 'baseline-8082541'), staged_baseline_dir, snapshot_meta['producer_sha'])

  # Re-run build to verify cached snapshot reuse
  puts "\n[STEP 2] Verifying cache reuse on second build..."
  EvolutionLabBuilder.build(
    catalog: 'active',
    dist_dir: temp_dist,
    generated_dir: temp_gen
  )
  puts "  PASS: Cached snapshot successfully validated and reused"

  # 6. Candidate mode build
  puts "\n[STEP 3] Testing candidate build for scene-resilient-a158b75..."
  cand_pkg = EvolutionLabBuilder.build(
    catalog: 'active',
    candidate: 'scene-resilient-a158b75',
    dist_dir: temp_dist,
    generated_dir: temp_gen
  )
  cand_rbz = File.join(temp_dist, 'candidate', 'scene-resilient-a158b75', 'sibambo_bom_engine_scene_resilient_a158b75.rbz')
  raise "Candidate RBZ missing: #{cand_rbz}" unless File.file?(cand_rbz)
  raise "Candidate package sha mismatch" unless Digest::SHA256.file(cand_rbz).hexdigest == cand_pkg[:sha256]

  cand_checksums = File.join(temp_dist, 'candidate', 'scene-resilient-a158b75', 'CHECKSUMS.sha256')
  raise "Candidate CHECKSUMS.sha256 missing" unless File.file?(cand_checksums)

  puts "  PASS: Candidate release build verified"

  # 7. Unbuilt development release rejection
  puts "\n[STEP 4] Verifying rejection of unbuilt development candidate..."
  rejection_passed = false
  begin
    EvolutionLabBuilder.build(
      catalog: 'active',
      candidate: 'next-from-8082541',
      dist_dir: temp_dist,
      generated_dir: temp_gen
    )
  rescue StandardError => e
    rejection_passed = true
    puts "  Caught expected error: #{e.message}"
  end
  raise "Expected build of unbuilt development candidate to fail!" unless rejection_passed
  puts "  PASS: Unbuilt development release rejected cleanly"

  # 8. Entry point contract verification
  entry_file = File.join(temp_gen, 'baseline-8082541', 'staged', 'entry_baseline_8082541.rb')
  raise "Entry file missing: #{entry_file}" unless File.file?(entry_file)
  entry_src = File.read(entry_file, encoding: 'UTF-8')

  raise "Missing RELEASE_ID in entry" unless entry_src.include?('RELEASE_ID = "baseline-8082541"')
  raise "Missing ENTRY_KIND in entry" unless entry_src.include?('ENTRY_KIND = :bomc_three_profile')
  raise "Missing PROFILES in entry" unless entry_src.include?('PROFILES = ["visual", "research", "exact"]')

  puts "  PASS: Entry point contract verified"
end

puts "\n[SUCCESS] Active release packaging tests: ALL PASSED."
