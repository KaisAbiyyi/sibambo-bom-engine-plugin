# Cooperative export runner for SketchUp's single UI thread.

require 'json'

module SibamboHistory
  module V20260827_02
  class ConversionJob
    class Cancelled < StandardError; end

    TIMER_INTERVAL_SECONDS = 0.04

    class << self
      attr_reader :active

      def start(title:, output_path:, batch_size: nil, &work)
        if @active && @active.running?
          UI.messagebox('Proses converting lain masih berjalan.', MB_OK)
          return @active
        end

        job = new(title: title, output_path: output_path, batch_size: batch_size, &work)
        @active = job
        job.start
      end

      def release(job)
        @active = nil if @active.equal?(job)
      end
    end

    def initialize(title:, output_path:, batch_size: nil, &work)
      @title = title
      @output_path = output_path
      @batch_size = batch_size
      @work = work
      @cancel_requested = false
      @finished = false
      @timer_id = nil
      @started_at = nil
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
        width: 440,
        height: 330,
        min_width: 360,
        min_height: 280,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(File.dirname(__FILE__), 'ui', 'conversion_dialog.html'))
      @dialog.add_action_callback('cancel') { |_ctx| cancel }
      @dialog.add_action_callback('close') { |_ctx| @dialog.close }
      @dialog.add_action_callback('openFolder') do |_ctx|
        directory = File.dirname(@output_path)
        UI.openURL("file:///#{directory.tr('\\', '/')}") if Dir.exist?(directory)
      end
      @dialog.add_action_callback('ready') do |_ctx|
        execute("initializeConversion(#{JSON.generate(title: @title, output_path: @output_path, batch_size: @batch_size)})")
      end
      @dialog.set_on_closed { cancel unless @finished }
    end

    def checkpoint(event = {})
      raise Cancelled, 'Export dibatalkan.' if @cancel_requested

      Fiber.yield([:progress, event || {}])
      raise Cancelled, 'Export dibatalkan.' if @cancel_requested
    end

    def tick
      return finish_timer if @finished

      outcome = @fiber.resume
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
      data = {
        stage: event[:stage] || event['stage'] || 'Converting model',
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
      stats = result[:validation] || {}
      data = {
        path: result[:path],
        bytes: result[:bytes],
        source_bytes: result.dig(:source_info, :bytes),
        savings_bytes: result[:status] == :pass ? result[:savings_bytes] : nil,
        gate_status: result[:status],
        strategy: result[:strategy],
        mode: result[:mode],
        elapsed_seconds: elapsed_seconds,
        nodes: stats[:nodes],
        triangles: stats[:triangles]
      }
      execute("completeConversion(#{JSON.generate(data)})")
      self.class.release(self)
    end

    def cancelled(_error)
      finish_timer
      @finished = true
      execute('cancelledConversion()')
      self.class.release(self)
    end

    def failed(error)
      finish_timer
      @finished = true
      Logger.error("Model-Eval cooperative export failed: #{error.message}\n#{Array(error.backtrace).first(8).join("\n")}")
      execute("failConversion(#{JSON.generate(message: error.message)})")
      self.class.release(self)
    end

    def finish_timer
      return if @timer_id.nil?

      UI.stop_timer(@timer_id)
      @timer_id = nil
    end

    def elapsed_seconds
      return 0.0 if @started_at.nil?

      (Time.now - @started_at).round(1)
    end

    def execute(script)
      @dialog.execute_script(script)
    rescue StandardError
      nil
    end
  end
end

end # SibamboHistory
