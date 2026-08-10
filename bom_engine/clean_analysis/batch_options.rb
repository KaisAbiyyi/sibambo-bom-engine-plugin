# frozen_string_literal: true

require 'etc'
require 'json'

module BOMEngine
  module CleanAnalysis
    module BatchOptions
      BATCH_SIZES = [
        8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512,
        1_024, 2_048, 4_096, 8_192
      ].freeze
      CALIBRATION_SECONDS = 0.025

      module_function

      def device_profile
        cores = Etc.nprocessors
        cores = ENV.fetch('NUMBER_OF_PROCESSORS', '4').to_i if cores.to_i < 1
        cores = 1 if cores.to_i < 1
        iterations = calibration_iterations
        {
          cores: cores,
          recommended_batch: recommended_batch(
            cores: cores,
            calibration_iterations: iterations
          ),
          calibration_iterations: iterations
        }
      rescue StandardError
        { cores: 4, recommended_batch: 16, calibration_iterations: 1 }
      end

      def recommended_batch(cores:, calibration_iterations:)
        core_count = cores.to_i
        base = if core_count <= 2
                 8
               elsif core_count <= 4
                 16
               elsif core_count <= 8
                 24
               elsif core_count <= 12
                 48
               elsif core_count <= 20
                 64
               else
                 96
               end
        index = BATCH_SIZES.index(base)
        index = [index - 1, 0].max if calibration_iterations.to_i < 12
        index = [index + 1, BATCH_SIZES.length - 1].min if calibration_iterations.to_i > 1_200
        BATCH_SIZES.fetch(index)
      end

      def normalize_batch(value, fallback: 24)
        requested = value.to_i
        return requested if BATCH_SIZES.include?(requested)

        BATCH_SIZES.min_by { |candidate| (candidate - fallback.to_i).abs }
      end

      def show(profile: device_profile, &callback)
        dialog = UI::HtmlDialog.new(
          dialog_title: 'BOM Engine Clean - Batch Options',
          scrollable: false,
          resizable: false,
          width: 470,
          height: 530,
          min_width: 420,
          min_height: 500,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        dialog.set_file(File.join(File.dirname(__FILE__), 'ui', 'batch_options.html'))
        dialog.add_action_callback('ready') do |_context|
          dialog.execute_script("initializeBatchOptions(#{JSON.generate(profile)})")
        end
        dialog.add_action_callback('start') do |_context, raw|
          settings = JSON.parse(raw.to_s)
          manual = settings['mode'] == 'manual'
          batch = if manual
                    normalize_batch(
                      settings['batch_size'],
                      fallback: profile.fetch(:recommended_batch)
                    )
                  else
                    profile.fetch(:recommended_batch)
                  end
          dialog.close
          callback.call(
            batch,
            manual ? 'manual' : 'auto',
            settings['pretty_print'] == true
          )
        rescue JSON::ParserError
          nil
        end
        dialog.add_action_callback('cancel') { |_context| dialog.close }
        dialog.show
        dialog
      end

      def calibration_iterations
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        iterations = 0
        value = 17
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < CALIBRATION_SECONDS
          300.times { |index| value = ((value * 33) + index) & 0x7fff_ffff }
          iterations += 1
        end
        iterations
      rescue StandardError
        1
      end
    end
  end
end
