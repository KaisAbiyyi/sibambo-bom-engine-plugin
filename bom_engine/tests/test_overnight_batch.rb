require 'minitest/autorun'
require 'tmpdir'
require_relative '../bomc_extension'
require_relative '../evolution_exporter'
require_relative '../overnight_batch'
MB_OK = 0 unless defined?(MB_OK)

class TestOvernightBatch < Minitest::Test
  B = BOMEngine::OvernightBatch
  class Host
    attr_accessor :failure, :dirty, :hook
    attr_reader :exports, :opens
    def initialize
      @exports = []; @opens = []
    end
    def runtime
      { 'files_sha256' => 'a' * 64, 'sketchup_version' => '2026' }
    end
    def safe_to_switch?; !dirty; end
    def safe_after_failure?(_); !dirty; end
    def free_bytes(_); 10**12; end
    def open(path)
      raise B::Unsafe, 'dirty host' if dirty
      @opens << path
      raise 'open failure' if failure == :open
      path
    end
    def export(model, path, profile)
      @exports << [model, path, profile]
      yield(stage: :SCAN_MODEL)
      @hook.call if @hook
      raise 'injected export failure' if failure == :export
      contract = BOMEngine::BOMCEncodingContract.encode(profile, source_skp_bytes: File.size(model))
      bytes = BOMEngine::BOMC::Container.pack([{type: 20, bytes: contract}])
      File.binwrite(path, bytes)
      artifact = B.fingerprint(path)
      trace = {schema: 'sibambo-performance-trace-v1', status: 'success', total_wall_ms: 12,
        metadata: {engine: 'e4', profile: profile, format: 'bomc-1.2',
          producer_source_sha256: 'unavailable', source: B.fingerprint(model), artifact: artifact}, stages: []}
      BOMEngine::PerformanceTrace.write_receipt("#{path}.performance.json", trace)
      yield(stage: :DONE)
      {path: path, validation: {report: {passed: true, profile: profile}}}
    end
    def validate(path, profile); B::Store.new.check_bomc_profile(path, profile); end
  end

  def setup
    @dir = Dir.mktmpdir('batch-', ENV.fetch('TEMP'))
    @src = File.join(@dir, 'sources'); @out = File.join(@dir, 'runs')
    FileUtils.mkdir_p(File.join(@src, 'nested'))
    File.binwrite(File.join(@src, 'same.skp'), 'source-one' * 100)
    File.binwrite(File.join(@src, 'nested', 'same.SKP'), 'source-two' * 100)
    @catalog = B::Catalog.new(@src, output_root: @out)
    @store = B::Store.new(root: @out); @host = Host.new
  end
  def teardown
    @queue.close if @queue && @queue.respond_to?(:close)
    FileUtils.remove_entry(@dir)
  end
  def create(selected: ['same.skp'], profiles: %w[exact visual], stop: false)
    @store.create(catalog: @catalog, selected: selected, profiles: profiles,
      runtime: @host.runtime, stop_on_error: stop, free_bytes: 10**12)
  end
  def queue(run)
    @queue = B::Queue.new(store: @store, catalog: @catalog, run: run, host: @host)
    @queue.resume
    @queue
  end
  def drain(q)
    100.times do
      q.step
      return unless q.run['status'] == 'running'
    end
    flunk 'queue did not finish'
  end
  def test_recursive_catalog_has_relative_names_and_distinct_keys
    rows = @catalog.scan
    assert_equal ['nested/same.SKP', 'same.skp'], rows.map { |r| r['relative'] }
    assert_equal 2, rows.map { |r| r['key'] }.uniq.size
  end
  def test_selected_subset_and_default_profile_order_leave_source_immutable
    before = @catalog.scan
    q = queue(create)
    drain(q)
    assert_equal 'complete', q.run['status']
    assert_equal %w[exact visual], @host.exports.map(&:last)
    assert_equal before, @catalog.scan
    assert_equal 2, q.counts['completed']
  end
  def test_cancel_between_profiles_preserves_success_and_repeated_resume_does_not_duplicate
    q = queue(create); q.step; q.cancel; q.step
    assert_equal 'cancelled', q.run['status']
    assert_equal 1, q.counts['completed']
    original = q.run['models'][0]['profiles']['exact']['path']
    receipt = File.binread("#{original}.performance.json")
    q.resume; drain(q); q.resume; drain(q)
    assert_equal %w[exact visual], @host.exports.map(&:last)
    assert_equal receipt, File.binread("#{original}.performance.json")
  end
  def test_cancel_cooperative_checkpoint_unwinds_without_success
    q = queue(create)
    fiber = Fiber.new { q.step { Fiber.yield } }
    fiber.resume; q.cancel
    fiber.resume while fiber.alive?
    assert_equal 'cancelled', q.run['status']
    assert_equal 0, q.counts['completed']
    assert_empty @host.opens
  end
  def test_cancel_noninterruptible_publication_keeps_completed_profile
    q = queue(create)
    @host.hook = -> { q.cancel }
    q.step
    assert_equal 'cancelled', q.run['status']
    assert_equal 1, q.counts['completed']
    assert_equal ['exact'], @host.exports.map(&:last)
  end
  def test_reuse_both_then_only_missing_profile
    q = queue(create); drain(q)
    run = create
    assert_equal %w[reused reused], run['models'][0]['profiles'].values.map { |r| r['status'] }
    File.binwrite(q.run['models'][0]['profiles']['visual']['path'], 'corrupt')
    run = create
    assert_equal 'reused', run['models'][0]['profiles']['exact']['status']
    assert_equal 'pending', run['models'][0]['profiles']['visual']['status']
    assert_equal 'needs_verification', run['models'][0]['profiles']['visual']['reuse_reason']
  end
  def test_changed_source_never_reuses_or_resumes
    q = queue(create); drain(q)
    File.binwrite(File.join(@src, 'same.skp'), 'changed')
    assert_raises(B::Unsafe) { q.resume }
    assert_equal 'pending', create['models'][0]['profiles']['exact']['status']
  end
  def test_single_profile_matrix
    %w[exact visual].each do |profile|
      q = queue(create(profiles: [profile])); drain(q)
      assert_equal [profile], q.run['models'][0]['profiles'].keys
      assert_equal 'complete', q.run['status']
    end
  end
  def test_continued_failure_cannot_report_complete_with_pending_work
    q = queue(create(selected: ['same.skp', 'nested/same.SKP']))
    @host.failure = :export; q.step; @host.failure = nil; drain(q)
    refute_equal 'complete', q.run['status']
    assert_equal 1, q.counts['failed']
    assert_operator q.counts['pending'], :>, 0
    assert_equal 2, q.counts['completed']
  end
  def test_dirty_host_pauses_and_stop_on_error_pauses
    q = queue(create); @host.dirty = true; q.step
    assert_equal 'paused', q.run['status']; assert_empty @host.exports
    @host.dirty = false; q.close
    q = queue(create(stop: true)); @host.failure = :export; q.step
    assert_equal 'paused', q.run['status']
  end
  def test_crash_recovery_uses_new_attempt_and_keeps_previous_success
    q = queue(create); q.step
    run = q.run; record = run['models'][0]['profiles']['visual']
    record['status'] = 'in_progress'; run['status'] = 'running'
    @store.save(run); q.close
    q = queue(@store.load(run['run_id'])); drain(q)
    assert_equal 2, q.counts['completed']
    assert_equal %w[exact visual], @host.exports.map(&:last)
  end
  def test_exclusive_run_writer
    q = queue(create)
    assert_raises(B::Unsafe) { B::Queue.new(store: @store, catalog: @catalog, run: @store.load(q.run['run_id']), host: @host) }
  end
  def test_invalid_selection_paths_and_disk_fail_closed
    assert_raises(B::Unsafe) { create(selected: ['../escape.skp']) }
    assert_raises(B::Unsafe) { create(selected: ['same.skp', 'same.skp']) }
    assert_raises(B::Unsafe) { create(profiles: ['research']) }
    assert_raises(B::Unsafe) { @store.create(catalog: @catalog, selected: ['same.skp'], profiles: ['exact'], runtime: @host.runtime, stop_on_error: false, free_bytes: 0) }
  end
  def test_bounded_bomc_profile_check_does_not_binread_file
    q = queue(create(profiles: ['visual'])); drain(q)
    path = q.run['models'][0]['profiles']['visual']['path']
    File.stub(:binread, ->(*) { flunk 'entire-file read' }) do
      assert @store.check_bomc_profile(path, 'visual')
      refute @store.check_bomc_profile(path, 'exact')
    end
  end
  def test_validation_sidecar_allows_commit_recovery_without_duplicate_export
    q = queue(create(profiles: ['exact'])); q.step
    run = @store.load(q.run['run_id'])
    record = run['models'][0]['profiles']['exact']
    run['models'][0]['profiles']['exact'] = {'status' => 'in_progress', 'attempts' => record['attempts']}
    run['status'] = 'running'; @store.save(run); q.close
    q = queue(@store.load(run['run_id'])); drain(q)
    assert_equal 1, @host.exports.size
    assert_equal 1, q.counts['completed']
    assert_equal 'verified_commit_after_interruption', q.run['models'][0]['profiles']['exact']['recovery_reason']
  end
  def test_incomplete_or_mismatched_receipts_never_reuse
    q = queue(create(profiles: ['exact'])); drain(q)
    r = q.run['models'][0]['profiles']['exact']
    original = Marshal.load(Marshal.dump(r))
    [
      -> { r.delete('validation_receipt') },
      -> { r['runtime'] = {'files_sha256' => 'wrong'} },
      -> { r['profile'] = 'visual' },
      -> { r['bytes'] += 1 },
      -> { r['performance_receipt']['sha256'] = 'wrong' }
    ].each do |mutate|
      r.replace(Marshal.load(Marshal.dump(original))); mutate.call
      refute @store.valid_record?(r, q.run['models'][0], 'exact', q.run, @host.runtime)
    end
    r.replace(original)
    receipt = r['performance_receipt']['path']
    File.write(receipt, '{')
    r['performance_receipt'] = B.fingerprint(receipt).merge('path' => receipt)
    refute @store.valid_record?(r, q.run['models'][0], 'exact', q.run, @host.runtime)
  end
  def test_old_export_hint_is_needs_verification_and_is_not_modified
    legacy = File.join(@src, 'model-eval-exports'); Dir.mkdir(legacy)
    path = File.join(legacy, 'same__SIBAMBO-BOMC-v1.2.0__EXACT.bomc'); File.binwrite(path, 'old')
    prior, reason = @store.reusable(@catalog.scan.last, 'exact', @host.runtime, @src)
    assert_nil prior; assert_equal 'needs_verification', reason
    assert_equal 'old', File.binread(path)
  end
  def test_collision_preserves_old_attempt_and_pauses
    q = queue(create(profiles: ['exact']))
    base = File.join(@out, q.run['run_id'], q.run['models'][0]['key'])
    FileUtils.mkdir_p(File.join(base, 'exact-' + 'c' * 24))
    marker = File.join(base, 'exact-' + 'c' * 24, 'artifact.bomc'); File.binwrite(marker, 'historic')
    SecureRandom.stub(:hex, 'c' * 24) { q.step }
    assert_equal 'historic', File.binread(marker)
    assert_equal 'paused', q.run['status']
    assert_empty @host.exports
  end
  def test_torn_latest_snapshot_recovery_does_not_collide_or_trust_manifest_view
    run = create
    snapshots = File.join(@out, run['run_id'], 'snapshots')
    File.write(File.join(snapshots, 'state-000000099.json'), '{')
    File.write(File.join(@out, run['run_id'], 'manifest.json'), 'not authoritative')
    loaded = @store.load(run['run_id']); assert_equal 99, loaded['sequence']
    @store.save(loaded); assert_equal 100, @store.load(run['run_id'])['sequence']
  end
  def test_resume_rejects_different_runtime
    q = queue(create); q.pause
    @host.define_singleton_method(:runtime) { {'files_sha256' => 'b' * 64} }
    assert_raises(B::Unsafe) { q.resume }
    assert_empty @host.exports
  end
  def test_pause_finishes_current_profile_and_resume_exports_only_remaining
    q = queue(create); @host.hook = -> { q.pause }; q.step
    assert_equal 'paused', q.run['status']; assert_equal 1, q.counts['completed']
    @host.hook = nil; q.resume; drain(q)
    assert_equal %w[exact visual], @host.exports.map(&:last)
  end
  def test_source_mutation_during_export_forces_pause_without_success
    q = queue(create)
    @host.hook = -> { File.binwrite(File.join(@src, 'same.skp'), 'changed') }
    q.step
    assert_equal 'paused', q.run['status']; assert_equal 0, q.counts['completed']
    assert_raises(B::Unsafe) { q.resume }
  end
  def test_progress_callback_cancel_prevents_export_and_reentrant_step
    q = queue(create)
    q.step do
      assert_raises(B::Unsafe) { q.step }
      q.cancel
    end
    assert_equal 'cancelled', q.run['status']; assert_empty @host.exports
  end
  def test_process_wide_lease_blocks_other_fibers_and_direct_exports
    q = queue(create)
    assert_nil BOMEngine::ConversionJob.start(title: 'conflict', output_path: 'D:/synthetic/out.bomc') { flunk 'interactive export ran' }
    error = assert_raises(RuntimeError) { BOMEngine::EvolutionExporter.export(nil, engine: :e2, profile: :exact, output_path: 'D:/synthetic/out') }
    assert_match 'Overnight batch owns', error.message
    assert_raises(RuntimeError) { SibamboNativeExportLease.direct { flunk 'conflicting export ran' } }
    other = Object.new
    assert_raises(RuntimeError) { SibamboNativeExportLease.acquire(other) }
    q.cancel
    assert_equal :allowed, SibamboNativeExportLease.direct { :allowed }
    SibamboNativeExportLease.direct do
      assert_raises(RuntimeError) { SibamboNativeExportLease.direct { flunk 'reentrant direct export ran' } }
    end
  end
  def test_permission_failure_is_recorded_and_pauses
    q = queue(create)
    @host.define_singleton_method(:export) { |*| raise Errno::EACCES, 'injected output denial' }
    q.step
    assert_equal 1, q.counts['failed']
    assert_match 'EACCES', q.run['last_error']
    assert_equal 'paused', q.run['status']
  end
  def test_linked_source_or_destination_is_refused
    linked = File.join(@dir, 'alias')
    begin
      File.symlink(@src, linked)
    rescue NotImplementedError, Errno::EACCES
      skip 'Windows symlink creation unavailable; native junction gate documented'
    end
    assert_raises(B::Unsafe) { B::Catalog.new(linked, output_root: @out) }
    assert_raises(B::Unsafe) { B::Store.new(root: File.join(linked, 'output')) }
  end
