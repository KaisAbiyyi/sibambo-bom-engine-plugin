# frozen_string_literal: true

# SIB-R1-ITCON-001 ModelTruth, SketchUp side (runs inside SketchUp, owner-run).
#
#   load 'D:/projects/sibambo/scratch/worktrees/sib-r1-model-truth-001/tools/model_truth/skp_side.rb'
#   SibamboModelTruthV1::SkpSide.capture(run_dir: '<run_dir>', expected_source_sha256: '<skp sha256>')
#   SibamboModelTruthV1::SkpSide.status   # prints phase, counts, elapsed
#   SibamboModelTruthV1::SkpSide.cancel   # optional
#
# Read-only: the model is never modified (no operations, no entity creation, no
# save). Cooperative: a Fiber driven by UI.start_timer yields every 64 records
# or 6 ms so SketchUp stays responsive. Requires only canonical.rb.

require 'digest'
require 'fileutils'
require 'json'
require 'zlib'
require_relative 'canonical'

module SibamboModelTruthV1
  module SkpSide
    REQUIRED_VERSION = '26.2.243'
    TIME_LIMIT_S = 14_400
    PROGRESS_EVERY_S = 5.0
    MAX_DEPTH = 64
    HIST_MS = [20, 50, 100, 250].freeze
    CPU_THREAD = Process.const_defined?(:CLOCK_THREAD_CPUTIME_ID) ? Process::CLOCK_THREAD_CPUTIME_ID : nil
    CPU_PROCESS = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : nil

    class Cancelled < ModelTruthError; end

    class << self
      attr_accessor :quiet

      # ------------------------------------------------------------------ API
      def capture(run_dir:, expected_source_sha256:, budget_records: 64, budget_s: 0.006, time_limit_s: TIME_LIMIT_S)
        preconditions!(run_dir, expected_source_sha256)
        @budget_records = budget_records
        @budget_s = budget_s
        @time_limit_s = time_limit_s
        start!(run_dir, expected_source_sha256)
        say("ModelTruth SKP side started: #{run_dir}")
        true
      end

      def status
        s = {
          active: @active ? true : false, finished: @finished ? true : false, phase: @phase,
          elapsed_s: @started ? (monotonic - @started).round(1) : nil, counts: @counts, complete: @complete
        }
        say(s.inspect)
        s
      end

      def cancel
        @cancel = true
        say('ModelTruth: cancel requested; stops at the next tick')
        true
      end

      # Owner probe (about 5 s): prints which clock is used and two samples.
      def cpu_probe
        a = cpu_ms(:thread)
        x = 0
        2_000_000.times { |i| x += i }
        b = cpu_ms(:thread)
        r = { source: cpu_source, thread_ms_before: a, thread_ms_after: b, process_ms: cpu_ms(:process) }
        say(r.inspect)
        r
      end

      # Test seam: forget all state (never called in production).
      def reset!
        @timer_id = nil
        @active = false
        @finished = false
        @finish_done = false
        @cancel = false
        @fiber = nil
      end

      # ------------------------------------------------------------ internals
      private

      def say(text)
        puts(text) unless quiet
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def jline(hash)
        JSON.generate(hash) + "\n"
      end

      def preconditions!(run_dir, expected)
        raise ModelTruthError, "SketchUp #{REQUIRED_VERSION} required (found #{Sketchup.version})" unless Sketchup.version == REQUIRED_VERSION
        raise ModelTruthError, 'Windows required' unless Sketchup.platform == :platform_win
        raise ModelTruthError, 'a capture is already active' if @active

        running = ObjectSpace.each_object(Class).any? do |klass|
          klass.name.to_s.end_with?('::ConversionJob') && klass.respond_to?(:active) && klass.active && klass.active.running?
        end
        raise ModelTruthError, 'a BOMC conversion job is running' if running

        model = Sketchup.active_model
        raise ModelTruthError, 'model has no path' if model.path.to_s.empty?
        raise ModelTruthError, 'model has unsaved changes' if model.modified?
        raise ModelTruthError, 'model SHA-256 differs from expected_source_sha256' unless Digest::SHA256.file(model.path).hexdigest == expected

        bman = File.join(run_dir, 'bomc', 'manifest.json')
        raise ModelTruthError, 'BOMC side manifest missing' unless File.file?(bman)

        manifest = JSON.parse(File.read(bman))
        raise ModelTruthError, 'BOMC side manifest not complete' unless manifest['complete'] == true
        raise ModelTruthError, 'BOMC side was built for another SKP' unless manifest.dig('inputs', 'skp_sha256') == expected
        raise ModelTruthError, 'run_dir/skp already exists' if File.exist?(File.join(run_dir, 'skp'))
      end

      def create_excl(path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600)
      end

      def write_atomic(path, text)
        File.open("#{path}.partial", File::WRONLY | File::CREAT | File::TRUNC | File::BINARY, 0o600) { |f| f.write(text) }
        File.rename("#{path}.partial", path)
      end

      def start!(run_dir, expected)
        @model = Sketchup.active_model
        @source_path = @model.path.to_s.tr('\\', '/')
        @source_guid = @model.guid.to_s
        @source_before = { bytes: File.size(@model.path), sha256: expected }
        @run_dir = run_dir
        @skp_dir = File.join(run_dir, 'skp')
        Dir.mkdir(@skp_dir)
        Dir.mkdir(File.join(@skp_dir, 'tmp'))
        Dir.mkdir(File.join(@skp_dir, 'jcm-base'))
        @saved_temp = [ENV['TEMP'], ENV['TMP']]
        tmp = File.join(@skp_dir, 'tmp').tr('/', '\\')
        ENV['TEMP'] = tmp
        ENV['TMP'] = tmp
        @items_gz = Zlib::GzipWriter.new(create_excl(File.join(@skp_dir, 'items.ndjson.gz')), 1)
        @items_gz.mtime = Time.at(0)
        @defs_io = create_excl(File.join(@skp_dir, 'definitions.ndjson'))
        @pix_io = create_excl(File.join(@skp_dir, 'bomc-texture-pixels.ndjson'))
        @tw = Sketchup.create_texture_writer
        @expected = expected
        @started = monotonic
        @finished = false
        @finish_done = false
        @complete = nil
        @cancel = false
        @active = true
        @in_tick = false
        @phase = 'starting'
        @counts = { uv_q0_vertices: 0, non_triangle_polygons: 0, deleted_skipped: 0, edges_with_material: 0, texts_without_point: 0,
                    unreachable_definitions: 0, faces: 0, edges: 0, instances: 0, images: 0, texts: 0, definitions: 0 }
        @excluded = Hash.new(0)
        @dfs = {}
        @digest = {}
        @records = []
        @tables = { tags: [], materials: [] }
        @root_digest = nil
        @slice_count = 0
        @max_slice_ms = 0.0
        @max_ruby_slice_ms = 0.0
        @max_native_ms = 0.0
        @max_native_label = nil
        @max_tick_gap_ms = 0.0
        @last_tick_start = nil
        @last_progress = 0.0
        @items_total = 0
        @ctx = nil
        @ctx_start = nil
        @slowest = []
        @untimed_totals = Hash.new(0.0)
        @slice_untimed = Hash.new(0.0)
        @gc_slice_start = nil
        @gc_run_start = gc_snapshot
        @cpu_thread_start = nil
        @cpu_proc_start = nil
        @slice_native_cpu_ms = 0.0
        @cpu_totals = { thread_ms: 0.0, process_ms: 0.0, native_thread_ms: 0.0 }
        @max_ruby_cpu_ms = 0.0
        @max_off_cpu_ms = 0.0
        @hist = { 'ruby_ms' => Hash[HIST_MS.map { |k| [k.to_s, 0] }], 'off_cpu_ms' => Hash[HIST_MS.map { |k| [k.to_s, 0] }] }
        @fiber = Fiber.new do
          run_phases
          :complete
        end
        write_progress(force: true)
        @timer_id = UI.start_timer(0.001, true) { tick }
      end

      # ------------------------------------------------------- cooperative core
      def tick
        return if @finished || @in_tick

        @in_tick = true
        t = monotonic
        if @last_tick_start
          gap = (t - @last_tick_start) * 1000.0 - 1.0
          @max_tick_gap_ms = gap if gap > @max_tick_gap_ms
        end
        @last_tick_start = t
        @slice_started = t
        @slice_records = 0
        @slice_native_ms = 0.0
        @slice_untimed = Hash.new(0.0)
        @ctx_start = @ctx
        @gc_slice_start = gc_snapshot
        @cpu_thread_start = cpu_ms(:thread)
        @cpu_proc_start = cpu_ms(:process)
        @slice_native_cpu_ms = 0.0
        @slice_accounted = false
        begin
          guard!
          res = @fiber.resume
          account_slice
          finish(true) if res == :complete
        rescue StandardError => e
          account_slice
          finish(false, e)
        ensure
          account_slice
          write_progress unless @finished
          @in_tick = false
        end
      end

      def account_slice
        return if @slice_accounted

        @slice_accounted = true
        ms = (monotonic - @slice_started) * 1000.0
        @slice_count += 1
        @max_slice_ms = ms if ms > @max_slice_ms
        ruby_ms = ms - @slice_native_ms
        @max_ruby_slice_ms = ruby_ms if ruby_ms > @max_ruby_slice_ms
        gc = gc_delta(@gc_slice_start, gc_snapshot)
        cpu = slice_cpu(ruby_ms)
        count_histogram(ruby_ms, cpu)
        record_slowest(ms, ruby_ms, gc, cpu)
      end

      # Evidence only (review F2, H3): Ruby GC counters. GC time is not
      # recorded: GC.total_time produced values larger than the slice itself
      # in the 20261117T100939Z capture, so it is not a usable measure.
      def gc_snapshot
        st = GC.stat
        { count: GC.count, major: st[:major_gc_count], minor: st[:minor_gc_count], allocated: st[:total_allocated_objects] }
      end

      def gc_delta(a, b)
        return {} if a.nil?

        { count: b[:count] - a[:count], major: (b[:major].to_i - a[:major].to_i), minor: (b[:minor].to_i - a[:minor].to_i),
          allocated: (b[:allocated].to_i - a[:allocated].to_i) }
      end

      # Evidence only: CPU time of this thread and of the whole process, in ms,
      # or nil when the platform has no such clock. Windows accounts thread time
      # in scheduler ticks (about 15.6 ms), so values below that are coarse.
      def cpu_ms(kind)
        case cpu_source
        when 'clock_gettime' then Process.clock_gettime(kind == :thread ? CPU_THREAD : CPU_PROCESS, :float_millisecond)
        when 'fiddle' then fiddle_cpu_ms(kind)
        end
      rescue StandardError, NotImplementedError
        nil
      end

      # 'clock_gettime' when Ruby has both CPU clocks, else 'fiddle' (read-only
      # GetThreadTimes/GetProcessTimes from kernel32), else 'none'. Ruby 2.5 on
      # Windows defines the constants but raises EINVAL, so each is tried.
      def cpu_source
        @cpu_source ||= detect_cpu_source
      end

      def detect_cpu_source
        if CPU_THREAD && CPU_PROCESS
          begin
            Process.clock_gettime(CPU_THREAD, :float_millisecond)
            Process.clock_gettime(CPU_PROCESS, :float_millisecond)
            return 'clock_gettime'
          rescue StandardError, NotImplementedError
            nil
          end
        end
        begin
          init_fiddle
          'fiddle'
        rescue StandardError, LoadError, NotImplementedError
          'none'
        end
      end

      def init_fiddle
        require 'fiddle'
        lib = Fiddle.dlopen('kernel32.dll')
        ptr = Fiddle::TYPE_VOIDP
        @fd_cur_thread = Fiddle::Function.new(lib['GetCurrentThread'], [], ptr)
        @fd_cur_process = Fiddle::Function.new(lib['GetCurrentProcess'], [], ptr)
        @fd_thread_times = Fiddle::Function.new(lib['GetThreadTimes'], [ptr, ptr, ptr, ptr, ptr], Fiddle::TYPE_INT)
        @fd_process_times = Fiddle::Function.new(lib['GetProcessTimes'], [ptr, ptr, ptr, ptr, ptr], Fiddle::TYPE_INT)
        @fd_bufs = Array.new(4) { Fiddle::Pointer.malloc(8) }
        raise 'GetThreadTimes failed' if fiddle_cpu_ms(:thread).nil?
      end

      # kernel + user time in ms (FILETIME, 100 ns units); Windows accounts it
      # in scheduler ticks, so resolution is about 15.6 ms.
      def fiddle_cpu_ms(kind)
        ok = if kind == :thread
               @fd_thread_times.call(@fd_cur_thread.call, *@fd_bufs)
             else
               @fd_process_times.call(@fd_cur_process.call, *@fd_bufs)
             end
        return nil if ok.zero?

        (filetime(@fd_bufs[2]) + filetime(@fd_bufs[3])) / 10_000.0
      end

      def filetime(ptr)
        lo, hi = ptr[0, 8].unpack('VV')
        (hi << 32) | lo
      end

      # Splits the slice's "Ruby" wall time into time this thread spent on the
      # CPU and time it did not (descheduled, blocked, waiting for the
      # interpreter lock). Native calls are removed on both sides.
      def slice_cpu(ruby_ms)
        t1 = cpu_ms(:thread)
        p1 = cpu_ms(:process)
        return nil if t1.nil? || @cpu_thread_start.nil?

        thread_ms = t1 - @cpu_thread_start
        process_ms = p1 && @cpu_proc_start ? p1 - @cpu_proc_start : nil
        ruby_cpu = [thread_ms - @slice_native_cpu_ms, 0.0].max
        off_cpu = [ruby_ms - ruby_cpu, 0.0].max
        @cpu_totals[:thread_ms] += thread_ms
        @cpu_totals[:process_ms] += process_ms if process_ms
        @cpu_totals[:native_thread_ms] += @slice_native_cpu_ms
        @max_ruby_cpu_ms = ruby_cpu if ruby_cpu > @max_ruby_cpu_ms
        @max_off_cpu_ms = off_cpu if off_cpu > @max_off_cpu_ms
        { thread_cpu_ms: thread_ms, process_cpu_ms: process_ms, native_cpu_ms: @slice_native_cpu_ms, ruby_cpu_ms: ruby_cpu, off_cpu_ms: off_cpu }
      end

      def count_histogram(ruby_ms, cpu)
        HIST_MS.each do |limit|
          @hist['ruby_ms'][limit.to_s] += 1 if ruby_ms > limit
          @hist['off_cpu_ms'][limit.to_s] += 1 if cpu && cpu[:off_cpu_ms] > limit
        end
      end

      # Evidence only (review F2): keeps the five slices with the most "Ruby"
      # time together with where they started and ended and how much of that
      # time was spent in measured-but-not-native-classified calls. Never
      # changes max_ruby_slice_ms, digests or verdicts.
      def record_slowest(ms, ruby_ms, gc = {}, cpu = nil)
        return if @slowest.length >= 5 && ruby_ms <= @slowest.last[:ruby_ms]

        @slowest << { slice: @slice_count, phase: @phase, slice_ms: ms.round(3), native_ms: @slice_native_ms.round(3), ruby_ms: ruby_ms.round(3),
                      records: @slice_records, ctx_start: ctx_hash(@ctx_start), ctx_end: ctx_hash(@ctx),
                      untimed_ms: @slice_untimed.each_with_object({}) { |(k, v), h| h[k.to_s] = v.round(3) },
                      gc: gc.transform_values { |v| v.is_a?(Float) ? v.round(3) : v },
                      cpu: cpu && cpu.each_with_object({}) { |(k, v), h| h[k.to_s] = v && v.round(3) } }
        @slowest = @slowest.sort_by { |s| -s[:ruby_ms] }.first(5)
      end

      def ctx_hash(ctx)
        return nil if ctx.nil?

        { phase: ctx[0], definition_dfs: ctx[1], definition_kind: ctx[2], entity_index: ctx[3],
          entity_class: ctx[4].respond_to?(:name) ? ctx[4].name : ctx[4].to_s, detail: ctx[5] }
      end

      # Measures a call that is not classified as native for G-RT3 (so
      # max_ruby_slice_ms is unchanged) but whose cost is reported per slice.
      def untimed(label)
        t0 = monotonic
        result = yield
        ms = (monotonic - t0) * 1000.0
        @slice_untimed[label] += ms
        @untimed_totals[label] += ms
        result
      end

      def guard!
        raise Cancelled, 'cancelled' if @cancel
        raise ModelTruthError, 'timeout' if monotonic - @started >= @time_limit_s
        unless @model.path.to_s.tr('\\', '/') == @source_path && @model.guid.to_s == @source_guid && !@model.modified?
          raise ModelTruthError, 'source model changed'
        end
      end

      def boundary
        @slice_records += 1
        @items_total += 1
        Fiber.yield if @slice_records >= @budget_records || monotonic - @slice_started >= @budget_s
      end

      def timed(label)
        t0 = monotonic
        c0 = cpu_ms(:thread)
        result = yield
        ms = (monotonic - t0) * 1000.0
        c1 = cpu_ms(:thread)
        @slice_native_cpu_ms += (c1 - c0) if c0 && c1
        @slice_native_ms += ms
        if ms > @max_native_ms
          @max_native_ms = ms
          @max_native_label = label.to_s
        end
        result
      end

      def write_progress(force: false)
        now = monotonic
        return unless force || now - @last_progress >= PROGRESS_EVERY_S

        @last_progress = now
        write_atomic(File.join(@skp_dir, 'progress.json'), JSON.generate(phase: @phase, counts: @counts, elapsed_s: (now - @started).round(1),
                                                                         definitions: @digest.length, complete: @complete))
      end

      def set_phase(name)
        @phase = name
        write_progress(force: true)
      end

      def finish(complete, error = nil)
        return if @finished

        @finished = true
        finish_body(complete, error)
      ensure
        if @finished && !@finish_done
          @finish_done = true
          ENV['TEMP'], ENV['TMP'] = @saved_temp if @saved_temp
          @phase = 'finished'
          @active = false
        end
      end

      def finish_body(complete, error)
        begin
          UI.stop_timer(@timer_id) if @timer_id
        rescue StandardError
          nil
        end
        [@items_gz, @defs_io, @pix_io].each do |io|
          begin
            io&.close
          rescue StandardError
            nil
          end
        end
        manifest = { schema: Canonical::SCHEMA, side: 'skp', complete: false }
        begin
          if complete
            after = { bytes: File.size(@model.path), sha256: Digest::SHA256.file(@model.path).hexdigest }
            raise ModelTruthError, 'source file changed during capture' unless after == @source_before
            raise ModelTruthError, 'model modified during capture' if @model.modified?
          end
          write_atomic(File.join(@skp_dir, 'tables.json'), JSON.pretty_generate(@tables.merge(schema: Canonical::SCHEMA)))
          write_atomic(File.join(@skp_dir, 'exclusions.json'), JSON.pretty_generate(excluded: @excluded, counters: @counts))
          files = {}
          Dir.glob(File.join(@skp_dir, '**', '*')).sort.each do |p|
            next unless File.file?(p)

            rel = p.sub("#{@skp_dir}/", '')
            next if rel == 'manifest.json' || rel.end_with?('.partial')

            files[rel] = Digest::SHA256.file(p).hexdigest
          end
          duration = monotonic - @started
          manifest = {
            schema: Canonical::SCHEMA, side: 'skp', complete: complete, inputs: { skp_path: @source_path, skp_sha256: @expected },
            root_digest: @root_digest, definition_count: @records.length, counts: @counts,
            sketchup_version: Sketchup.version, ruby_version: RUBY_VERSION,
            tools: { canonical_rb_sha256: Digest::SHA256.file(File.expand_path('canonical.rb', __dir__)).hexdigest,
                     skp_side_rb_sha256: Digest::SHA256.file(File.expand_path(__FILE__)).hexdigest },
            runtime: { duration_s: duration.round(3), slice_count: @slice_count, max_slice_ms: @max_slice_ms.round(3),
                       max_ruby_slice_ms: @max_ruby_slice_ms.round(3), max_native_call_ms: @max_native_ms.round(3),
                       max_native_call_label: @max_native_label, max_tick_gap_ms: @max_tick_gap_ms.round(3),
                       items_per_second: duration.positive? ? (@items_total / duration).round(1) : nil,
                       gc_run: gc_delta(@gc_run_start, gc_snapshot).transform_values { |v| v.is_a?(Float) ? v.round(3) : v },
                       ruby_gc_version: RUBY_VERSION,
                       cpu: { source: cpu_source, resolution_note: 'Windows thread time is accounted in ~15.6 ms ticks',
                              thread_ms: @cpu_totals[:thread_ms].round(3), process_ms: @cpu_totals[:process_ms].round(3),
                              native_thread_ms: @cpu_totals[:native_thread_ms].round(3),
                              max_ruby_cpu_slice_ms: @max_ruby_cpu_ms.round(3), max_off_cpu_slice_ms: @max_off_cpu_ms.round(3) },
                       slice_histogram: @hist,
                       slowest_slices: @slowest, untimed_totals_ms: @untimed_totals.each_with_object({}) { |(k, v), h| h[k.to_s] = v.round(3) } },
            files: files
          }
          manifest[:error] = { class: error.class.name, message: error.message } if error
        rescue StandardError => e
          manifest = { schema: Canonical::SCHEMA, side: 'skp', complete: false, error: { class: e.class.name, message: e.message } }
          complete = false
        end
        @complete = complete
        manifest[:complete] = complete
        write_atomic(File.join(@skp_dir, 'manifest.json'), JSON.pretty_generate(manifest))
        say("ModelTruth SKP side finished: complete=#{complete}#{error ? " error=#{error.class}: #{error.message}" : ''}")
      end

      # ------------------------------------------------------------------ phases
      def run_phases
        set_phase('tables')
        phase_tables
        set_phase('definitions')
        @root_digest = visit(@model, 'root', 0)
        @counts[:unreachable_definitions] = @model.definitions.count { |d| !d.image? && !@digest.key?(d) }
        write_definition_records
        set_phase('skp_pixels')
        phase_skp_pixels
        set_phase('bomc_pixels')
        phase_bomc_pixels
        set_phase('finish')
      end

      def name_or_nil(m)
        m.nil? ? nil : Canonical.utf8!(m.name)
      end

      def layer_name(e)
        e.layer.nil? ? nil : Canonical.utf8!(e.layer.name)
      end

      def colorize_type_of(m)
        return nil unless m.materialType.to_i == 2 && m.respond_to?(:colorize_type)

        m.colorize_type == Sketchup::Material::COLORIZE_SHIFT ? 'shift' : 'tint'
      end

      def phase_tables
        @model.layers.each do |layer|
          @tables[:tags] << { name: Canonical.utf8!(layer.name), visible: layer.visible? ? true : false }
          boundary
        end
        @model.materials.each do |m|
          t = m.texture
          c = m.color
          deltas = (m.materialType.to_i == 2 && m.respond_to?(:colorize_deltas)) ? m.colorize_deltas : nil
          @tables[:materials] << {
            name: Canonical.utf8!(m.name),
            color: [c.red, c.green, c.blue, c.alpha],
            alpha_hex: Canonical.float_hex(m.alpha),
            material_type: m.materialType.to_i,
            texture: t.nil? ? nil : { width_m_hex: Canonical.float_hex((t.width.to_f * 0.0254).round(9)),
                                      height_m_hex: Canonical.float_hex((t.height.to_f * 0.0254).round(9)),
                                      image_width: t.image_width, image_height: t.image_height },
            colorize_type: colorize_type_of(m),
            colorize_deltas_hex: deltas.nil? ? nil : deltas.to_a.map { |v| Canonical.float_hex(v) },
            pixels: nil
          }
          boundary
        end
      end

      def add_item(msets, key, code, item, dfs_idx, extra = {})
        msets[key].add(Canonical.canon_json(item))
        @items_gz.write(jline({ 'd' => dfs_idx, 'c' => code, 'i' => item }.merge(extra)))
      end

      def visit(owner, kind, depth)
        return @digest[owner] if @digest.key?(owner)
        raise ModelTruthError, 'depth_limit' if depth > MAX_DEPTH

        my_dfs = @dfs.length
        @dfs[owner] = my_dfs
        entities = kind == 'root' ? @model.entities : owner.entities
        msets = { faces: Canonical::MSet.new, edges: Canonical::MSet.new, images: Canonical::MSet.new, texts: Canonical::MSet.new,
                  inst_local: Canonical::MSet.new, inst_merkle: Canonical::MSet.new }
        counts = { faces: 0, edges: 0, instances: 0, images: 0, texts: 0 }
        children_dfs = []

        @ctx = [@phase, my_dfs, kind, nil, nil]
        entity_index = -1
        each_started = monotonic
        entities.each do |e|
          if entity_index < 0
            ms = (monotonic - each_started) * 1000.0
            @slice_untimed[:entities_each_start] += ms
            @untimed_totals[:entities_each_start] += ms
          end
          entity_index += 1
          @ctx = [@phase, my_dfs, kind, entity_index, e.class]
          if e.deleted?
            @counts[:deleted_skipped] += 1
            boundary
            next
          end
          case e
          when Sketchup::Face
            add_item(msets, :faces, 'F', face_item(e), my_dfs)
            counts[:faces] += 1
            boundary
          when Sketchup::Edge
            item = Canonical.edge_item(tag: layer_name(e), hidden: e.hidden?, soft: e.soft?, smooth: e.smooth?,
                                       a: Canonical.skp_pos(e.start.position), b: Canonical.skp_pos(e.end.position))
            add_item(msets, :edges, 'E', item, my_dfs)
            @counts[:edges_with_material] += 1 if e.material
            counts[:edges] += 1
            boundary
          when Sketchup::Group, Sketchup::ComponentInstance
            child = e.definition
            ck = e.is_a?(Sketchup::Group) ? 'group' : 'component'
            child_digest = visit(child, ck, depth + 1)
            local = Canonical.instance_local_item(kind: ck, t16: Canonical.skp_t16(e.transformation), material: name_or_nil(e.material), tag: layer_name(e))
            msets[:inst_local].add(Canonical.canon_json(local))
            msets[:inst_merkle].add(Canonical.canon_json(Canonical.instance_merkle_item(local, child_digest)))
            @items_gz.write(jline('d' => my_dfs, 'c' => 'I', 'i' => local, 'child_dfs' => @dfs[child], 'child_digest' => child_digest))
            counts[:instances] += 1
            children_dfs << @dfs[child]
            boundary
          when Sketchup::Image
            add_item(msets, :images, 'G', Canonical.image_item(t16: Canonical.skp_t16(e.transformation), tag: layer_name(e)), my_dfs)
            counts[:images] += 1
            boundary
          when Sketchup::Text
            if e.point.nil?
              @counts[:texts_without_point] += 1
            else
              add_item(msets, :texts, 'X', Canonical.text_item(text: Canonical.utf8!(e.text), point: Canonical.skp_pos(e.point), tag: layer_name(e)), my_dfs)
              counts[:texts] += 1
            end
            boundary
          else
            @excluded[e.class.name] += 1
            boundary
          end
        end

        local_digest, dig = Canonical.definition_digests(kind, msets[:faces], msets[:edges], msets[:images], msets[:texts],
                                                         msets[:inst_local], msets[:inst_merkle])
        counts.each { |k, v| @counts[k] += v }
        @counts[:definitions] += 1
        @records << {
          dfs: my_dfs, kind: kind, digest: dig, local_digest: local_digest,
          faces: msets[:faces].to_a, edges: msets[:edges].to_a, images: msets[:images].to_a, texts: msets[:texts].to_a,
          inst_local: msets[:inst_local].to_a, inst_merkle: msets[:inst_merkle].to_a, counts: counts, children_dfs: children_dfs
        }
        @digest[owner] = dig
      end

      def face_item(face)
        fm = face.material
        bm = face.back_material
        ft = !fm.nil? && !fm.texture.nil?
        bt = !bm.nil? && !bm.texture.nil?
        helper = (ft || bt) ? timed(:get_UVHelper) { face.get_UVHelper(ft, bt, @tw) } : nil
        tuple = lambda do |v|
          t = Canonical.skp_pos(v.position)
          t += Canonical.skp_uv(helper.get_front_UVQ(v.position), @counts) if ft
          t += Canonical.skp_uv(helper.get_back_UVQ(v.position), @counts) if bt
          t
        end
        outer_vertices = untimed(:face_loops) { face.outer_loop.vertices }
        hole_loops = untimed(:face_loops) { face.loops.reject(&:outer?) }
        outer = outer_vertices.map(&tuple)
        holes = hole_loops.map { |l| l.vertices.map(&tuple) }
        mesh = timed(:mesh) { face.mesh }
        tris = []
        polygons = untimed(:mesh_polygons) { mesh.polygons }
        polygons.each do |poly|
          pts = poly.map { |i| mesh.point_at(i.abs) }.compact
          if pts.length == 3
            tris << pts.map { |p| Canonical.skp_pos(p) }
          else
            @counts[:non_triangle_polygons] += 1
          end
        end
        normal = [face.normal.x, face.normal.y, face.normal.z].map { |c| Canonical.skp_unit(c) }
        Canonical.face_item(front: name_or_nil(fm), back: name_or_nil(bm), tag: layer_name(face), hidden: face.hidden?, normal: normal,
                            outer: outer, holes: holes, triangles: tris, uv_front: ft, uv_back: bt)
      end

      def write_definition_records
        @records.sort_by { |r| r[:dfs] }.each { |r| @defs_io.write(jline(r)) }
      end

      def pixel_summary(res)
        { sha256: res[:sha256], width: res[:width], height: res[:height], bpp: res[:bpp], row_padding: res[:row_padding] }
      end

      def phase_skp_pixels
        @model.materials.each_with_index do |m, i|
          t = m.texture
          next if t.nil?

          row = @tables[:materials][i]
          # Each side is canonicalised on its own: a failure of the side the
          # comparator does not need (review F1) must not hide the needed one.
          both = {}
          [true, false].each do |flag|
            rep = nil
            begin
              rep = timed(:"image_rep_#{flag}") { t.image_rep(flag) }
              data = timed(:image_rep_data) { rep.data }
              detail = [m.name.to_s, flag, rep.width, rep.height, rep.bits_per_pixel]
              res = Canonical.canonical_rgba_sha(width: rep.width, height: rep.height, bits_per_pixel: rep.bits_per_pixel,
                                                 row_padding: rep.row_padding, data: data) do |y|
                @ctx = ['skp_pixels', nil, 'material', i, Sketchup::Material, detail + [y]]
                boundary
              end
              both[flag.to_s] = pixel_summary(res)
            rescue Cancelled
              raise
            rescue StandardError => e
              both[flag.to_s] = { status: 'FAIL', code: 'skp_image_rep_error', message: "#{e.class}: #{e.message}", flag: flag,
                                  bits_per_pixel: (rep.bits_per_pixel if rep), row_padding: (rep.row_padding if rep) }
            end
          end
          row[:pixels] = both
          boundary
        end
      end

      def phase_bomc_pixels
        tables = JSON.parse(File.read(File.join(@run_dir, 'bomc', 'tables.json')))
        tables['textures'].each do |tex|
          pixel = tex['pixel']
          next unless pixel && pixel['status'] == 'PENDING_SKETCHUP'

          jcm = tex['media_type'] == 'jpeg_color_map'
          file = jcm ? pixel['jcm_jpeg'] : tex['file']
          path = File.join(@run_dir, 'bomc', 'textures', file)
          begin
            rep = Sketchup::ImageRep.new
            timed(:load_file) { rep.load_file(path) }
            data = timed(:image_rep_data) { rep.data }
            detail = [tex['index'], file, rep.width, rep.height, rep.bits_per_pixel]
            res = Canonical.canonical_rgba_sha(width: rep.width, height: rep.height, bits_per_pixel: rep.bits_per_pixel,
                                               row_padding: rep.row_padding, data: data, keep: jcm) do |y|
              @ctx = ['bomc_pixels', nil, 'texture', tex['index'], Sketchup::ImageRep, detail + [y]]
              boundary
            end
            if jcm
              File.open(File.join(@skp_dir, 'jcm-base', "#{tex['index']}.rgba"), File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) { |f| f.write(res[:bytes]) }
            end
            @pix_io.write(jline({ index: tex['index'], status: 'OK' }.merge(pixel_summary(res))))
          rescue Cancelled
            raise
          rescue StandardError => e
            @pix_io.write(jline(index: tex['index'], status: 'FAIL', code: 'bomc_imagerep_load_error', message: "#{e.class}: #{e.message}"))
          end
          boundary
        end
      end
    end
  end
end
