# frozen_string_literal: true

module BOMEngine
  module CleanAnalysis
    # Converts fine-grained compiler checkpoints into bounded UI-thread yields.
    class ProgressBatcher
      DEFAULT_MAX_SLICE_SECONDS = 0.08

      attr_reader :processed

      def initialize(progress, batch_size, clock: nil,
                     max_slice_seconds: DEFAULT_MAX_SLICE_SECONDS)
        @progress = progress
        @batch_size = [batch_size.to_i, 1].max
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @max_slice_seconds = max_slice_seconds.to_f
        @processed = 0
        @last_emit_at = @clock.call
      end

      def step(stage)
        @processed += 1
        elapsed = @clock.call - @last_emit_at
        emit(stage) if (@processed % @batch_size).zero? || elapsed >= @max_slice_seconds
      end

      def force(stage)
        emit(stage)
      end

      private

      def emit(stage)
        return if @progress.nil?

        @last_emit_at = @clock.call
        @progress.call(stage: stage.to_s, processed: @processed)
      end
    end
  end
end