end

module UI
  class HtmlDialog
    STYLE_DIALOG = 0
    attr_reader :callbacks, :scripts
    def initialize(**); @callbacks = {}; @scripts = []; end
    def set_file(_); end
    def add_action_callback(name, &cb); @callbacks[name] = cb; end
    def set_on_closed(&cb); @closed = cb; end
    def show; @visible = true; end
    def visible?; @visible; end
    def bring_to_front; end
    def close; @visible = false; @closed.call; end
    def execute_script(s); @scripts << s; end
  end
  def self.start_timer(*, &cb); @timer = cb; 1; end
  def self.stop_timer(_); @timer = nil; end
  def self.tick; @timer.call if @timer; end
  def self.messagebox(*); end
end

class TestOvernightBatch
  def dialog_start(profiles: %w[exact visual])
    dialog = B::Dialog.new(host: @host, store: @store, require_d: false)
    dialog.command('action' => 'scan', 'root' => @src)
    dialog.show
    dialog.command('action' => 'start', 'selected' => ['same.skp'], 'profiles' => profiles)
    @queue = dialog.queue
    dialog
  end
  def test_dialog_timer_fiber_handles_nested_tick_and_cancel_drain
    dialog = dialog_start
    @host.hook = -> { UI.tick; dialog.command('action' => 'cancel') }
    10.times { UI.tick }
    assert_equal 'cancelled', @queue.run['status']
    assert_equal 1, @queue.counts['completed']
    refute SibamboNativeExportLease.owned?
    @host.hook = nil; dialog.command('action' => 'resume')
    20.times { UI.tick }
    assert_equal 'complete', @queue.run['status']
    assert_equal %w[exact visual], @host.exports.map(&:last)
  end
  def test_dialog_close_unwinds_fiber_and_releases_host
    dialog = dialog_start; UI.tick # suspended at OPEN_SKP
    run_id = @queue.run['run_id']
    html = dialog.instance_variable_get(:@dialog); html.close
    10.times { UI.tick }
    assert_equal 'cancelled', @store.load(run_id)['status']
    refute SibamboNativeExportLease.owned?
    assert_empty @host.exports
    @queue = nil # controller closed its writer handle after draining
  end
  def test_dialog_refuses_new_run_or_resume_while_profile_suspended
    dialog = dialog_start; UI.tick
    assert_raises(B::Unsafe) { dialog.command('action' => 'resume') }
    assert_raises(B::Unsafe) { dialog.command('action' => 'start', 'selected' => ['same.skp'], 'profiles' => ['visual']) }
    dialog.command('action' => 'cancel'); 10.times { UI.tick }
  end
  def test_evolution_template_exposes_batch_through_e4_without_building_package
    template = File.expand_path('../../tools/history/evolution_lineup/master_menu.rb', __dir__)
    menu = Object.new
    labels = []
    menu.define_singleton_method(:add_submenu) { |_| self }
    menu.define_singleton_method(:add_item) { |label, &_| labels << label }
    menu.define_singleton_method(:add_separator) {}
    UI.define_singleton_method(:menu) { |_| menu }
    slots = [{'id' => 'e4-bomc', 'engine' => 'e4', 'title' => 'E4', 'sha' => '0' * 40,
      'entry' => 'synthetic-entry.rb', 'moduleName' => 'SibamboBatchFixture'}]
    original = File.method(:read)
    File.stub(:read, ->(path, **opts) { path.end_with?('/engines.json') ? JSON.generate(slots) : original.call(path, **opts) }) { load template }
    assert_includes labels, 'Overnight Batch Export...'
    fixture = Module.new
    fixture.define_singleton_method(:load_engine) { BOMEngine }
    Object.const_set(:SibamboBatchFixture, fixture)
    lab = SibamboHistory::EvolutionLab
    required = []
    lab.define_singleton_method(:require) { |path| required << path }
    shown = 0
    File.stub(:file?, true) do
      B::Dialog.stub(:show, -> { shown += 1 }) { lab.open_overnight_batch }
    end
    assert_equal 1, shown
    assert_equal [File.join(File.dirname(template), 'synthetic-entry.rb')], required
  ensure
    Object.send(:remove_const, :SibamboBatchFixture) if Object.const_defined?(:SibamboBatchFixture)
    lab.singleton_class.send(:remove_method, :require) if lab && lab.singleton_methods(false).include?(:require)
  end
end
