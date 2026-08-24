# frozen_string_literal: true

require 'json'

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    # Runs one clean export cooperatively on SketchUp's single UI thread.
    class ConversionJob
      class Cancelled < StandardError; end

      TIMER_INTERVAL_SECONDS = 0.04

      class << self
        attr_reader :active

        def start(title:, output_path:, batch_size: nil, &work)
          if @active && @active.running?
            UI.messagebox('Proses clean export lain masih berjalan.')
            return @active
          end

          job = new(
            title: title,
            output_path: output_path,
            batch_size: batch_size,
            &work
          )
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
            [:success, @work.call(method(:checkpoint))]
          rescue Cancelled => error
            [:cancelled, error]
          rescue StandardError => error
            [:error, error]
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
        @dialog.add_action_callback('cancel') { |_context| cancel }
        @dialog.add_action_callback('close') { |_context| @dialog.close }
        @dialog.add_action_callback('openFolder') do |_context|
          directory = File.dirname(@output_path)
          UI.openURL("file:///#{directory.tr('\\', '/')}") if Dir.exist?(directory)
        end
        @dialog.add_action_callback('ready') do |_context|
          execute(
            "initializeConversion(#{JSON.generate(
              title: @title,
              output_path: @output_path,
              batch_size: @batch_size
            )})"
          )
        end
        @dialog.set_on_closed { cancel unless @finished }
      end

      def checkpoint(event = {})
        raise Cancelled, 'Export dibatalkan.' if @cancel_requested

        Fiber.yield(event || {})
        raise Cancelled, 'Export dibatalkan.' if @cancel_requested
      end

      def tick
        return finish_timer if @finished

        outcome = @fiber.resume
        terminal = outcome.is_a?(Array) &&
                   %i[success cancelled error].include?(outcome.first)
        unless terminal
          update_progress(outcome)
          return
        end

        status, value = outcome
        case status
        when :success then complete(value)
        when :cancelled then cancelled
        else failed(value)
        end
      rescue StandardError => error
        failed(error)
      end

      def update_progress(event)
        data = {
          stage: event[:stage] || event['stage'] || 'Converting model',
          processed: event[:processed] || event['processed'] || 0,
          elapsed_seconds: elapsed_seconds
        }
        execute("updateProgress(#{JSON.generate(data)})")
      end

      def complete(result)
        finish_timer
        @finished = true
        counts = result.fetch(:counts, {})
        execute(
          "completeConversion(#{JSON.generate(
            path: result[:path],
            bytes: result[:bytes],
            elapsed_seconds: elapsed_seconds,
            surfaces: counts['architectural_surface_count'],
            components: counts['component_count'],
            excluded: counts['excluded_object_count']
          )})"
        )
        self.class.release(self)
      end

      def cancelled
        finish_timer
        @finished = true
        execute('cancelledConversion()')
        self.class.release(self)
      end

      def failed(error)
        finish_timer
        @finished = true
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
end

end # SibamboHistory
