# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module SibamboHistory
  module EvolutionLab
    # Serial, crash-resumable batch runner for the historical exporter matrix.
    # SketchUp is single-threaded, so work is deliberately sliced between files.
    module BatchRunner
      SOURCE_DIR = 'D:/projects/sibambo/model-eval/skps'.freeze
      OUTPUT_DIR = File.join(SOURCE_DIR, 'evolution-exports').freeze
      STATUS_PATH = File.join(OUTPUT_DIR, 'batch-status.json').freeze
      MODEL_PATTERN = /\A(?:PROJECT SBOOST \d+|RUMAH [A-Z])\.skp\z/i

      FORMATS = [
        { id: '01', label: 'Original BOM JSON', engine: '2026_05_11_01' },
        { id: '02', label: 'Visual JSON', engine: '2026_05_11_02' },
        { id: '03', label: 'Minified Visual JSON', engine: '2026_05_11_03' },
        { id: '04', label: 'Canonical JSON v3 + Gzip', engine: '2026_07_16_01' },
        { id: '05', label: 'Model-Eval Compact JSON', engine: '2026_07_16_02' },
        { id: '06', label: 'BOME2 Binary Runtime', engine: '2026_07_16_03' },
        { id: '07', label: 'CleanPKG Binary Container', engine: '2026_08_12_01' },
        { id: '08', label: 'First BOMC Compiled Format', engine: '2026_08_13_01' },
        { id: '09', label: 'Scene/Page-Preserving BOMC', engine: '2026_08_19_01' }
      ].freeze

      class << self
        def start_or_resume
          return if @running

          FileUtils.mkdir_p(OUTPUT_DIR)
          @tasks = build_tasks
          @status = load_status
          @status['status'] = 'running'
          @status['started_at'] ||= Time.now.iso8601
          @status['completed'] ||= []
          @status['failed'] ||= []
          @attempted = {}
          @cancel_requested = false
          @running = true
          build_dialog
          persist_status
          schedule(0.1) { advance }
        rescue StandardError => error
          @running = false
          UI.messagebox("Evolution batch gagal dimulai:\n#{error.message}", MB_OK)
        end

        def resume_if_pending
          return unless File.file?(STATUS_PATH)

          status = JSON.parse(File.read(STATUS_PATH, encoding: 'UTF-8'))
          return unless status['status'] == 'running'

          status['status'] = 'paused_after_restart'
          status['updated_at'] = Time.now.iso8601
          File.write(STATUS_PATH, JSON.pretty_generate(status), mode: 'w:UTF-8')
          Sketchup.set_status_text('Evolution batch dipause setelah restart; klik menu batch untuk resume.')
        rescue StandardError
          nil
        end

        def running?
          @running == true
        end

        def cancel
          @cancel_requested = true
          update_dialog('Cancelling after current exporter finishes...')
        end

        private

        def build_tasks
          models = Dir.glob(File.join(SOURCE_DIR, '*.skp')).select do |path|
            File.basename(path).match?(MODEL_PATTERN)
          end.sort_by { |path| [File.size(path), File.basename(path).downcase] }

          models.flat_map do |model_path|
            FORMATS.map do |format|
              model_name = File.basename(model_path, '.skp')
              output_dir = File.join(OUTPUT_DIR, model_name, "[#{format[:id]}] #{format[:label]}")
              format.merge(
                model_path: model_path,
                model_name: model_name,
                output_dir: output_dir,
                output_path: output_path_for(output_dir, model_name, format[:id])
              )
            end
          end
        end

        def output_path_for(directory, model_name, id)
          prefix = "[#{id}] #{model_name}"
          case id
          when '01' then File.join(directory, "#{prefix}__SBE-2026.05.11-01_bom.json")
          when '02' then File.join(directory, "#{prefix}__SBE-2026.05.11-02_visual.json")
          when '03' then File.join(directory, "#{prefix}__SBE-2026.05.11-03_visual.json")
          when '04' then File.join(directory, "#{prefix}__SBE-2026.07.16-01_canonical.json.gz")
          when '05' then File.join(directory, "#{prefix}__SBE-2026.07.16-02_model-eval.json")
          when '06' then File.join(directory, "#{prefix}__SBE-2026.07.16-03_runtime.bome2")
          when '07' then File.join(directory, "#{prefix}__SBE-2026.08.12-01.cleanpkg")
          when '08' then File.join(directory, "#{prefix}__SBE-2026.08.13-01.bomc")
          when '09' then File.join(directory, "#{prefix}__SBE-2026.08.19-01.bomc")
          end
        end

        def task_key(task)
          "#{task[:model_name]}|#{task[:id]}"
        end

        def load_status
          return {} unless File.file?(STATUS_PATH)

          JSON.parse(File.read(STATUS_PATH, encoding: 'UTF-8'))
        rescue StandardError
          {}
        end

        def persist_status
          @status['updated_at'] = Time.now.iso8601
          temporary = "#{STATUS_PATH}.tmp"
          File.write(temporary, JSON.pretty_generate(@status), mode: 'w:UTF-8')
          File.rename(temporary, STATUS_PATH)
        end

        def advance
          return finish('cancelled') if @cancel_requested

          task = @tasks.find do |candidate|
            key = task_key(candidate)
            needs_export = !@status['completed'].include?(key) || !valid_output?(candidate)
            needs_export && !@attempted[key]
          end
          unless task
            state = @status['failed'].empty? ? 'complete' : 'complete_with_failures'
            return finish(state)
          end

          @current_task = task
          @status['current'] = task_key(task)
          @attempted[@status['current']] = true
          persist_status
          update_dialog("Opening #{task[:model_name]} for [#{task[:id]}] #{task[:label]}")

          if normalized_path(Sketchup.active_model.path) == normalized_path(task[:model_path])
            schedule(0.1) { execute_current }
          else
            opened = Sketchup.open_file(task[:model_path])
            raise "SketchUp gagal membuka #{task[:model_path]}" unless opened
            schedule(1.0) { verify_model_and_execute }
          end
        rescue StandardError => error
          fail_current(error)
        end

        def verify_model_and_execute
          unless normalized_path(Sketchup.active_model.path) == normalized_path(@current_task[:model_path])
            raise "Model aktif tidak sesuai: #{Sketchup.active_model.path}"
          end
          execute_current
        rescue StandardError => error
          fail_current(error)
        end

        def execute_current
          task = @current_task
          FileUtils.mkdir_p(task[:output_dir])
          File.delete(task[:output_path]) if File.file?(task[:output_path]) && !valid_output?(task)
          update_dialog("Exporting #{task[:model_name]} with [#{task[:id]}] #{task[:label]}")

          start_cooperative(task)
        rescue StandardError => error
          fail_current(error)
        end

        def export_sync(task, progress = nil)
          model = Sketchup.active_model
          case task[:id]
          when '01'
            load_core('2026_05_11_01').run_export(old_settings(task[:output_path], pretty: true, progress: progress))
          when '02'
            load_core('2026_05_11_02').run_export(old_settings(task[:output_path], pretty: true, progress: progress).merge(export_level: 'visual'))
          when '03'
            base = task[:output_path].sub(/_visual\.json\z/i, '.json')
            load_core('2026_05_11_03').run_export(old_settings(base, pretty: false, progress: progress).merge(export_level: 'visual'))
          when '04'
            base = task[:output_path].sub(/__SBE-2026\.07\.16-01_canonical\.json\.gz\z/, '.json')
            load_core('2026_07_16_01').run_export(new_settings(base, 'canonical_v3', true, progress: progress))
          when '05'
            load_core('2026_07_16_02').export_model_eval_json(model, task[:output_path], progress: progress, batch_size: 32)
          when '06'
            base = task[:output_path].sub(/__SBE-2026\.07\.16-03_runtime\.bome2\z/, '.json')
            load_core('2026_07_16_03').run_export(new_settings(base, 'bome2', false, progress: progress))
          when '07'
            require_engine_file('2026_08_12_01', 'bom_engine/clean_analysis/sketchup_extension.rb')
            SibamboHistory::V20260812_01::CleanAnalysis::Exporter.export_package(
              model: model, roots: model.entities, parent_transform: Geom::Transformation.new,
              output_path: task[:output_path], settings: { include_hidden: false },
              progress: progress, batch_size: 24
            )
          when '08'
            require_engine_file('2026_08_13_01', 'bom_engine/bomc_extension.rb')
            SibamboHistory::V20260813_01::BOMCExtension.export(model, output_path: task[:output_path], progress: progress)
          when '09'
            require_engine_file('2026_08_19_01', 'bom_engine/bomc_extension.rb')
            settings = SibamboHistory::V20260819_01::BOMCProcessing.settings(:light)
            SibamboHistory::V20260819_01::BOMCExtension.export(
              model, output_path: task[:output_path], progress: progress, settings: settings
            )
          end
        end

        def start_cooperative(task)
          @worker_fiber = Fiber.new do
            begin
              result = with_suppressed_messageboxes do
                export_sync(task, method(:cooperative_checkpoint))
              end
              [:finished, :success, result]
            rescue StandardError => error
              [:finished, :error, error]
            end
          end
          schedule(0.04) { poll_cooperative }
        end

        def poll_cooperative
          outcome = @worker_fiber.resume
          if outcome.is_a?(Array) && outcome[0] == :progress
            event = outcome[1] || {}
            stage = event[:stage] || event['stage'] || 'Exporting'
            processed = event[:processed] || event['processed'] || 0
            update_dialog("#{stage} — #{processed} items")
            schedule(0.04) { poll_cooperative }
            return
          end

          marker, status, value = outcome
          raise 'Exporter cooperative selesai dengan state tidak valid.' unless marker == :finished
          raise value if status == :error

          @worker_fiber = nil
          complete_current
        rescue StandardError => error
          @worker_fiber = nil
          fail_current(error)
        end

        def cooperative_checkpoint(event = {})
          raise 'Batch dibatalkan.' if @cancel_requested

          Fiber.yield([:progress, event || {}])
        end

        def complete_current
          raise "Output tidak valid atau tidak lengkap: #{@current_task[:output_path]}" unless valid_output?(@current_task)

          key = task_key(@current_task)
          @status['completed'] << key unless @status['completed'].include?(key)
          @status['failed'].reject! { |item| item['task'] == key }
          persist_status
          update_dialog("Completed #{key}")
          @current_task = nil
          GC.start
          schedule(0.4) { advance }
        end

        def fail_current(error)
          key = @current_task ? task_key(@current_task) : 'unknown'
          @status ||= { 'completed' => [], 'failed' => [] }
          @status['failed'] ||= []
          @status['failed'].reject! { |item| item['task'] == key }
          @status['failed'] << { 'task' => key, 'error' => error.message, 'at' => Time.now.iso8601 }
          persist_status
          update_dialog("FAILED #{key}: #{error.message}")
          @current_task = nil
          GC.start
          schedule(1.0) { advance }
        end

        def finish(state)
          @running = false
          @status['status'] = state
          @status.delete('current')
          @status['finished_at'] = Time.now.iso8601
          persist_status
          completed = @status['completed'].length
          failed = @status['failed'].length
          update_dialog("Batch #{state}: #{completed}/#{@tasks.length} complete, #{failed} failed")
        end

        def load_core(engine)
          require_engine_file(engine, 'bom_engine/core.rb')
          constant = engine.delete('_')
          SibamboHistory.const_get("V#{constant}").const_get(:Core)
        end

        def require_engine_file(engine, relative)
          path = File.join(__dir__, "engine_sbe_#{engine}", relative)
          require path
        end

        def old_settings(path, pretty:, progress: nil)
          {
            output_path: path, export_textures: false, include_edges: false,
            include_materials: true, pretty_print: pretty, selection_only: false, silent: true,
            progress: progress, batch_size: 32
          }
        end

        def new_settings(path, format, compress, progress: nil)
          old_settings(path, pretty: false, progress: progress).merge(
            output_format: format, compress_output: compress, compact_geometry: true,
            binary_geometry: format == 'bome2', export_level: 'visual'
          )
        end

        def valid_output?(task)
          path = task[:output_path]
          return false unless File.file?(path) && File.size(path) > 16

          File.open(path, 'rb') do |file|
            head = file.read(8).to_s
            case task[:id]
            when '01', '02', '03', '05'
              file.seek([File.size(path) - 128, 0].max)
              head.lstrip.start_with?('{') && file.read.to_s.rstrip.end_with?('}')
            when '04' then head.start_with?("\x1F\x8B".b)
            when '06' then head.start_with?("BOME2\n".b)
            when '07'
              file.seek([File.size(path) - 65_557, 0].max)
              head.start_with?("PK\x03\x04".b) && file.read.to_s.include?("PK\x05\x06".b)
            when '08', '09' then head.start_with?("BOMC\x01\x00\x00\x00".b)
            else false
            end
          end
        rescue StandardError
          false
        end

        def normalized_path(path)
          File.expand_path(path.to_s).tr('\\', '/').downcase
        end

        def with_suppressed_messageboxes
          singleton = class << UI; self; end
          original = UI.method(:messagebox)
          singleton.send(:define_method, :messagebox) { |_message, *_args| 1 }
          yield
        ensure
          singleton.send(:define_method, :messagebox) { |*args| original.call(*args) } if singleton && original
        end

        def close_job_dialog(job)
          dialog = job && job.instance_variable_get(:@dialog)
          dialog.close if dialog
        rescue StandardError
          nil
        end

        def schedule(delay, &block)
          UI.start_timer(delay, false, &block)
        end

        def build_dialog
          @dialog&.close
          @dialog = UI::HtmlDialog.new(
            dialog_title: 'Evolution Lab Batch Export', scrollable: false, resizable: true,
            width: 560, height: 260, min_width: 460, min_height: 220,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          @dialog.set_html(<<~HTML)
            <!doctype html><meta charset="utf-8"><style>
            body{font:14px system-ui;background:#17202a;color:#eef;padding:20px}h2{margin-top:0}
            #status{white-space:pre-wrap;line-height:1.5}button{margin-top:18px;padding:8px 16px}
            </style><h2>Evolution Lab Batch Export</h2><div id="status">Preparing...</div>
            <button onclick="sketchup.cancelBatch()">Cancel after current exporter</button>
          HTML
          @dialog.add_action_callback('cancelBatch') { |_ctx| cancel }
          @dialog.set_on_closed { cancel if running? }
          @dialog.show
        end

        def update_dialog(message)
          index = @status && @status['completed'] ? @status['completed'].length : 0
          total = @tasks ? @tasks.length : 0
          payload = JSON.generate("#{index}/#{total}\n#{message}")
          @dialog.execute_script("document.getElementById('status').textContent=#{payload}") if @dialog
          Sketchup.set_status_text(message)
        rescue StandardError
          nil
        end
      end
    end
  end
end
