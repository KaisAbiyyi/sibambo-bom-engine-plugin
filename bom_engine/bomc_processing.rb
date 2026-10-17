# Central BOMC responsiveness presets and adaptive cooperative scheduling.

module BOMEngine
  module BOMCProcessing
    class Cancelled < StandardError; end

    PRESETS = {
      light: { mode: :light, max_items: 64, max_ms: 10.0, min_items: 1, max_items_limit: 512 },
      balanced: { mode: :balanced, max_items: 256, max_ms: 24.0, min_items: 4, max_items_limit: 8_192 },
      interactive: { mode: :interactive, max_items: 1_024, max_ms: 12.0, min_items: 16, max_items_limit: 8_192 },
      fast: { mode: :fast, max_items: 1_024, max_ms: 60.0, min_items: 16, max_items_limit: 8_192 }
    }.freeze

    CUSTOM_LIMITS = {
      max_ms_min: 1.0,
      max_ms_max: 100.0,
      max_items_max: 32_768
    }.freeze

    module_function

    UI_BATCH_SIZES = [96, 128, 256, 512, 1024, 2048, 4096, 8192].freeze

    def from_ui(batch_mode:, batch_size: nil)
      return settings(:interactive) if batch_mode.to_s == 'auto'
      raise ArgumentError, 'Unknown batch mode' unless batch_mode.to_s == 'manual'

      size = Integer(batch_size)
      raise ArgumentError, 'Unsupported geometry batch size' unless UI_BATCH_SIZES.include?(size)

      settings(:custom, custom: {
        max_items: [size, 1_024].min,
        max_items_limit: size,
        min_items: [16, size].min,
        max_ms: 12.0
      })
    end

    def settings(name = :balanced, custom: nil)
      mode = (name || :balanced).to_sym
      preset = PRESETS[mode]
      return preset.dup if preset
      raise ArgumentError, "Unknown BOMC processing mode #{mode}." unless mode == :custom

      values = custom || {}
      minimum = clamp_integer(values[:min_items] || 1, 1, CUSTOM_LIMITS[:max_items_max])
      limit = clamp_integer(values[:max_items_limit] || 4_096, minimum, CUSTOM_LIMITS[:max_items_max])
      maximum = clamp_integer(values[:max_items] || 256, minimum, limit)
      milliseconds = clamp_float(values[:max_ms] || 24.0, CUSTOM_LIMITS[:max_ms_min], CUSTOM_LIMITS[:max_ms_max])
      { mode: :custom, max_items: maximum, max_ms: milliseconds, min_items: minimum, max_items_limit: limit }
    end

    def clamp_integer(value, minimum, maximum)
      [[Integer(value), minimum].max, maximum].min
    rescue ArgumentError, TypeError
      minimum
    end
    private_class_method :clamp_integer

    def clamp_float(value, minimum, maximum)
      [[Float(value), minimum].max, maximum].min
    rescue ArgumentError, TypeError
      minimum
    end
    private_class_method :clamp_float

    class Controller
      attr_reader :target_items, :settings

      def initialize(settings:, clock:, on_yield:, cancelled:)
        @settings = settings.dup
        @clock = clock
        @on_yield = on_yield
        @cancelled = cancelled
        @initial_target_items = Integer(@settings.fetch(:max_items))
        @target_items = @initial_target_items
        @stage = nil
        @stage_targets = {}
        @stage_ms_per_item = {}
        @slice_started = nil
        @slice_processed = 0
      end

      def checkpoint(stage:, processed:, total:, candidate_bytes: nil, source_bytes: nil, savings_bytes: nil, phase: nil, force: false)
        raise Cancelled, 'BOMC export cancelled.' if @cancelled && @cancelled.call

        now = Float(@clock.call)
        current_stage = stage.to_sym
        current_processed = Integer(processed || 0)
        if @slice_started.nil?
          enter_stage(current_stage, current_processed, now)
        elsif @stage != current_stage || current_processed < @slice_processed
          enter_stage(current_stage, current_processed, now)
        end

        elapsed_ms = (now - @slice_started) * 1000.0
        items = current_processed - @slice_processed
        reason = if force
                   :forced
                 elsif elapsed_ms >= @settings.fetch(:max_ms).to_f
                   :time
                 elsif items >= @target_items
                   :items
                 end
        return false unless reason

        adapt_target(elapsed_ms, items) unless force
        total_value = Integer(total || 0)
        percent = total_value > 0 ? [current_processed.to_f * 100.0 / total_value, 100.0].min : 0.0
        @on_yield.call(
          stage: current_stage,
          processed: current_processed,
          total: total_value,
          percent: percent,
          mode: @settings[:mode],
          elapsed_ms: elapsed_ms,
          candidate_bytes: candidate_bytes,
          source_bytes: source_bytes,
          savings_bytes: savings_bytes,
          phase: phase,
          target_items: @target_items,
          reason: reason
        ) if @on_yield
        @slice_started = Float(@clock.call)
        @slice_processed = current_processed
        true
      end

      private

      def enter_stage(stage, processed, now)
        @stage_targets[@stage] = @target_items if @stage
        @stage = stage
        @target_items = @stage_targets.fetch(stage, @initial_target_items)
        @slice_started = now
        @slice_processed = processed
      end

      def adapt_target(elapsed_ms, items)
        budget = @settings.fetch(:max_ms).to_f
        minimum = Integer(@settings.fetch(:min_items))
        maximum = Integer(@settings.fetch(:max_items_limit))
        candidate = @target_items

        if items > 0 && elapsed_ms > 0.0
          sample = elapsed_ms / items.to_f
          previous = @stage_ms_per_item[@stage]
          estimate = previous ? (previous * 0.7 + sample * 0.3) : sample
          @stage_ms_per_item[@stage] = estimate
          desired = [(budget * 0.80 / estimate).floor, minimum].max
          if elapsed_ms > budget
            candidate = [(@target_items * budget / elapsed_ms).floor, desired].min
          elsif elapsed_ms < budget * 0.60
            candidate = [(@target_items * 1.5).ceil, desired].min
          else
            candidate = desired
          end
        elsif elapsed_ms > budget
          candidate = (@target_items * budget / elapsed_ms).floor
        end

        @target_items = [[candidate, minimum].max, maximum].min
        @stage_targets[@stage] = @target_items
      end
    end
  end
end
