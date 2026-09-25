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
  MENU_LAUNCHER_PATH = File.join(KIT_DIR, 'sibambo_t7_capture_launcher.rb')

  PINNED_PRODUCER_SHA = 'bd6782691ef8ba98f9d3baab698bc1cd961ce393'.freeze
  PINNED_CONSUMER_SHA = '4c927dfc4c38dea767ff8f7a3f796230e25c45bf'.freeze
  EXPECTED_SNAPSHOT_TREE_SHA256 = '703e65a95b459b852409abab50d53f7044c35f83a40a8ba48496c465786c0e6d'.freeze
  EXPECTED_LOADER_ID = 'bomc-next-v1'.freeze
  EXPECTED_PROFILE_CONTRACT_REVISION = 1

  def setup
    @temp_dir = Dir.mktmpdir('t8-test-capture')
  end

  # Runtime doubles exercise the runner, not just generated-source strings.
  # These tests never count as real SketchUp evidence.
  def with_capture_runtime(modified: false, model_name: 'Fixture.skp')
    require CAPTURE_SCRIPT_PATH
    source = File.join(@temp_dir, model_name)
    File.write(source, 'synthetic source')
    model = Struct.new(:path, :modified?).new(source, modified)
    sketchup = Module.new
    sketchup.define_singleton_method(:active_model) { model }
    sketchup.define_singleton_method(:version) { '26.0.test' }
    Object.const_set(:Sketchup, sketchup)
    exporter = Module.new
    bytes = build_synthetic_bomc_bytes('exact')
    exporter.define_singleton_method(:export) { |_model, output_path:, **_| File.binwrite(output_path, bytes) }
    engine = Module.new
    engine.const_set(:BOMCExtension, exporter)
    original = SibamboCaptureKit.method(:ensure_extension_loaded!)
    SibamboCaptureKit.define_singleton_method(:ensure_extension_loaded!) { engine }
    yield exporter, engine, model
  ensure
    SibamboCaptureKit.define_singleton_method(:ensure_extension_loaded!, original) if original
    Object.send(:remove_const, :Sketchup) if sketchup && Object.const_defined?(:Sketchup)
  end

  def test_runner_rejects_unsaved_edits
    with_capture_runtime(modified: true) do
      error = assert_raise(RuntimeError) { SibamboCaptureKit.export_profile(:visual, output_dir: @temp_dir) }
      assert_match(/Save the model/, error.message)
    end
  end

  def test_runner_preserves_existing_output
    with_capture_runtime do
      path = File.join(@temp_dir, 'Fixture__E4__VISUAL.bomc')
      File.write(path, 'old evidence')
      assert_raise(RuntimeError) { SibamboCaptureKit.export_profile(:visual, output_dir: @temp_dir) }
      assert_equal 'old evidence', File.read(path)
    end
  end

  def test_runner_does_not_claim_wrong_profile_as_success
    with_capture_runtime do
      record = SibamboCaptureKit.export_profile(:visual, output_dir: @temp_dir)
      assert_equal false, record['real_runtime_evidence']
      assert_equal 'failed', record['export_status']
      assert_match(/profile/, record['export_errors'].join)
    end
  end

  def test_runner_forwards_progress_to_cooperative_checkpoint
    with_capture_runtime do |exporter|
      bytes = build_synthetic_bomc_bytes('visual')
      exporter.define_singleton_method(:export) do |_model, output_path:, progress:, **_|
        progress.call(stage: :INITIALIZE, processed: 0, total: 20)
        progress.call(stage: :DONE, processed: 20, total: 20)
        File.binwrite(output_path, bytes)
      end
      events = []
      record = SibamboCaptureKit.export_profile(:visual, output_dir: @temp_dir, checkpoint: ->(event) { events << event })
      assert_equal 'success', record['export_status']
      assert_equal ['VISUAL: INITIALIZE', 'VISUAL: DONE'], events.map { |event| event[:stage] }
    end
  end

  def test_cancel_propagates_without_writing_false_capture_record
    with_capture_runtime do |exporter, engine|
      cancelled = Class.new(StandardError)
      conversion_job = Class.new
      conversion_job.const_set(:Cancelled, cancelled)
      engine.const_set(:ConversionJob, conversion_job)
      exporter.define_singleton_method(:export) do |_model, progress:, **_|
        progress.call(stage: :INITIALIZE, processed: 0, total: 20)
      end
      assert_raise(cancelled) do
        SibamboCaptureKit.export_profile(:visual, output_dir: @temp_dir, checkpoint: ->(_event) { raise cancelled })
      end
      assert_false File.exist?(File.join(@temp_dir, 'capture_visual.json'))
    end
  end

  def test_one_click_launcher_schedules_work_without_synchronous_export
    with_capture_runtime(model_name: 'RUMAH L.skp') do |exporter, engine|
      exporter.define_singleton_method(:export) { |_model, **_| raise 'export must not run on menu click' }
      job_class = Class.new do
        attr_reader :work
        def self.active
          nil
        end
        def self.start(title:, output_path:, batch_size:, &work)
          new(work)
        end
        def initialize(work)
          @work = work
        end
        def running?
          true
        end
      end
      engine.const_set(:ConversionJob, job_class)
      ui = Module.new
      ui.define_singleton_method(:start_timer) { |_interval, _repeat, &_block| 1 }
      Object.const_set(:UI, ui)
      begin
        job = SibamboCaptureKit.start_interactive
        assert_kind_of job_class, job
        assert_not_nil job.work
      ensure
        Object.send(:remove_const, :UI)
      end
    end
  end

  def test_loaded_candidate_commit_must_match
    require CAPTURE_SCRIPT_PATH
    engine = Module.new
    engine.const_set(:COMMIT_SHA, '0' * 40)
    error = assert_raise(RuntimeError) { SibamboCaptureKit.verify_engine_identity!(engine) }
    assert_match(/Loaded E4 commit differs/, error.message)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir) if @temp_dir && File.directory?(@temp_dir)
  end

  # SYNTHETIC TEST FIXTURE BUILDER
  # Generates valid minimal synthetic BOMC bytes containing Section 20 (Encoding Contract).
  # Used purely for unit testing parser/verifier behavior and does not represent real SketchUp runtime certification.
  def build_synthetic_bomc_bytes(profile)
    buf = String.new(encoding: 'ASCII-8BIT')
    # Header (32 bytes)
    buf << "BOMC\r\n\x1a\n"
    buf << [1, 2].pack('v2') # major: 1, minor: 2
    buf << [0x01020304].pack('V') # endian
    buf << [0].pack('V') # flags: standard directory
    buf << [1].pack('V') # section_count: 1
    buf << [32].pack('Q<') # directory_offset: 32

    # Directory entry at offset 32 (40 bytes standard)
    buf << [20].pack('v') # type: 20 (SECTION_ENCODING_CONTRACT)
    buf << [0].pack('C') # codec: 0 (STORE)
    buf << [0].pack('C') # flags: 0
    buf << [80].pack('Q<') # offset: 80
    buf << [76].pack('Q<') # stored_size: 76
    buf << [76].pack('Q<') # raw_size: 76
    buf << [1].pack('V') # count: 1
    buf << [0].pack('V') # crc32: 0
    buf << [0].pack('V') # reserved: 0
    # 32 + 40 = 72 bytes so far. Need 8 bytes of padding to reach offset 80:
    buf << ("\x00" * 8)

    # Section 20 data at offset 80 (76 bytes)
    prof_id = case profile.to_s.downcase
              when 'exact' then 1
              when 'research' then 2
              when 'visual' then 3
              else 0
              end
    buf << [1].pack('v') # schema_version: 1
    buf << [prof_id].pack('C') # profile_id
    buf << [1].pack('C') # texture_policy: pixel_lossless
    buf << ("\x00" * 68)
    buf << [EXPECTED_PROFILE_CONTRACT_REVISION].pack('V') # encoder revision at Section 20 offset 72
    buf
  end

  def test_manifest_metadata_and_provenance
    assert File.file?(MANIFEST_PATH), "Manifest must exist at #{MANIFEST_PATH}"
    manifest = JSON.parse(File.read(MANIFEST_PATH))

    assert_equal 't8-capture-manifest-v1', manifest['schema_version']
    assert_equal 'next-from-8082541', manifest['release_id']
    assert_equal PINNED_PRODUCER_SHA, manifest['producer_sha']
    assert_equal '8082541d852cd68b9874231e41c6b9c967c74d26', manifest['base_producer_sha']
    assert_equal PINNED_CONSUMER_SHA, manifest['consumer_sha']
    assert_equal EXPECTED_LOADER_ID, manifest['loader_id']
    assert_equal EXPECTED_PROFILE_CONTRACT_REVISION, manifest['profile_contract_revision']
    assert_equal %w[visual research exact], manifest['supported_profiles']
    assert_equal '1.0', manifest['builder_revision']
    assert_equal '1.0', manifest['transformer_revision']
    assert_equal EXPECTED_SNAPSHOT_TREE_SHA256, manifest['snapshot_tree_sha256']

    assert File.file?(PACKAGE_PATH), "Package must exist at #{PACKAGE_PATH}"
    actual_pkg_sha = Digest::SHA256.file(PACKAGE_PATH).hexdigest
    assert_equal actual_pkg_sha, manifest['package_sha256']
  end

  def test_one_click_menu_launcher_is_available_without_ruby_console
    assert File.file?(MENU_LAUNCHER_PATH)
    assert_nothing_raised { RubyVM::InstructionSequence.compile_file(MENU_LAUNCHER_PATH) }
    source = File.read(MENU_LAUNCHER_PATH)
    assert_include source, 'Sibambo E4 — Capture RUMAH L (3 profiles)'
    assert_include source, 'SibamboCaptureKit.start_interactive'
    assert_include File.read(OPERATOR_GUIDE_PATH), 'Ruby Console is not required'
  end

  def test_package_structure_and_isolation
    assert File.file?(PACKAGE_PATH)
    assert File.size(PACKAGE_PATH) > 500_000, 'Package should be around 1MB'

    # Check operator guide existence and required contents
    assert File.file?(OPERATOR_GUIDE_PATH)
    guide_content = File.read(OPERATOR_GUIDE_PATH)
    assert guide_content.include?('next-from-8082541')
    assert guide_content.include?('SibamboCaptureKit.start_interactive')
    assert guide_content.include?('Install Extension')
    assert guide_content.include?('Uninstall')
    assert guide_content.include?('captured_pending_certification')
    assert guide_content.include?('ready: false')
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
    assert script_src.include?('def self.start_interactive')
    assert script_src.include?('t8-runtime-capture-v1')
    assert script_src.include?('read_bomc_encoding_contract_profile')
    assert script_src.include?('EXPECTED_EXPORT_STAGES')
  end

  def test_verifier_marks_empty_results_as_incomplete
    assert File.file?(VERIFIER_PATH)
    require VERIFIER_PATH

    res = T8CaptureVerifier.verify(@temp_dir, skip_consumer_inspection: true)
    assert_equal 'incomplete', res[:status]
    assert_equal false, res[:ready]
    assert_equal %w[visual research exact], res[:missing_profiles]
    assert res[:errors].empty?
  end

  def test_verifier_validates_complete_capture_set_and_stays_not_ready
    require VERIFIER_PATH

    manifest = JSON.parse(File.read(MANIFEST_PATH))
    pkg_sha = manifest['package_sha256']
    consumer_sha = manifest['consumer_sha']
    source_model_sha = 'a' * 64

    # Generate synthetic captures for all 3 profiles with valid Section 20 BOMC fixtures
    %w[visual research exact].each do |prof|
      bomc_file = File.join(@temp_dir, "TestModel__E4__#{prof.upcase}.bomc")
      bomc_bytes = build_synthetic_bomc_bytes(prof)
      File.binwrite(bomc_file, bomc_bytes)
      bomc_sha = Digest::SHA256.file(bomc_file).hexdigest

      record = {
        'schema_version' => 't8-runtime-capture-v1',
        'release_id' => 'next-from-8082541',
        'producer_sha' => PINNED_PRODUCER_SHA,
        'consumer_sha' => consumer_sha,
        'loader_id' => EXPECTED_LOADER_ID,
        'profile_contract_revision' => EXPECTED_PROFILE_CONTRACT_REVISION,
        'package_sha256' => pkg_sha,
        'snapshot_tree_sha256' => EXPECTED_SNAPSHOT_TREE_SHA256,
        'profile' => prof,
        'actual_bomc_profile' => prof,
        'timestamp' => Time.now.utc.iso8601,
        'source_model_path' => 'C:/Models/TestHouse.skp',
        'source_model_bytes' => 1234567,
        'source_model_sha256' => source_model_sha,
        'output_bomc_path' => "TestModel__E4__#{prof.upcase}.bomc",
        'bomc_sha256' => bomc_sha,
        'bomc_bytes' => bomc_bytes.bytesize,
        'sketchup_version' => '26.0.483',
        'ruby_version' => 'ruby 3.2.2 (2023-03-30 revision e51014f9c0) [x64-mingw-ucrt]',
        'real_runtime_evidence' => true,
        'export_status' => 'success',
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

    res = T8CaptureVerifier.verify(@temp_dir, skip_consumer_inspection: true)
    assert_equal 'captured_pending_certification', res[:status]
    assert_equal false, res[:ready], 'Even complete capture set must NOT mark release ready (fail-closed)'
    assert res[:errors].empty?, "Expected zero errors, got: #{res[:errors].inspect}"
    assert_equal 3, res[:verified_captures].length
  end

  def test_verifier_fails_on_hash_mismatch_or_error
    require VERIFIER_PATH

    manifest = JSON.parse(File.read(MANIFEST_PATH))
    pkg_sha = manifest['package_sha256']
    bomc_file = File.join(@temp_dir, 'Corrupt__E4__VISUAL.bomc')
    File.binwrite(bomc_file, build_synthetic_bomc_bytes('visual'))

    # Record fake hash that doesn't match actual file
    record = {
      'schema_version' => 't8-runtime-capture-v1',
      'release_id' => 'next-from-8082541',
      'producer_sha' => PINNED_PRODUCER_SHA,
      'consumer_sha' => manifest['consumer_sha'],
      'loader_id' => EXPECTED_LOADER_ID,
      'profile_contract_revision' => EXPECTED_PROFILE_CONTRACT_REVISION,
      'package_sha256' => pkg_sha,
      'snapshot_tree_sha256' => EXPECTED_SNAPSHOT_TREE_SHA256,
      'profile' => 'visual',
      'actual_bomc_profile' => 'visual',
      'timestamp' => Time.now.utc.iso8601,
      'source_model_path' => 'C:/Models/TestHouse.skp',
      'source_model_bytes' => 1234567,
      'source_model_sha256' => 'a' * 64,
      'output_bomc_path' => 'Corrupt__E4__VISUAL.bomc',
      'bomc_sha256' => '0' * 64, # Mismatch!
      'bomc_bytes' => 156,
      'sketchup_version' => '26.0.483',
      'ruby_version' => 'ruby 3.2.2',
      'real_runtime_evidence' => true,
      'export_status' => 'failed',
      'export_errors' => ['Simulated internal failure'],
      'timings' => { 'total_wall_clock_ms' => 500.0, 'stage_timing_evidence' => 'incomplete' }
    }
    File.write(File.join(@temp_dir, 'capture_visual.json'), JSON.pretty_generate(record))

    res = T8CaptureVerifier.verify(@temp_dir, skip_consumer_inspection: true)
    assert_equal 'failed', res[:status]
    assert_equal false, res[:ready]
    assert res[:errors].any? { |e| e.include?('BOMC SHA256 mismatch') }
    assert res[:errors].any? { |e| e.include?('Export errors recorded') }
  end

  def test_verifier_rejects_section20_profile_and_revision_mismatch
    require VERIFIER_PATH

    manifest = JSON.parse(File.read(MANIFEST_PATH))
    bomc_file = File.join(@temp_dir, 'Mismatch__E4__VISUAL.bomc')
    # Build BOMC encoded as EXACT (prof_id 1) but claimed as VISUAL:
    bomc_bytes = build_synthetic_bomc_bytes('exact')
    bomc_bytes[-4, 4] = [99].pack('V') # forged encoder revision; metadata still claims pinned revision
    File.binwrite(bomc_file, bomc_bytes)
    bomc_sha = Digest::SHA256.file(bomc_file).hexdigest

    record = {
      'schema_version' => 't8-runtime-capture-v1',
      'release_id' => 'next-from-8082541',
      'producer_sha' => PINNED_PRODUCER_SHA,
      'consumer_sha' => manifest['consumer_sha'],
      'loader_id' => EXPECTED_LOADER_ID,
      'profile_contract_revision' => EXPECTED_PROFILE_CONTRACT_REVISION,
      'package_sha256' => manifest['package_sha256'],
      'snapshot_tree_sha256' => EXPECTED_SNAPSHOT_TREE_SHA256,
      'profile' => 'visual',
      'actual_bomc_profile' => 'exact',
      'timestamp' => Time.now.utc.iso8601,
      'source_model_path' => 'C:/Models/TestHouse.skp',
      'source_model_bytes' => 1234567,
      'source_model_sha256' => 'a' * 64,
      'output_bomc_path' => 'Mismatch__E4__VISUAL.bomc',
      'bomc_sha256' => bomc_sha,
      'bomc_bytes' => bomc_bytes.bytesize,
      'sketchup_version' => '26.0.483',
      'ruby_version' => 'ruby 3.2.2',
      'real_runtime_evidence' => true,
      'export_status' => 'success',
      'export_errors' => [],
      'timings' => { 'total_wall_clock_ms' => 500.0 }
    }
    File.write(File.join(@temp_dir, 'capture_visual.json'), JSON.pretty_generate(record))

    res = T8CaptureVerifier.verify(@temp_dir, skip_consumer_inspection: true)
    assert_equal 'failed', res[:status]
    assert res[:errors].any? { |e| e.include?('Profile mismatch with BOMC encoding contract') }
    assert res[:errors].any? { |e| e.include?('Profile contract revision mismatch in BOMC') }
  end

  def test_verifier_rejects_path_traversal_escape
    require VERIFIER_PATH

    manifest = JSON.parse(File.read(MANIFEST_PATH))
    record = {
      'schema_version' => 't8-runtime-capture-v1',
      'release_id' => 'next-from-8082541',
      'producer_sha' => PINNED_PRODUCER_SHA,
      'consumer_sha' => manifest['consumer_sha'],
      'loader_id' => EXPECTED_LOADER_ID,
      'profile_contract_revision' => EXPECTED_PROFILE_CONTRACT_REVISION,
      'package_sha256' => manifest['package_sha256'],
      'snapshot_tree_sha256' => EXPECTED_SNAPSHOT_TREE_SHA256,
      'profile' => 'visual',
      'timestamp' => Time.now.utc.iso8601,
      'source_model_path' => 'C:/Models/TestHouse.skp',
      'source_model_bytes' => 1234567,
      'source_model_sha256' => 'a' * 64,
      'output_bomc_path' => '../../../../etc/shadow.bomc',
      'bomc_sha256' => 'a' * 64,
      'bomc_bytes' => 100,
      'sketchup_version' => '26.0.483',
      'ruby_version' => 'ruby 3.2.2',
      'real_runtime_evidence' => true,
      'export_status' => 'success',
      'export_errors' => [],
      'timings' => { 'total_wall_clock_ms' => 500.0 }
    }
    File.write(File.join(@temp_dir, 'capture_visual.json'), JSON.pretty_generate(record))

    res = T8CaptureVerifier.verify(@temp_dir, skip_consumer_inspection: true)
    assert_equal 'failed', res[:status]
    assert res[:errors].any? { |e| e.include?('escapes results directory') }
  end

  def test_verifier_rejects_inconsistent_source_model_across_profiles
    require VERIFIER_PATH

    manifest = JSON.parse(File.read(MANIFEST_PATH))
    [
      ['visual', 'a' * 64],
      ['research', 'b' * 64]
    ].each do |prof, model_sha|
      bomc_file = File.join(@temp_dir, "House__E4__#{prof.upcase}.bomc")
      bomc_bytes = build_synthetic_bomc_bytes(prof)
      File.binwrite(bomc_file, bomc_bytes)
      bomc_sha = Digest::SHA256.file(bomc_file).hexdigest

      record = {
        'schema_version' => 't8-runtime-capture-v1',
        'release_id' => 'next-from-8082541',
        'producer_sha' => PINNED_PRODUCER_SHA,
        'consumer_sha' => manifest['consumer_sha'],
        'loader_id' => EXPECTED_LOADER_ID,
        'profile_contract_revision' => EXPECTED_PROFILE_CONTRACT_REVISION,
        'package_sha256' => manifest['package_sha256'],
        'snapshot_tree_sha256' => EXPECTED_SNAPSHOT_TREE_SHA256,
        'profile' => prof,
        'actual_bomc_profile' => prof,
        'timestamp' => Time.now.utc.iso8601,
        'source_model_path' => "C:/Models/House_#{prof}.skp",
        'source_model_bytes' => 1048576,
        'source_model_sha256' => model_sha,
        'output_bomc_path' => "House__E4__#{prof.upcase}.bomc",
        'bomc_sha256' => bomc_sha,
        'bomc_bytes' => bomc_bytes.bytesize,
        'sketchup_version' => '26.0.483',
        'ruby_version' => 'ruby 3.2.2',
        'real_runtime_evidence' => true,
        'export_status' => 'success',
        'export_errors' => [],
        'timings' => { 'total_wall_clock_ms' => 500.0 }
      }
      File.write(File.join(@temp_dir, "capture_#{prof}.json"), JSON.pretty_generate(record))
    end

    res = T8CaptureVerifier.verify(@temp_dir, skip_consumer_inspection: true)
    assert_equal 'failed', res[:status]
    assert res[:errors].any? { |e| e.include?('Inconsistent source model across profiles') }
  end

  def test_verifier_rejects_manifest_tuple_mismatches_and_malformed_fields
    require VERIFIER_PATH

    dummy_bomc = File.join(@temp_dir, 'House__E4__VISUAL.bomc')
    bomc_bytes = build_synthetic_bomc_bytes('visual')
    File.binwrite(dummy_bomc, bomc_bytes)
    bomc_sha = Digest::SHA256.file(dummy_bomc).hexdigest

    record = {
      'schema_version' => 't8-runtime-capture-v1',
      'release_id' => 'wrong-release-id',
      'producer_sha' => '0' * 40,
      'consumer_sha' => '1' * 40,
      'loader_id' => 'wrong-loader',
      'profile_contract_revision' => 99,
      'package_sha256' => '2' * 64,
      'snapshot_tree_sha256' => '3' * 64,
      'profile' => 'visual',
      'actual_bomc_profile' => 'visual',
      'timestamp' => 'not-a-valid-date',
      'source_model_path' => '',
      'source_model_bytes' => -5,
      'source_model_sha256' => 'not-hex',
      'output_bomc_path' => 'House__E4__VISUAL.bomc',
      'bomc_sha256' => bomc_sha,
      'bomc_bytes' => bomc_bytes.bytesize,
      'sketchup_version' => '',
      'ruby_version' => '',
      'real_runtime_evidence' => false,
      'export_status' => 'failed',
      'export_errors' => ['Fatal export crash'],
      'timings' => { 'total_wall_clock_ms' => -1 }
    }
    File.write(File.join(@temp_dir, 'capture_visual.json'), JSON.pretty_generate(record))

    res = T8CaptureVerifier.verify(@temp_dir, skip_consumer_inspection: true)
    assert_equal 'failed', res[:status]
    assert res[:errors].any? { |e| e.include?('Release ID mismatch') }
    assert res[:errors].any? { |e| e.include?('Producer SHA mismatch') }
    assert res[:errors].any? { |e| e.include?('Consumer SHA mismatch') }
    assert res[:errors].any? { |e| e.include?('Loader ID mismatch') }
    assert res[:errors].any? { |e| e.include?('Profile contract revision mismatch') }
    assert res[:errors].any? { |e| e.include?('Package SHA256 mismatch') }
    assert res[:errors].any? { |e| e.include?('Snapshot tree digest mismatch') }
    assert res[:errors].any? { |e| e.include?('source_model_bytes must be a positive integer') }
    assert res[:errors].any? { |e| e.include?('source_model_sha256 missing or not a 64-char hex string') }
    assert res[:errors].any? { |e| e.include?('real_runtime_evidence must be true') }
    assert res[:errors].any? { |e| e.include?('Export errors recorded in visual') }
  end

  def test_verifier_inspects_consumer_provenance
    require VERIFIER_PATH

    res = T8CaptureVerifier.inspect_consumer_provenance
    assert res[:available], 'Consumer provenance should be available'
    assert_match(/\A[0-9a-f]{40}\z/, res[:head_sha])
    assert [true, false].include?(res[:is_dirty])
    if res[:is_dirty]
      assert res[:requirement].include?('Consumer checkout is dirty')
    end
  end
end
