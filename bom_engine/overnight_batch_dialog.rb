# frozen_string_literal: true
require_relative 'overnight_batch'

module BOMEngine
  module OvernightBatch
    # HtmlDialog callbacks only request state transitions. One timer owns one
    # fiber, and never resumes it recursively when SketchUp pumps UI events.
    class Dialog
      def self.show
        @instance ||= new
        @instance.show
      end
      attr_reader :queue
      def initialize(host: SketchupHost.new, store: Store.new, require_d: true)
        @host, @store, @require_d = host, store, require_d
        @source_root = SOURCE_ROOT; @rows = []; @busy = false; @closed = false
      end
      def show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return
        end
        @closed = false
        @dialog = UI::HtmlDialog.new(dialog_title: 'Overnight Batch Export', preferences_key: 'sibambo.overnight_batch',
          scrollable: true, resizable: true, width: 1050, height: 740, style: UI::HtmlDialog::STYLE_DIALOG)
        @dialog.set_file(File.join(__dir__, 'overnight_batch.html'))
        @dialog.add_action_callback('batch') do |_, payload|
          begin
            raise Unsafe, 'Invalid UI payload.' unless payload.is_a?(String) && payload.bytesize <= 1024 * 1024
            command(JSON.parse(payload))
          rescue StandardError => e
            @error = "#{e.class}: #{e.message}"; render
          end
        end
        @dialog.set_on_closed do
          @closed = true
          @queue.cancel if @queue && active?
          # Keep ticking to unwind suspended exporter ensure/cleanup blocks.
          release_queue unless @fiber && @fiber.alive?
        end
        @dialog.show
      end
      def active?
        (@fiber && @fiber.alive?) || (@queue && @queue.run['status'] == 'running')
      end
      def command(data)
        action = data.fetch('action')
        if %w[scan choose start load resume].include?(action) && active?
          raise Unsafe, 'Wait until the active profile reaches a safe boundary.'
        end
        @error = nil
        case action
        when 'ready', 'scan'
          scan(data['root'] || @source_root)
        when 'choose'
          root = UI.select_directory(title: 'Choose SKP source root on D:', directory: @source_root)
          scan(root) if root
        when 'start'
          release_queue
          @catalog = Catalog.new(@source_root, output_root: @store.root, require_d: @require_d)
          runtime = @host.runtime
          run = @store.create(catalog: @catalog, selected: data.fetch('selected'), profiles: data.fetch('profiles'),
            engines: data.fetch('engines', ['e4']),
            runtime: runtime, stop_on_error: data['stop_on_error'], free_bytes: @host.free_bytes(@store.root))
          attach(run); @queue.resume; schedule
        when 'load'
          release_queue
          run = @store.load(data.fetch('run_id'))
          @source_root = run.fetch('source_root')
          @rows = []
          scan(@source_root)
          if run['schema'] == LEGACY_SCHEMA
            @legacy_run = run # Read/display only. Never save or migrate v2.
          else
            attach(run) # load/reverify only; Resume remains explicit.
          end
        when 'resume'
          raise Unsafe, 'Load a run first.' unless @queue
          @queue.resume; schedule
        when 'pause'; @queue.pause if @queue
        when 'cancel'; @queue.cancel if @queue
        else; raise Unsafe, 'Unknown batch action.'
        end
        render
      end
      def scan(root)
        raise Unsafe, 'Cannot scan during active export.' if active?
        catalog = Catalog.new(root, output_root: @store.root, require_d: @require_d)
        if @queue && OvernightBatch.canonical(@queue.run['source_root']) != OvernightBatch.canonical(catalog.root)
          release_queue
        end
        @legacy_run = nil if @legacy_run && OvernightBatch.canonical(@legacy_run['source_root']) != OvernightBatch.canonical(catalog.root)
        @catalog = catalog
        @rows = []
        @source_root = @catalog.root
        runtime = @host.runtime
        @rows = @catalog.scan.map do |row|
          statuses = ENGINES.to_h do |engine|
            [engine, PROFILES.to_h do |p|
              prior, reason = @store.reusable(row, p, runtime, @source_root, engine: engine)
              [p, {'status' => prior ? 'Verified' : (reason == 'needs_verification' ? 'Needs Verification' : 'Missing'), 'reason' => reason}]
            end]
          end
          row.merge('statuses' => statuses)
        end
      end
      def attach(run)
        @queue = Queue.new(store: @store, catalog: @catalog, run: run, host: @host)
      end
      def schedule
        return if @timer
        @timer = UI.start_timer(0.04, true) { tick }
      end
      def tick
        return if @busy
        @busy = true
        begin
          if @fiber && @fiber.alive?
            @fiber.resume
          elsif @queue && @queue.run['status'] == 'running'
            @fiber = Fiber.new { @queue.step { render_progress; Fiber.yield } }
            @fiber.resume
          end
          unless (@fiber && @fiber.alive?) || (@queue && @queue.run['status'] == 'running')
            UI.stop_timer(@timer) if @timer; @timer = nil
            release_queue if @closed
          end
          active? ? render_progress : render
        rescue StandardError => e
          @error = "#{e.class}: #{e.message}"
          @queue.pause if @queue
          UI.stop_timer(@timer) if @timer; @timer = nil
          render
        ensure
          @busy = false
        end
      end
      def release_queue
        @queue.close if @queue
        @queue = nil
        @legacy_run = nil
      end
      def state
        run = (@queue && @queue.run) || @legacy_run
        rows = @rows.map do |row|
          live = run && run['models'].find { |m| m['relative'] == row['relative'] && m['sha256'] == row['sha256'] }
          next row unless live
          statuses = row['statuses'].transform_values(&:dup)
          exports = @legacy_run ? {'e4' => live.fetch('profiles')} : live.fetch('exports')
          exports.each do |engine, records|
            records.each do |p, r|
              label = %w[success reused].include?(r['status']) ? 'Verified' : r['status'].tr('_', ' ').capitalize
              label = 'Historical' if @legacy_run && %w[success reused].include?(r['status'])
              statuses[engine][p] = {'status' => label, 'reason' => r['error'] || r['reuse_reason'] || r['status']}
            end
          end
          row.merge('statuses' => statuses)
        end
        {'root' => @source_root, 'rows' => rows, 'error' => @error, 'active' => !!active?,
          'run' => run, 'counts' => @queue && @queue.counts, 'read_only' => !!@legacy_run,
          'output_root' => @store.root, 'runs' => @store.run_ids,
          'manifest' => run && File.join(@store.root, run['run_id'], 'manifest.json')}
      end
      def render
        return if @closed || !@dialog
        # JSON is passed as data, never HTML. Escape JS line separators for CEF.
        payload = JSON.generate(state).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
        @dialog.execute_script("window.batchState(#{payload})")
      end
      def render_progress
        return if @closed || !@dialog || !@queue
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @last_progress && now - @last_progress < 0.1
        @last_progress = now
        data = {'status' => @queue.run['status'], 'current' => @queue.run['current'], 'counts' => @queue.counts}
        @dialog.execute_script("window.batchProgress(#{JSON.generate(data)})")
      end
    end
  end
end
