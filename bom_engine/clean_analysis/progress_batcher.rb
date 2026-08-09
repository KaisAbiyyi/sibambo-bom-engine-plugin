# frozen_string_literal: true

module BOMEngine
  module CleanAnalysis
    # Converts fine-grained compiler checkpoints into bounded UI-thread yields.
    class ProgressBatcher
      attr_reader :processed

      def initialize(progress, batch_size)
        @progress = progress
        @batch_size = [batch_size.to_i, 1].max
        @processed = 0
      end

      def step(stage)
        @processed += 1
        emit(stage) if (@processed % @batch_size).zero?
      end

      def force(stage)
        emit(stage)
      end

      private

      def emit(stage)
        return if @progress.nil?

        @progress.call(stage: stage.to_s, processed: @processed)
      end
    end
  end
end
