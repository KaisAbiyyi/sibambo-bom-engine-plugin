# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'time'
require 'fileutils'
require 'digest'
require 'tmpdir'

class TestT8RuntimeCaptureKit < Test::Unit::TestCase
  KIT_DIR = File.expand_path('../../../scratch/t8-capture-kit', __dir__)
  MANIFEST_PATH = File.join(KIT_DIR, 'manifest.json')
  PACKAGE_PATH = File.join(KIT_DIR, 'sibambo_bom_engine_next_from_8082541.rbz')
  CAPTURE_SCRIPT_PATH = File.join(KIT_DIR, 'capture_e4.rb')
  VERIFIER_PATH = File.join(KIT_DIR, 'verify_capture.rb')
  OPERATOR_GUIDE_PATH = File.join(KIT_DIR, 'OPERATOR_GUIDE.md')

  PINNED_PRODUCER_SHA = '7284982b26834f2635a839c6c7a1e687f83dca35'.freeze
  EXPECTED_SNAPSHOT_TREE_SHA256 = '71373d0fcda67580ab9333df8de4e1628d36b9f5c8d0c03f6e97061d8634a6f4'.freeze

  def setup
    @temp_dir = Dir.mktmpdir('t8-test-capture')
  end

  def teardown
    FileUtils.rm_rf(@temp_dir) if @temp_dir && File.directory?(@temp_dir)
  end

  def test_manifest_metadata_and_provenance
    assert File.file?(MANIFEST_PATH), "Manifest must exist at #{MANIFEST_PATH}"
    manifest = JSON.parse(File.read(MANIFEST_PATH))

    assert_equal 't8-capture-manifest-v1', manifest['schema_version']
    assert_equal 'next-from-8082541', manifest['release_id']
    assert_equal PINNED_PRODUCER_SHA, manifest['producer_sha']
    assert_equal '8082541d852cd68b9874231e41c6b9c967c74d26', manifest['base_producer_sha']
    assert_equal 'bomc-next-v1', manifest['loader_id']
    assert_equal 2, manifest['profile_contract_revision']
    assert_equal %w[visual research exact], manifest['supported_profiles']
    assert_equal '1.0', manifest['builder_revision']
    assert_equal '1.0', manifest['transformer_revision']
    assert_equal EXPECTED_SNAPSHOT_TREE_SHA256, manifest['snapshot_tree_sha256']

    assert File.file?(PACKAGE_PATH), "Package must exist at #{PACKAGE_PATH}"
    actual_pkg_sha = Digest::SHA256.file(PACKAGE_PATH).hexdigest
    assert_equal actual_pkg_sha, manifest['package_sha256']
  end

  def test_package_structure_and_isolation
    assert File.file?(PACKAGE_PATH)
    assert File.size(PACKAGE_PATH) > 500_000, 'Package should be around 1MB'

    # Check operator guide existence and required contents
    assert File.file?(OPERATOR_GUIDE_PATH)
    guide_content = File.read(OPERATOR_GUIDE_PATH)
    assert guide_content.include?('next-from-8082541')
    assert guide_content.include?('SibamboCaptureKit.export_profile(:visual)')
    assert guide_content.include?('SibamboCaptureKit.export_profile(:research)')
    assert guide_content.include?('SibamboCaptureKit.export_profile(:exact)')
    assert guide_content.include?('Install Extension')
    assert guide_content.include?('Uninstall')
  end

  def test_capture_script_syntax_and_structure
    assert File.file?(CAPTURE_SCRIPT_PATH)

    # Validate ruby syntax
    syntax_ok = system("ruby -c \"#{CAPTURE_SCRIPT_PATH}\" > nul 2>&1")
    assert syntax_ok, 'capture_e4.rb must have valid Ruby syntax'

    script_src = File.read(CAPTURE_SCRIPT_PATH)
    assert script_src.include?('module SibamboCaptureKit')
    assert script_src.include?('PROFILES = %i[visual research exact]')
    assert script_src.include?('def self.export_profile')
    assert script_src.include?('def self.export_all')
    assert script_src.include?('t8-runtime-capture-v1')
  end

  def test_verifier_marks_empty_results_as_incomplete
    assert File.file?(VERIFIER_PATH)
    require VERIFIER_PATH

    # Running verify against empty directory must return incomplete and ready: false
    res = T8CaptureVerifier.verify(@temp_dir)
    assert_equal 'incomplete', res[:status]
    assert_equal false, res[:ready]
    assert_equal %w[visual research exact], res[:missing_profiles]
    assert res[:errors].empty?
  end

  def test_verifier_validates_complete_capture_set_and_stays_not_ready
    require VERIFIER_PATH

    manifest = JSON.parse(File.read(MANIFEST_PATH))
    pkg_sha = manifest['package_sha256']

    # Generate mock captures for all 3 profiles with genuine dummy BOMC files
    %w[visual research exact].each do |prof|
      bomc_file = File.join(@temp_dir, "TestModel__E4__#{prof.upcase}.bomc")
      File.write(bomc_file, "BOMC_TEST_PAYLOAD_#{prof}_" + ('x' * 200))
      bomc_sha = Digest::SHA256.file(bomc_file).hexdigest

      record = {
        'schema_version' => 't8-runtime-capture-v1',
        'release_id' => 'next-from-8082541',
        'producer_sha' => PINNED_PRODUCER_SHA,
        'profile' => prof,
        'timestamp' => Time.now.utc.iso8601,
        'source_model_path' => 'C:/Models/TestHouse.skp',
        'source_model_bytes' => 1234567,
        'output_bomc_path' => bomc_file,
        'bomc_sha256' => bomc_sha,
        'bomc_bytes' => File.size(bomc_file),
        'package_sha256' => pkg_sha,
        'sketchup_version' => '26.0.483',
        'ruby_version' => 'ruby 3.2.2 (2023-03-30 revision e51014f9c0) [x64-mingw-ucrt]',
        'real_runtime_evidence' => true,
        'export_errors' => [],
        'timings' => {
          'total_wall_clock_ms' => 1250.5,
          'stage_timings' => {
            'SCAN_MODEL' => { 'duration_ms' => 120.0 },
            'SNAPSHOT_ENTITIES' => { 'duration_ms' => 450.0 },
            'WRITE_CONTAINER' => { 'duration_ms' => 680.5 }
          },
          'stage_timing_evidence' => 'complete'
        }
      }

      File.write(File.join(@temp_dir, "capture_#{prof}.json"), JSON.pretty_generate(record))
    end

    res = T8CaptureVerifier.verify(@temp_dir)
    assert_equal 'captured_pending_certification', res[:status]
    assert_equal false, res[:ready], 'Even complete capture set must NOT mark release ready (fail-closed)'
    assert res[:errors].empty?, "Expected zero errors, got: #{res[:errors].inspect}"
    assert_equal 3, res[:verified_captures].length
  end

  def test_verifier_fails_on_hash_mismatch_or_error
    require VERIFIER_PATH

    manifest = JSON.parse(File.read(MANIFEST_PATH))
    pkg_sha = manifest['package_sha256']

    bomc_file = File.join(@temp_dir, "Corrupt__E4__VISUAL.bomc")
    File.write(bomc_file, "BOMC_CORRUPT_CONTENT")

    # Record fake hash that doesn't match actual file
    record = {
      'schema_version' => 't8-runtime-capture-v1',
      'release_id' => 'next-from-8082541',
      'producer_sha' => PINNED_PRODUCER_SHA,
      'profile' => 'visual',
      'timestamp' => Time.now.utc.iso8601,
      'source_model_path' => 'C:/Models/TestHouse.skp',
      'output_bomc_path' => bomc_file,
      'bomc_sha256' => '0' * 64, # Mismatch!
      'package_sha256' => pkg_sha,
      'sketchup_version' => '26.0.483',
      'ruby_version' => 'ruby 3.2.2',
      'real_runtime_evidence' => true,
      'export_errors' => ['Simulated internal failure'],
      'timings' => { 'total_wall_clock_ms' => 500.0, 'stage_timing_evidence' => 'incomplete' }
    }
    File.write(File.join(@temp_dir, "capture_visual.json"), JSON.pretty_generate(record))

    res = T8CaptureVerifier.verify(@temp_dir)
    assert_equal 'failed', res[:status]
    assert_equal false, res[:ready]
    assert res[:errors].any? { |e| e.include?('BOMC SHA256 mismatch') }
    assert res[:errors].any? { |e| e.include?('Export errors recorded') }
  end
end
