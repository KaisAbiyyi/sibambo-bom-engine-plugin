# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../../tools/history/build_adaptive_preview_kit'
require_relative '../../tools/history/adaptive_preview/capture'

class AdaptivePreviewKitTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('adaptive-preview-test-')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def synthetic_correspondence_graph
    { definitions: [
        { id: 'root', kind: 'root', source_identity: { guid: 'fixture' } },
        { id: 'component', kind: 'component_definition', source_identity: { persistent_id: '10' } }
      ],
      nodes: [
        { kind: 'root', source_identity: { guid: 'fixture' } },
        { kind: 'component_instance', source_identity: { persistent_id: '11' } }
      ],
      meshes: [{ definition_id: 'root', faces: [{ source_identity: { persistent_id: '12' } }] }] }
  end

  def test_runtime_inventory_uses_current_bytes_and_excludes_development_artifacts
    root = File.join(@tmp, 'repo')
    %w[bom_engine/tests bom_engine/tools bom_engine/bin].each { |p| FileUtils.mkdir_p(File.join(root, p)) }
    File.write(File.join(root, 'bom_engine/core.rb'), 'local uncommitted fix')
    File.write(File.join(root, 'bom_engine/tests/test_a.rb'), 'test')
    File.write(File.join(root, 'bom_engine/tools/tool.rb'), 'tool')
    File.write(File.join(root, 'bom_engine/bin/encoder.exe'), 'binary')
    files = AdaptivePreviewKit.runtime_files(root)
    assert_equal %w[bom_engine/bin/encoder.exe bom_engine/core.rb], files.keys.sort
    assert_equal Digest::SHA256.hexdigest('local uncommitted fix'), files['bom_engine/core.rb']
    before = AdaptivePreviewKit.inventory_digest(files)
    File.write(File.join(root, 'bom_engine/core.rb'), 'second local fix')
    refute_equal before, AdaptivePreviewKit.inventory_digest(AdaptivePreviewKit.runtime_files(root))
  end

  def test_namespace_isolation_preserves_bomc_extension
    code = "module BOMEngine\n  X = BOMEngine::Thing\n  EXT = '.bomc'\nend\n"
    result = AdaptivePreviewKit.transform(code, 'Adaptive_abc123')
    assert_includes result, 'module Adaptive_abc123'
    assert_includes result, 'SibamboHistory::Adaptive_abc123::Thing'
    assert_includes result, "EXT = '.bomc'"
    refute_match(/\bBOMEngine\b/, result)
  end

  def test_failure_diagnostics_survive_json_serialization
    error = Class.new(StandardError) do
      def texture_diagnostics; [{ material: 'roof', attempts: [{ accepted: false, psnr: nil }] }]; end
      def hard_budget_bytes; 123; end
    end.new('over budget')
    data = JSON.parse(JSON.generate(AdaptivePreviewCapture.error_details(error)))
    assert_equal 'roof', data['texture_diagnostics'][0]['material']
    assert_equal 123, data['hard_budget_bytes']
    assert_equal 'over budget', data['message']
  end

  def test_exact_correspondence_sidecar_binds_source_ids_to_output_order
    graph = {
      definitions: [{ id: 'definition:root', kind: 'root', source_identity: { guid: 'model' } },
                    { id: 'definition:7', kind: 'component_definition', source_identity: { persistent_id: '7' } }],
      nodes: [{ kind: 'root', source_identity: { guid: 'model' } },
              { kind: 'component_instance', source_identity: { persistent_id: '42' } }],
      meshes: [{ definition_id: 'definition:root', faces: [{ source_identity: { persistent_id: '99' } }] }]
    }
    path = File.join(@tmp, 'exact-correspondence.json')
    identity = AdaptivePreviewCapture.write_source_correspondence(path, graph,
      source_sha256: 'a' * 64, bomc_sha256: 'b' * 64)
    saved = JSON.parse(File.read(path))
    assert_equal 'bomc-source-correspondence-v1', saved['schema']
    assert_equal false, saved['ready']
    assert_equal 'a' * 64, saved['source_sha256']
    assert_equal 'b' * 64, saved['bomc_sha256']
    assert_equal [{ 'index' => 0, 'source_id' => nil, 'kind' => 'root' },
                  { 'index' => 1, 'source_id' => '42', 'kind' => 'component_instance' }], saved['instances']
    assert_equal [{ 'index' => 0, 'source_id' => 'root', 'kind' => 'root' },
                  { 'index' => 1, 'source_id' => '7', 'kind' => 'component_definition' }], saved['definitions']
    assert_equal [{ 'mesh' => 0, 'face' => 0, 'definition' => 0, 'source_id' => '99' }], saved['faces']
    assert_equal Digest::SHA256.file(path).hexdigest, identity['sha256']
    assert_raises(Errno::EEXIST) do
      AdaptivePreviewCapture.write_source_correspondence(path, graph,
        source_sha256: 'a' * 64, bomc_sha256: 'b' * 64)
    end
    graph[:meshes][0][:faces][0][:source_identity] = {}
    assert_raises(RuntimeError) do
      AdaptivePreviewCapture.write_source_correspondence(File.join(@tmp, 'invalid-correspondence.json'), graph,
        source_sha256: 'a' * 64, bomc_sha256: 'b' * 64)
    end
  end

  def test_session_reservations_never_reuse_existing_evidence
    first = AdaptivePreviewCapture.reserve_session(@tmp)
    File.write(File.join(first, 'capture.json'), 'original')
    second = AdaptivePreviewCapture.reserve_session(@tmp)
    refute_equal first, second
    assert_equal 'original', File.read(File.join(first, 'capture.json'))
  end

  def test_operator_guide_never_prompts_heavy_capture_before_small_audit
    jobs = [
      { 'id' => '1-tiny', 'category' => 'tiny', 'source' => { 'path' => 'tiny.skp' } },
      { 'id' => '2-small-textured', 'category' => 'small-textured', 'source' => { 'path' => 'house2.skp' } },
      { 'id' => '3-medium-architectural', 'category' => 'medium-architectural', 'source' => { 'path' => 'presentation20.skp' } },
      { 'id' => '5-texture-heavy', 'category' => 'texture-heavy', 'source' => { 'path' => 'RUMAH Y.skp' } }
    ]
    step = AdaptivePreviewKit.next_operator_step(jobs)
    assert_includes step, 'house2.skp'
    assert_includes step, 'presentation20.skp'
    refute_includes step, 'RUMAH Y.skp'
    assert_includes step, 'Send all successful result folders together'
    assert_includes step, 'Do not run texture-heavy'
  end

  def test_failed_export_records_diagnostics_and_never_claims_runtime_success
    model = Struct.new(:path).new(File.join(@tmp, 'fixture.skp'))
    File.write(model.path, 'saved source')
    exporter = Object.new
    exporter.define_singleton_method(:export) do |*args, **opts|
      raise Class.new(StandardError) { def texture_diagnostics; [{ reason: 'quality_floor' }]; end }.new('gate failed')
    end
    engine = Module.new
    engine.const_set(:BOMCExtension, exporter)
    record = AdaptivePreviewCapture.export_profile(engine, model, :research, @tmp, {}, ->(_) {})
    assert_equal 'failed', record['export_status']
    assert_equal false, record['real_runtime_evidence']
    assert_equal false, record['ready']
    saved = JSON.parse(File.read(File.join(@tmp, 'capture_research.json')))
    assert_equal 'quality_floor', saved['error']['texture_diagnostics'][0]['reason']
    assert_raises(RuntimeError) { AdaptivePreviewCapture.export_profile(engine, model, :research, @tmp, {}, ->(_) {}) }
  end

  def test_existing_output_is_rejected_before_any_build
    assert_raises(ArgumentError) { AdaptivePreviewKit.build(output: @tmp, matrix_index: 'absent') }
    assert_empty Dir.children(@tmp)
  end

  def test_failed_preflight_writes_reason_and_aborts_before_capture
    require_relative '../../bom_engine/bomc_texture_encoder'
    engine = Module.new
    engine.const_set(:BOMCTextureEncoder, BOMEngine::BOMCTextureEncoder)
    old_path = BOMEngine::BOMCTextureEncoder.configured_binary_path
    BOMEngine::BOMCTextureEncoder.configured_binary_path = '/missing/cwebp'
    report_path = File.join(@tmp, 'preflight.json')
    assert_respond_to AdaptivePreviewCapture, :run_preflight!
    assert_raises(RuntimeError) { AdaptivePreviewCapture.run_preflight!(engine, report_path) }
    report = JSON.parse(File.read(report_path))
    assert_equal false, report['success']
    assert_equal false, report['ready']
    assert_equal 'binary_not_found', report.dig('capabilities', 'status')
    assert_empty Dir.glob(File.join(@tmp, '*.bomc'))
  ensure
    BOMEngine::BOMCTextureEncoder.configured_binary_path = old_path
  end

  def test_model_guard_rejects_wrong_modified_and_changed_sources
    path = File.join(@tmp, 'source.skp')
    File.write(path, 'original')
    model_type = Struct.new(:path, :changed) { def modified?; changed; end }
    model = model_type.new(path, false)
    source = { 'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest }
    assert AdaptivePreviewCapture.validate_model!(model, source)
    model.changed = true
    assert_raises(RuntimeError) { AdaptivePreviewCapture.validate_model!(model, source) }
    model.changed = false
    other = File.join(@tmp, 'other.skp')
    File.write(other, 'original')
    model.path = other
    assert_raises(RuntimeError) { AdaptivePreviewCapture.validate_model!(model, source) }
    model.path = path
    File.write(path, 'changed')
    assert_raises(RuntimeError) { AdaptivePreviewCapture.validate_model!(model, source) }
  end

  def test_real_contract_success_wrong_profile_and_smoke_tamper_detection
    require_relative '../../bom_engine/bomc_writer'
    graph = JSON.parse(File.read(File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)), symbolize_names: true)
    model = Struct.new(:path).new(File.join(@tmp, 'source.skp'))
    File.write(model.path, 'source')
    exporter = Object.new
    fixture_correspondence = synthetic_correspondence_graph
    exporter.define_singleton_method(:export) do |*args, **opts|
      bytes = BOMEngine::BOMCWriter.pack(graph, profile: opts[:profile])[:bytes]
      File.binwrite(opts[:output_path], bytes)
      opts[:diagnostics][:graph] = fixture_correspondence.merge(
        materials: [{ name: 'lossless', texture: { encoding_evidence: { staging: { psnr: Float::INFINITY } } } }])
    end
    engine = Module.new
    engine.const_set(:BOMCExtension, exporter)
    session = AdaptivePreviewCapture.reserve_session(File.join(@tmp, 'results/1-tiny'))
    identity = { 'preview_build_sha256' => 'test-build', 'profile_contract_revision' => 1 }
    AdaptivePreviewCapture::PROFILES.each do |profile|
      record = AdaptivePreviewCapture.export_profile(engine, model, profile, session, identity, ->(_) {})
      assert_equal 'success', record['export_status']
      assert_equal false, record['ready']
      assert_equal profile, AdaptivePreviewCapture.read_contract(File.join(session, "#{profile}.bomc"))['profile']
      assert File.file?(record.dig('source_correspondence', 'path')) if profile == 'exact'
    end
    File.write(File.join(session, 'session-status.json'), JSON.generate(identity.merge('status' => 'captured_pending_certification')))
    manifest = identity.merge('jobs' => [{ 'id' => '1-tiny', 'category' => 'tiny', 'source' => { 'sha256' => Digest::SHA256.file(model.path).hexdigest } }])
    assert AdaptivePreviewCapture.smoke_passed?(@tmp, manifest)
    File.binwrite(File.join(session, 'research.bomc'), 'tampered')
    refute AdaptivePreviewCapture.smoke_passed?(@tmp, manifest)
    wrong = File.join(@tmp, 'wrong')
    Dir.mkdir(wrong)
    mismatch = AdaptivePreviewCapture.export_profile(engine, model, :exact, wrong, identity.merge('profile_contract_revision' => 999), ->(_) {})
    assert_equal 'failed', mismatch['export_status']
    assert_equal false, mismatch['real_runtime_evidence']
  end

  def test_capture_contract_rejects_duplicate_section_even_when_first_is_valid
    require_relative '../../bom_engine/bomc_writer'
    graph = JSON.parse(File.read(File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)), symbolize_names: true)
    bytes = BOMEngine::BOMCWriter.pack(graph, profile: :exact)[:bytes].dup
    _magic, _major, _minor, _endian, flags, count, offset = bytes.byteslice(0, 32).unpack('a8vvVVVQ<')
    width = flags & 0x10 == 0x10 ? 24 : 40
    entries = bytes.byteslice(offset, count * width)
    contract = count.times.map { |i| entries.byteslice(i * width, width) }.find { |entry| entry.unpack1('v') == 20 }
    refute_nil contract
    new_offset = bytes.bytesize
    bytes << entries << contract
    bytes[20, 4] = [count + 1].pack('V')
    bytes[24, 8] = [new_offset].pack('Q<')
    path = File.join(@tmp, 'duplicate-contract.bomc')
    File.binwrite(path, bytes)
    assert_raises(RuntimeError) { AdaptivePreviewCapture.read_contract(path) }
  end

  def test_full_build_pins_source_and_installed_bytes_without_touching_existing_kits
    source = File.join(@tmp, 'fixture.skp')
    File.write(source, 'fake saved model for packaging only')
    index = File.join(@tmp, 'index.json')
    File.write(index, JSON.generate('jobs' => [{ 'id' => '1-tiny', 'category' => 'tiny',
      'source' => { 'path' => source, 'sha256' => Digest::SHA256.file(source).hexdigest } }]))
    output = File.join(@tmp, 'new-kit')
    manifest = AdaptivePreviewKit.build(output: output, matrix_index: index)
    assert_equal false, manifest['ready']
    assert_equal true, manifest['provisional']
    refute manifest.key?('producer_sha'), 'dirty source must not masquerade as its base SHA'
    assert_equal AdaptivePreviewKit.runtime_files(AdaptivePreviewKit::ROOT), manifest['source_files']
    assert_equal Digest::SHA256.file(File.join(output, manifest['package'])).hexdigest, manifest['package_sha256']
    manifest['installed_files'].each do |relative, sha|
      assert_equal sha, Digest::SHA256.file(File.join(output, 'install', relative)).hexdigest
    end
    exporter = File.join(output, 'install', manifest['folder'], 'bom_engine/bomc_extension.rb')
    code = "require #{exporter.inspect}; abort 'wrong policy' unless SibamboHistory::#{manifest['namespace']}::BOMCTextureOptimizer::POLICY_REVISION == 'adaptive-texture-3'"
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', code)
    assert status.success?, "Staged exporter load failed: #{stdout} #{stderr}"
    entry = File.join(output, 'install', manifest['folder'], 'entry.rb')
    menu_probe = <<~'RUBY'
      require 'json'
      $LOADED_FEATURES << 'sketchup.rb'
      module UI
        class Menu
          attr_reader :items
          def initialize; @items = []; end
          def add_submenu(name); @name = name; self; end
          def add_item(name); @items << name; end
        end
        def self.menu(_name); @menu ||= Menu.new; end
        def self.items; @menu.items; end
      end
      load ARGV.fetch(0)
      puts JSON.generate(UI.items)
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', menu_probe, entry)
    assert status.success?, "Staged menu load failed: #{stdout} #{stderr}"
    assert_equal 2, JSON.parse(stdout).length
    assert_raises(ArgumentError) { AdaptivePreviewKit.build(output: output, matrix_index: index) }
  end

  def test_jcm_capture_enables_experimental_codec_only_for_exact_and_checks_loader
    require_relative '../../bom_engine/bomc_writer'
    graph = JSON.parse(File.read(File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)), symbolize_names: true)
    model = Struct.new(:path).new(File.join(@tmp, 'saved.skp'))
    File.write(model.path, 'saved source')
    calls = []
    exporter = Object.new
    fixture_correspondence = synthetic_correspondence_graph
    exporter.define_singleton_method(:export) do |*args, **opts|
      calls << [opts[:profile], opts[:allow_jpeg_color_map], opts[:prepared_color_maps]]
      bytes = BOMEngine::BOMCWriter.pack(graph, profile: opts[:profile])[:bytes]
      File.binwrite(opts[:output_path], bytes)
      opts[:diagnostics][:graph] = fixture_correspondence
      opts[:profile] == :exact ? {required_loader: 'bomc-next-jcm-v1'} : {}
    end
    engine = Module.new
    engine.const_set(:BOMCExtension, exporter)
    identity = {'profile_contract_revision' => 1, 'loader_id' => 'bomc-next-jcm-v1'}
    prepared = Object.new
    visual = AdaptivePreviewCapture.export_profile(engine, model, :visual, @tmp, identity, ->(_) {},
      jcm_matrix: true, prepared_color_maps: prepared)
    exact = AdaptivePreviewCapture.export_profile(engine, model, :exact, @tmp, identity, ->(_) {},
      jcm_matrix: true, prepared_color_maps: prepared)
    assert_equal 'success', visual['export_status']
    assert_equal 'success', exact['export_status']
    assert_equal [[:visual, false, nil], [:exact, true, prepared]], calls
    assert_equal 'bomc-next-jcm-v1', exact['actual_required_loader']
    assert_equal false, exact['ready']
  end

  def test_profile_export_passes_one_scoped_candidate_cache_to_engine
    require_relative '../../bom_engine/bomc_writer'
    graph = JSON.parse(File.read(File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)), symbolize_names: true)
    model = Struct.new(:path).new(File.join(@tmp, 'saved.skp'))
    File.write(model.path, 'saved source')
    received_cache = nil
    received_processing = nil
    exporter = Object.new
    exporter.define_singleton_method(:export) do |*args, **opts|
      received_cache = opts[:candidate_cache]
      received_processing = opts[:settings]
      File.binwrite(opts[:output_path], BOMEngine::BOMCWriter.pack(graph, profile: opts[:profile])[:bytes])
      {}
    end
    engine = Module.new
    engine.const_set(:BOMCExtension, exporter)
    cache = { directory: File.join(@tmp, 'candidate-cache'), entries: {}, hits: 0 }
    Dir.mkdir(cache[:directory])
    record = nil
    processing = { mode: :custom, max_items: 8192, max_items_limit: 8192, min_items: 1, max_ms: 60.0 }
    argument_error = nil
    begin
      record = AdaptivePreviewCapture.export_profile(engine, model, :visual, @tmp,
        { 'profile_contract_revision' => 1 }, ->(_) {}, candidate_cache: cache, processing: processing)
    rescue ArgumentError => error
      argument_error = error
    end
    assert_nil argument_error
    assert_same cache, received_cache
    assert_same processing, received_processing
    assert_equal 'success', record['export_status']
  end

  def test_scoped_candidate_cache_is_fresh_and_cleaned_after_capture
    cache_path = nil
    error = nil
    begin
      AdaptivePreviewCapture.with_candidate_cache do |cache|
        cache_path = cache.fetch(:directory)
        assert File.directory?(cache_path)
        assert_equal({}, cache.fetch(:entries))
        assert_equal 0, cache.fetch(:hits)
      end
    rescue NoMethodError => caught
      error = caught
    end
    assert_nil error
    refute File.exist?(cache_path)
  end

  def test_jcm_capture_rejects_an_export_that_does_not_declare_the_jcm_loader
    require_relative '../../bom_engine/bomc_writer'
    graph = JSON.parse(File.read(File.expand_path('../../examples/model-eval-json-v1-small.json', __dir__)), symbolize_names: true)
    model = Struct.new(:path).new(File.join(@tmp, 'saved.skp'))
    File.write(model.path, 'saved source')
    exporter = Object.new
    exporter.define_singleton_method(:export) do |*args, **opts|
      File.binwrite(opts[:output_path], BOMEngine::BOMCWriter.pack(graph, profile: opts[:profile])[:bytes])
      {required_loader: 'bomc-next-v1'}
    end
    engine = Module.new
    engine.const_set(:BOMCExtension, exporter)
    record = AdaptivePreviewCapture.export_profile(engine, model, :exact, @tmp,
      {'profile_contract_revision' => 1, 'loader_id' => 'bomc-next-jcm-v1'}, ->(_) {}, jcm_matrix: true)
    assert_equal 'failed', record['export_status']
    assert_equal false, record['real_runtime_evidence']
    assert_match(/loader/i, record.dig('error', 'message'))
  end

  def test_jcm_preview_build_declares_a_distinct_loader_and_never_marks_ready
    source = File.join(@tmp, 'fixture.skp')
    File.write(source, 'saved tiny fixture')
    index = File.join(@tmp, 'index.json')
    File.write(index, JSON.generate('jobs' => [{ 'id' => '1-tiny', 'category' => 'tiny',
      'source' => { 'path' => source, 'sha256' => Digest::SHA256.file(source).hexdigest } }]))
    output = File.join(@tmp, 'jcm-kit')
    manifest = AdaptivePreviewKit.build(output: output, matrix_index: index, jcm_matrix: true)
    assert_equal 'bomc-next-jcm-v1', manifest['loader_id']
    assert_equal true, manifest['jcm_matrix']
    assert_equal false, manifest['ready']
    assert_match(/jcm/, manifest['package'])
    assert_includes File.read(File.join(output, 'OPERATOR_GUIDE.md')), 'JCM'
  end

  def test_source_byte_count_mismatch_fails_before_creating_a_kit
    source = File.join(@tmp, 'fixture.skp')
    File.write(source, 'saved tiny fixture')
    index = File.join(@tmp, 'index.json')
    File.write(index, JSON.generate('jobs' => [{ 'id' => '1-tiny', 'category' => 'tiny',
      'source' => { 'path' => source, 'sha256' => Digest::SHA256.file(source).hexdigest,
        'bytes' => File.size(source) + 1 } }]))
    output = File.join(@tmp, 'wrong-size-kit')
    error = assert_raises(RuntimeError) do
      AdaptivePreviewKit.build(output: output, matrix_index: index, jcm_matrix: true)
    end
    assert_match(/byte count/i, error.message)
    refute File.exist?(output)
  end

  def test_prepared_jcm_maps_must_match_a_pinned_matrix_source_before_output_is_created
    offline = 'D:/projects/sibambo/scratch/exact-jcm-pixels-20260922-01/results/offline-20260922T131415-9e2eb88a/report.json'
    browser = 'D:/projects/sibambo/scratch/exact-jcm-pixels-20260922-01/results/offline-20260922T131415-9e2eb88a/browser-verification-60HNnv/report.json'
    skip 'Real prepared-map evidence unavailable on this host' unless File.file?(offline) && File.file?(browser)
    source = File.join(@tmp, 'wrong.skp')
    File.write(source, 'unrelated saved model')
    index = File.join(@tmp, 'index.json')
    File.write(index, JSON.generate('jobs' => [{ 'id' => '1-tiny', 'category' => 'tiny',
      'source' => { 'path' => source, 'sha256' => Digest::SHA256.file(source).hexdigest } }]))
    output = File.join(@tmp, 'must-not-exist')
    error = assert_raises(ArgumentError) do
      AdaptivePreviewKit.build(output: output, matrix_index: index, jcm_matrix: true,
        prepared_maps: {offline_report: offline, browser_report: browser})
    end
    assert_match(/prepared.*source/i, error.message)
    refute File.exist?(output)
  end

  def test_prepared_maps_are_loaded_only_for_the_matching_source
    offline = 'D:/projects/sibambo/scratch/exact-jcm-pixels-20260922-01/results/offline-20260922T131415-9e2eb88a/report.json'
    browser = 'D:/projects/sibambo/scratch/exact-jcm-pixels-20260922-01/results/offline-20260922T131415-9e2eb88a/browser-verification-60HNnv/report.json'
    skip 'Real prepared-map evidence unavailable on this host' unless File.file?(offline) && File.file?(browser)
    require_relative '../../bom_engine/bomc_prepared_color_maps'
    engine = Module.new
    engine.const_set(:BOMCPreparedColorMaps, BOMEngine::BOMCPreparedColorMaps)
    source_sha = '5291179e1f4eac5ebf6b5eedc66135469a913f8df6a6d5a28238f497c75af119'
    manifest = { 'jcm_matrix' => true, 'prepared_maps' => {
      'offline_report' => offline, 'browser_report' => browser, 'source_sha256' => source_sha } }
    tiny = {'source' => {'sha256' => '1' * 64}}
    texture_heavy = {'source' => {'sha256' => source_sha}}
    assert_nil AdaptivePreviewCapture.prepared_for_job(manifest, tiny, engine)
    assert_instance_of BOMEngine::BOMCPreparedColorMaps,
      AdaptivePreviewCapture.prepared_for_job(manifest, texture_heavy, engine)
  end
end
