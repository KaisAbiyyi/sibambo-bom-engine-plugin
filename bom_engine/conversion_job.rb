# Cooperative export runner for SketchUp's single UI thread.

require 'json'
require 'uri'

module BOMEngine
  class ConversionJob
    class Cancelled < StandardError; end

    TIMER_INTERVAL_SECONDS = 0.01

    class << self
      attr_reader :active

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
      @result_path = event[:output_directory] || event['output_directory'] if @kind == :batch_export && (event[:output_directory] || event['output_directory'])
      data = {
        stage: event[:stage] || event['stage'] || 'Converting model',
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
      resize_result(450)
      execute("cancelledConversion(#{JSON.generate(path: @result_path || @output_path, capture: @kind == :capture, batch_export: @kind == :batch_export, partial_result: @kind == :batch_export && !@result_path.nil?)})")
      self.class.release(self)
    end

    def failed(error)
      finish_timer
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

    def execute(script)
      @dialog.execute_script(script)
    rescue StandardError
      nil
    end
  end
end
