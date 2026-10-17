# Cooperative export runner for SketchUp's single UI thread.

require 'json'
require 'uri'
require_relative 'performance_trace'

module BOMEngine
  class ConversionJob
    class Cancelled < StandardError; end

    TIMER_INTERVAL_SECONDS = 0.001
    UI_PROGRESS_INTERVAL_SECONDS = 0.10

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

    attr_reader :generation_id, :performance_metrics

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
      @last_ui_stage = nil
      @generation_id = self.class.next_generation
      @last_tick_at = nil
      @last_checkpoint_at = nil
      @performance_metrics = {
        generation_id: @generation_id,
        slice_count: 0,
        checkpoint_count: 0,
        ui_update_count: 0,
        total_slice_ms: 0.0,
        max_slice_ms: 0.0,
        max_tick_delay_ms: 0.0,
        max_checkpoint_gap_ms: 0.0,
        max_ui_heartbeat_delay_ms: 0.0
      }
      build_dialog
    end

    def running?
      !@finished
    end

    def start
      @started_at = Time.now
      @fiber = Fiber.new do
        begin
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
      execute('setCancelling()')
    end

    private

    def build_dialog
      @dialog = UI::HtmlDialog.new(
        dialog_title: @title,
        scrollable: true,
        resizable: true,
        width: 620,
        height: 380,
        min_width: 420,
        min_height: 320,
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
        execute("initializeConversion(#{JSON.generate(title: @title, output_path: @output_path, batch_size: @batch_size, capture: @kind == :capture, batch_export: @kind == :batch_export)})")
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

      Fiber.yield([:progress, event || {}])
      raise Cancelled, 'Export dibatalkan.' if @cancel_requested
    end

    def tick
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
      if outcome.is_a?(Array) && outcome[0] == :progress
        update_progress(outcome[1])
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

    def update_progress(event)
      @result_path = event[:output_directory] || event['output_directory'] if @kind == :batch_export && (event[:output_directory] || event['output_directory'])
      stage = event[:stage] || event['stage'] || 'Converting model'
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      force_ui = stage.to_s != @last_ui_stage.to_s || event[:force] == true || event['force'] == true
      return unless force_ui || (now - @last_ui_progress_at) >= UI_PROGRESS_INTERVAL_SECONDS

      @last_ui_progress_at = now
      @last_ui_stage = stage
      @performance_metrics[:ui_update_count] += 1
      if @previous_ui_update_at
        heartbeat_delay_ms = [((now - @previous_ui_update_at) - UI_PROGRESS_INTERVAL_SECONDS) * 1000.0, 0.0].max
        @performance_metrics[:max_ui_heartbeat_delay_ms] = [@performance_metrics[:max_ui_heartbeat_delay_ms], heartbeat_delay_ms].max
      end
      @previous_ui_update_at = now
      data = {
        stage: stage,
        profile: event[:profile] || event['profile'],
        processed: event[:processed] || event['processed'] || 0,
        total: event[:total] || event['total'] || 0,
        percent: event[:percent] || event['percent'] || 0.0,
        mode: event[:mode] || event['mode'],
        source_bytes: event[:source_bytes] || event['source_bytes'],
        candidate_bytes: event[:candidate_bytes] || event['candidate_bytes'],
        savings_bytes: event[:savings_bytes] || event['savings_bytes'],
        elapsed_seconds: elapsed_seconds
      }
      execute("updateProgress(#{JSON.generate(data)})")
    end

    def complete(result)
      finish_timer
      @finished = true
      finalize_performance_metrics
      persist_performance_metrics(result)
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
      execute("completeConversion(#{JSON.generate(data)})")
      self.class.release(self)
    end

    def cancelled(_error)
      finish_timer
      @finished = true
      finalize_performance_metrics
      resize_result(450)
      execute("cancelledConversion(#{JSON.generate(path: @result_path || @output_path, capture: @kind == :capture, batch_export: @kind == :batch_export, partial_result: @kind == :batch_export && !@result_path.nil?)})")
      self.class.release(self)
    end

    def failed(error)
      finish_timer
      @finished = true
      finalize_performance_metrics
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
      execute("failConversion(#{JSON.generate(message: "#{error.class}: #{error.message}", path: display_path, capture: @kind == :capture, batch_export: @kind == :batch_export, partial_result: @kind == :batch_export && !@result_path.nil?)})")
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

    def execute(script)
      @dialog.execute_script(script)
    rescue StandardError
      nil
    end
  end
end
