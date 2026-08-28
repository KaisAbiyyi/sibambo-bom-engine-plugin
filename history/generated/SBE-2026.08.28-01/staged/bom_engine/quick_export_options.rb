# Device-aware options for the Model-Eval quick export.

require 'etc'
require 'json'

module SibamboHistory
  module V20260828_01
  module QuickExportOptions
    BATCH_SIZES = [8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 1_024, 2_048, 4_096, 8_192].freeze
    CALIBRATION_SECONDS = 0.025

    def self.device_profile
      cores = Etc.nprocessors
      cores = ENV.fetch('NUMBER_OF_PROCESSORS', '4').to_i if cores.to_i < 1
      cores = 1 if cores.to_i < 1
      iterations = calibration_iterations
      { cores: cores, recommended_batch: recommended_batch(cores: cores, calibration_iterations: iterations), calibration_iterations: iterations }
    rescue StandardError
      { cores: 4, recommended_batch: 16, calibration_iterations: 1 }
    end

    # A bounded work slice avoids long UI stalls while reducing timer overhead.
    def self.recommended_batch(cores:, calibration_iterations:)
      c = cores.to_i
      base = if c <= 2
               8
             elsif c <= 4
               16
             elsif c <= 8
               24
             elsif c <= 12
               48
             elsif c <= 20
               64
             else
               96
             end
      return BATCH_SIZES[[BATCH_SIZES.index(base) - 1, 0].max] if calibration_iterations.to_i < 12
      return BATCH_SIZES[[BATCH_SIZES.index(base) + 1, BATCH_SIZES.length - 1].min] if calibration_iterations.to_i > 1_200
      base
    end

    def self.normalize_batch(value, fallback: 24)
      requested = value.to_i
      return requested if BATCH_SIZES.include?(requested)
      BATCH_SIZES.min_by { |candidate| (candidate - fallback.to_i).abs }
    end

    def self.show(profile: device_profile, &callback)
      dialog = UI::HtmlDialog.new(dialog_title: 'BOM Engine - Quick Export Options', scrollable: true, resizable: false, width: 470, height: 480, min_width: 420, min_height: 450, style: UI::HtmlDialog::STYLE_DIALOG)
      dialog.set_file(File.join(File.dirname(__FILE__), 'ui', 'quick_export_options.html'))
      dialog.add_action_callback('ready') { |_ctx| dialog.execute_script("initializeQuickExportOptions(#{JSON.generate(profile)})") }
      dialog.add_action_callback('start') do |_ctx, raw|
        settings = JSON.parse(raw.to_s) rescue {}
        manual = settings['mode'] == 'manual'
        batch = manual ? normalize_batch(settings['batch_size'], fallback: profile[:recommended_batch]) : profile[:recommended_batch]
        dialog.close
        callback.call(batch, manual ? 'manual' : 'auto')
      end
      dialog.add_action_callback('cancel') { |_ctx| dialog.close }
      dialog.show
      dialog
    end

    def self.calibration_iterations
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

end # SibamboHistory
