# Cooperative export runner for SketchUp's single UI thread.

require 'json'
require 'uri'
require_relative 'performance_trace'

module BOMEngine
  class ConversionJob
    class Cancelled < StandardError; end

    TIMER_INTERVAL_SECONDS = 0.001
    UI_PROGRESS_INTERVAL_SECONDS = 0.10
    ACTIVE_STATES = [:created, :capturing, :compiling, :validating, :publishing, :completed].freeze
    TERMINAL_STATES = [:completed, :cancelled, :failed].freeze

    class << self
      attr_reader :active

      def next_generation
        @generation_sequence = @generation_sequence.to_i + 1
      end

      def start(title:, output_path:, batch_size: nil, kind: :export, &work)
        if @active && @active.running?
          UI.messagebox('Proses converting lain masih berjalan.', MB_OK)
          return @active
        end

        job = new(title: title, output_path: output_path, batch_size: batch_size, kind: kind, &work)
        @active = job
        job.start
      end

      def release(job)
        @active = nil if @active.equal?(job)
      end
    end

    attr_reader :generation_id, :performance_metrics, :state, :event_sequence, :state_history

    def initialize(title:, output_path:, batch_size: nil, kind: :export, &work)
      @title = title
      @output_path = output_path
      @batch_size = batch_size
      @kind = kind
      @work = work
      @cancel_requested = false
      @finished = false
      @timer_id = nil
      @started_at = nil
      @result_path = nil
      @last_ui_progress_at = 0.0
      @dialog_ready = false
      @pending_ui_event = nil
      @pending_ui_event_queued_at = nil
      @progress_passes = {}
      @generation_id = self.class.next_generation
      @event_sequence = 0
      @state = :created
      @state_history = [{ state: @state, at_ms: 0.0 }]
      @last_tick_at = nil
      @last_checkpoint_at = nil
      @performance_metrics = {
        generation_id: @generation_id,
        event_sequence: 0,
        state: @state,
        slice_count: 0,
        checkpoint_count: 0,
        ui_update_count: 0,
        coalesced_ui_event_count: 0,
        total_slice_ms: 0.0,
        max_slice_ms: 0.0,
        max_tick_delay_ms: 0.0,
        max_checkpoint_gap_ms: 0.0,
        max_ui_heartbeat_delay_ms: 0.0,
        max_ui_event_queue_age_ms: 0.0
      }
      build_dialog
    end

    def running?
      !@finished
    end

    def start
      @started_at = Time.now
      @monotonic_started_at = monotonic_seconds
      transition_state(:capturing)
      @fiber = Fiber.new do
        begin
          raise Cancelled, 'Export dibatalkan.' if @cancel_requested
          result = @work.call(method(:checkpoint))
          [:finished, :success, result]
        rescue Cancelled => error
          [:finished, :cancelled, error]
        rescue StandardError => error
          [:finished, :error, error]
        end
      end
      @dialog.center
      @dialog.show
      @timer_id = UI.start_timer(TIMER_INTERVAL_SECONDS, true) { tick }
      self
    end

    def cancel
      return if @finished

      @cancel_requested = true
      transition_state(:cancelling)
      enqueue_ui_event(stage: 'Menghentikan proses dengan aman…', force: true)
      flush_pending_ui_event(force: true)
    end

    private

    def build_dialog
      @dialog = UI::HtmlDialog.new(
        dialog_title: @title,
        scrollable: true,
        resizable: true,
        width: 620,
        height: 540,
        min_width: 420,
        min_height: 440,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(File.dirname(__FILE__), 'ui', 'conversion_dialog.html'))
      @dialog.add_action_callback('cancel') { |_ctx| cancel }
      @dialog.add_action_callback('close') { |_ctx| @dialog.close }
      @dialog.add_action_callback('openFolder') do |_ctx|
        directory = if @kind == :capture
                      @output_path
                    elsif @kind == :batch_export
                      @result_path || File.dirname(@output_path)
                    else
                      File.dirname(@output_path)
                    end
        UI.openURL("file:///#{URI::DEFAULT_PARSER.escape(directory.tr('\\', '/'))}") if Dir.exist?(directory)
      end
      @dialog.add_action_callback('ready') do |_ctx|
        @dialog_ready = true
        data = event_envelope(
          title: @title,
          output_path: @output_path,
          batch_size: @batch_size,
          capture: @kind == :capture,
          batch_export: @kind == :batch_export
        )
        execute("initializeConversion(#{JSON.generate(data)})")
        requeue_pending_event_after_initialize
        flush_pending_ui_event(force: true)
      end
      @dialog.set_on_closed { cancel unless @finished }
    end

    def checkpoint(event = {})
      raise Cancelled, 'Export dibatalkan.' if @cancel_requested

      now = monotonic_seconds
      if @last_checkpoint_at
        gap_ms = (now - @last_checkpoint_at) * 1000.0
        @performance_metrics[:max_checkpoint_gap_ms] = [@performance_metrics[:max_checkpoint_gap_ms], gap_ms].max
      end
      @last_checkpoint_at = now
      @performance_metrics[:checkpoint_count] += 1

      payload = event || {}
      transition_state(state_for_event(payload))
      enqueue_ui_event(payload)
      Fiber.yield([:checkpoint])
      raise Cancelled, 'Export dibatalkan.' if @cancel_requested
    end

    def tick
      # SketchUp may dispatch the repeating timer again while the current
      # resume is inside a native UI/Logger callback. A Fiber cannot resume
      # itself; defer the nested tick to the next scheduled callback.
      return if @in_tick
      @in_tick = true
      begin
        run_tick
      ensure
        @in_tick = false
      end
    end

    def run_tick
      return finish_timer if @finished

      tick_started = monotonic_seconds
      if @last_tick_at
        delay_ms = [((tick_started - @last_tick_at) - TIMER_INTERVAL_SECONDS) * 1000.0, 0.0].max
        @performance_metrics[:max_tick_delay_ms] = [@performance_metrics[:max_tick_delay_ms], delay_ms].max
      end
      @last_tick_at = tick_started
      outcome = nil
      begin
        outcome = @fiber.resume
      ensure
        slice_ms = [(monotonic_seconds - tick_started) * 1000.0, 0.0].max
        @performance_metrics[:slice_count] += 1
        @performance_metrics[:total_slice_ms] += slice_ms
        @performance_metrics[:max_slice_ms] = [@performance_metrics[:max_slice_ms], slice_ms].max
      end
      flush_pending_ui_event
      if outcome.is_a?(Array) && outcome[0] == :checkpoint
        return
      end

      marker, status, value = outcome
      raise 'Cooperative conversion returned an invalid outcome.' unless marker == :finished
      case status
      when :success then complete(value)
      when :cancelled then cancelled(value)
      else failed(value)
      end
    rescue StandardError => error
      failed(error)
    end

    def enqueue_ui_event(event)
      @result_path = event[:output_directory] || event['output_directory'] if @kind == :batch_export && (event[:output_directory] || event['output_directory'])
      stage = event[:stage] || event['stage'] || 'Converting model'
      stage_key = stage.to_s.downcase
      profile = event[:profile] || event['profile']
      phase_id = if stage_key == 'snapshot_textures'
                   'textures'
                 elsif [:compiling, :validating, :publishing].include?(@state)
                   @state.to_s == 'compiling' ? 'compile' : @state.to_s == 'validating' ? 'validate' : 'publish'
                 else
                   'capture'
                 end
      raw_processed = event.key?(:processed) ? event[:processed] : event['processed']
      raw_total = event.key?(:total) ? event[:total] : event['total']
      counter_key = [phase_id, profile.to_s, stage_key]
      pass = (@progress_passes[counter_key] ||= { index: 1, previous: nil })
      if raw_processed.is_a?(Numeric) && pass[:previous] && raw_processed < pass[:previous]
        pass[:index] += 1
      end
      pass[:previous] = raw_processed if raw_processed.is_a?(Numeric)
      unit = event[:unit] || event['unit'] || (stage_key == 'snapshot_textures' || stage_key == 'snapshot_materials' ? 'material' :
        stage_key == 'snapshot_entities' ? 'entitas' : 'langkah')
      data = {
        stage: stage,
        phase: @state,
        phase_id: phase_id,
        pass_id: "#{stage_key}-#{pass[:index]}",
        pass_index: pass[:index],
        operation_label: event[:operation_label] || event['operation_label'] || event[:material_name] || event['material_name'],
        unit: unit,
        profile: profile,
        processed: raw_processed,
        total: raw_total,
        percent: event[:percent] || event['percent'] || 0.0,
        mode: event[:mode] || event['mode'],
        source_bytes: event[:source_bytes] || event['source_bytes'],
        candidate_bytes: event[:candidate_bytes] || event['candidate_bytes'],
        savings_bytes: event[:savings_bytes] || event['savings_bytes'],
        elapsed_seconds: elapsed_seconds
      }
      @performance_metrics[:coalesced_ui_event_count] += 1 if @pending_ui_event
      @pending_ui_event = event_envelope(data)
      @pending_ui_event_queued_at = monotonic_seconds
      @pending_ui_event
    end

    def flush_pending_ui_event(force: false)
      return if @pending_ui_event.nil? || !@dialog_ready

      now = monotonic_seconds
      return unless force || @last_ui_progress_at.zero? || (now - @last_ui_progress_at) >= UI_PROGRESS_INTERVAL_SECONDS

      queued_at = @pending_ui_event_queued_at || now
      queue_age_ms = [(now - queued_at) * 1000.0, 0.0].max
      @performance_metrics[:max_ui_event_queue_age_ms] = [@performance_metrics[:max_ui_event_queue_age_ms], queue_age_ms].max
      if @previous_ui_update_at
        heartbeat_delay_ms = [((now - @previous_ui_update_at) - UI_PROGRESS_INTERVAL_SECONDS) * 1000.0, 0.0].max
        @performance_metrics[:max_ui_heartbeat_delay_ms] = [@performance_metrics[:max_ui_heartbeat_delay_ms], heartbeat_delay_ms].max
      end
      @previous_ui_update_at = now
      @last_ui_progress_at = now
      @performance_metrics[:ui_update_count] += 1
      data = @pending_ui_event
      @pending_ui_event = nil
      @pending_ui_event_queued_at = nil
      execute("updateProgress(#{JSON.generate(data)})")
    end

    def requeue_pending_event_after_initialize
      return if @pending_ui_event.nil?

      pending = @pending_ui_event.dup
      pending.delete(:job_id)
      pending.delete(:sequence)
      pending.delete(:state)
      @pending_ui_event = event_envelope(pending)
      @pending_ui_event_queued_at = monotonic_seconds
    end

    def complete(result)
      finish_timer
      flush_pending_ui_event(force: true)
      transition_state(:publishing)
      transition_state(:completed)
      @finished = true
      @result_path = result[:path] if @kind == :batch_export
      resize_result(650)
      stats = result[:validation] || {}
      metrics = result[:metrics] || {}
      texture_metrics = metrics[:textures] || {}
      encodings = texture_metrics[:encodings] || {}
      jcm = encodings[:jpeg_color_map] || encodings['jpeg_color_map'] || {}
      semantic_rows = Array(texture_metrics[:evidence]).map do |outer|
        outer && outer.dig(:staging, :policy_revision) ? outer[:staging] : outer
      end.compact.select { |ev| ev[:selected] == :semantic_colorized_native }
      texture_encodings = encodings.map do |name, values|
        { name: name.to_s, count: (values[:count] || values['count']).to_i,
          bytes: (values[:bytes] || values['bytes']).to_i }
      end.sort_by { |row| -row[:bytes] }
      top_sections = (metrics[:sections] || {}).map do |name, values|
        { name: name.to_s, stored_bytes: values[:stored_bytes].to_i, raw_bytes: values[:raw_bytes].to_i }
      end.sort_by { |row| -row[:stored_bytes] }.first(3)
      data = {
        path: result[:path],
        bytes: result[:bytes],
        source_bytes: result.dig(:source_info, :bytes),
        source_path: result.dig(:source_info, :path),
        savings_bytes: result[:savings_bytes],
        gate_status: result[:status],
        strategy: result[:strategy],
        profile: result[:profile],
        mode: result[:mode],
        elapsed_seconds: elapsed_seconds,
        nodes: stats[:nodes],
        triangles: stats[:triangles],
        texture_bytes: texture_metrics[:bytes],
        texture_unique: texture_metrics[:unique],
        texture_references: texture_metrics[:references],
        jcm_count: jcm[:count] || jcm['count'],
        jcm_bytes: jcm[:bytes] || jcm['bytes'],
        semantic_colorize_count: semantic_rows.length,
        semantic_colorize_bytes: semantic_rows.sum { |ev| ev[:candidate_bytes].to_i },
        texture_encodings: texture_encodings,
        largest_textures: Array(texture_metrics[:largest]),
        top_sections: top_sections
      }
      data[:capture] = true if @kind == :capture
      data[:batch_export] = true if @kind == :batch_export
      data[:profiles] = result[:profiles] if result[:profiles]
      terminal_event = event_envelope(data)
      finalize_performance_metrics
      persist_performance_metrics(result)
      execute("completeConversion(#{JSON.generate(terminal_event)})")
      self.class.release(self)
    end

    def cancelled(_error)
      finish_timer
      transition_state(:cancelling)
      flush_pending_ui_event(force: true)
      transition_state(:cancelled)
      @finished = true
      resize_result(450)
      data = {
        path: @result_path || @output_path,
        capture: @kind == :capture,
        batch_export: @kind == :batch_export,
        partial_result: @kind == :batch_export && !@result_path.nil?
      }
      terminal_event = event_envelope(data)
      finalize_performance_metrics
      execute("cancelledConversion(#{JSON.generate(terminal_event)})")
      self.class.release(self)
    end

    def failed(error)
      finish_timer
      flush_pending_ui_event(force: true)
      transition_state(:failed)
      @finished = true
      resize_result(500)
      detail = "#{error.class}: #{error.message}\n#{Array(error.backtrace).first(20).join("\n")}"
      Logger.error("Model-Eval cooperative export failed: #{detail}")
      @result_path = error.directory if @kind == :batch_export && error.respond_to?(:directory)
      display_path = @result_path || @output_path
      begin
        log_path = @kind == :batch_export && @result_path ? File.join(@result_path, 'export-error.log') : "#{@output_path}.error.log"
        File.write(log_path, detail, encoding: 'UTF-8')
      rescue StandardError
        nil
      end
      data = {
        message: "#{error.class}: #{error.message}",
        path: display_path,
        capture: @kind == :capture,
        batch_export: @kind == :batch_export,
        partial_result: @kind == :batch_export && !@result_path.nil?
      }
      terminal_event = event_envelope(data)
      finalize_performance_metrics
      execute("failConversion(#{JSON.generate(terminal_event)})")
      self.class.release(self)
    end

    def finish_timer
      return if @timer_id.nil?

      UI.stop_timer(@timer_id)
      @timer_id = nil
    end

    def resize_result(height)
      @dialog.set_size(620, height)
      @dialog.center
    end

    def elapsed_seconds
      return 0.0 if @started_at.nil?

      (Time.now - @started_at).round(1)
    end

    def finalize_performance_metrics
      slices = @performance_metrics[:slice_count].to_i
      @performance_metrics[:mean_slice_ms] = slices.positive? ? (@performance_metrics[:total_slice_ms].to_f / slices) : 0.0
      @performance_metrics[:event_sequence] = @event_sequence
      @performance_metrics[:state] = @state
      @performance_metrics[:state_history] = @state_history.map(&:dup)
      @performance_metrics.each do |key, value|
        @performance_metrics[key] = value.round(3) if value.is_a?(Float)
      end
      @performance_metrics
    end

    def persist_performance_metrics(result)
      return unless result.is_a?(Hash)
      path = result[:performance_receipt_path] || result['performance_receipt_path']
      return if path.to_s.empty?

      PerformanceTrace.merge_receipt_metadata(path, conversion_job: @performance_metrics)
    rescue StandardError
      # Telemetry must never change export success/failure semantics.
      nil
    end

    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def transition_state(target)
      target = target.to_sym
      return @state if @state == target || TERMINAL_STATES.include?(@state)
      return @state if @state == :cancelling && ACTIVE_STATES.include?(target)

      if ACTIVE_STATES.include?(target)
        current_index = ACTIVE_STATES.index(@state)
        target_index = ACTIVE_STATES.index(target)
        return @state if current_index && target_index && target_index <= current_index
        start_index = current_index ? current_index + 1 : 0
        ACTIVE_STATES[start_index..target_index].to_a.each { |value| record_state(value) }
      elsif target == :cancelling
        record_state(:cancelling)
      elsif target == :cancelled
        record_state(:cancelling) unless @state == :cancelling
        record_state(:cancelled)
      elsif target == :failed
        record_state(:failed)
      else
        raise ArgumentError, "Unknown conversion state #{target}."
      end
      @state
    end

    def record_state(value)
      @state = value
      elapsed_ms = @monotonic_started_at ? (monotonic_seconds - @monotonic_started_at) * 1000.0 : 0.0
      @state_history << { state: value, at_ms: [elapsed_ms, 0.0].max.round(3) }
      @performance_metrics[:state] = value
    end

    def state_for_event(event)
      explicit = event[:phase] || event['phase']
      return normalize_active_state(explicit) if explicit

      stage = (event[:stage] || event['stage']).to_s.upcase
      return :publishing if stage.match?(/PUBLISH|WRITE_CONTAINER|DONE/)
      return :validating if stage.match?(/VALIDAT|READBACK|FIDELITY/)
      return :compiling if stage.match?(/COMPILE|BUILD_|ENCODE|COMPRESS|SIZE_GATE|CANDIDATE|SERIALIZ|WRITER/)

      :capturing
    end

    def normalize_active_state(value)
      state = value.to_s.downcase.to_sym
      return state if ACTIVE_STATES.include?(state) && state != :completed

      :capturing
    end

    def event_envelope(data = {})
      @event_sequence += 1
      @performance_metrics[:event_sequence] = @event_sequence
      data.merge(job_id: @generation_id, sequence: @event_sequence, state: @state)
    end

    def execute(script)
      @dialog.execute_script(script)
    rescue StandardError
      nil
    end
  end
end
