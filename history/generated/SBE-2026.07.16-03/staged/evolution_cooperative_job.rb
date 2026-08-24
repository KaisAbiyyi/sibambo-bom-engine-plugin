# frozen_string_literal: true

require 'json'

module SibamboHistory
  module V20260716_03
    module EvolutionCooperativeJob
      class << self
        def start(title:, batch_size:, &work)
          return UI.messagebox('Exporter ini masih berjalan.') if @running

          @running = true
          @ticking = false
          @batch_size = batch_size
          @fiber = Fiber.new do
            begin
              [:complete, work.call(method(:checkpoint))]
            rescue StandardError => error
              [:error, error]
            end
          end
          build_dialog(title)
          @dialog.show
          @timer_id = UI.start_timer(0.04, true) { tick }
          self
        end

        def checkpoint(event = {})
          Fiber.yield(event || {})
        end

        def tick
          return if @ticking

          @ticking = true
          begin
            outcome = @fiber.resume
            unless outcome.is_a?(Array) && [:complete, :error].include?(outcome[0])
              update(outcome)
              return
            end

            status, value = outcome
            finish
            UI.messagebox("Export gagal:
#{value.message}") if status == :error
          rescue StandardError => error
            finish
            UI.messagebox("Export gagal:
#{error.message}")
          ensure
            @ticking = false
          end
        end

        def build_dialog(title)
          @dialog&.close
          @dialog = UI::HtmlDialog.new(
            dialog_title: "#{title} — Batch #{@batch_size}",
            scrollable: true,
            resizable: true,
            width: 460,
            height: 260,
            min_width: 380,
            min_height: 220,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          @dialog.set_html(<<~HTML)
            <!doctype html><meta charset="utf-8"><style>
            body{font:14px system-ui;background:#17202a;color:#eef;padding:20px}h2{color:#4fffb0;margin-top:0}
            #status{white-space:pre-wrap;line-height:1.5;color:#b8c7d6}
            </style><h2>Current Model Export</h2><div id="status">Menyiapkan batch #{@batch_size}…</div>
          HTML
          @dialog.set_on_closed { nil }
        end

        def update(event)
          data = event.is_a?(Hash) ? event : {}
          text = "#{data[:stage] || 'Memproses model'}
Processed: #{data[:processed] || 0}
Batch: #{@batch_size}"
          @dialog.execute_script("document.getElementById('status').textContent=#{JSON.generate(text)}")
        end

        def finish
          UI.stop_timer(@timer_id) if @timer_id
          @dialog.close if @dialog
          @running = false
          @fiber = nil
          @timer_id = nil
        end
      end
    end
  end
end
