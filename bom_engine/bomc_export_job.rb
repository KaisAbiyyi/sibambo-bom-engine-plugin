# Staged cooperative BOMC export orchestration. SketchUp-specific snapshotting is
# injected by the extension so this state machine stays pure-Ruby testable.

require_relative 'bomc_processing'
require_relative 'performance_trace'

module BOMEngine
  module BOMCExportJob
    STAGES = [
      :INITIALIZE, :SCAN_MODEL, :SNAPSHOT_MATERIALS, :SNAPSHOT_TEXTURES,
      :SNAPSHOT_ENTITIES, :CLASSIFY, :BUILD_COVERAGE, :BUILD_DEFINITIONS,
      :BUILD_INSTANCES, :COMPILE_METADATA, :ENCODE_POSITIONS, :ENCODE_TOPOLOGY,
      :ENCODE_NORMALS, :ENCODE_UV, :ENCODE_TRANSFORMS, :ENCODE_TEXTURES,
      :COMPRESS_SECTIONS, :WRITE_CONTAINER, :SIZE_GATE, :VALIDATE, :PUBLISH, :DONE
    ].freeze

    SNAPSHOT_STAGES = STAGES[1, 8].freeze
    COMPILE_STAGES = STAGES[9, 9].freeze

    module_function

    def run(model:, output_path:, settings:, context:)
      graph = nil
      source = nil
      result = nil
      trace = context[:performance_trace]
      trace_status = :success
      trace_error = nil
      controller = BOMCProcessing::Controller.new(
        settings: settings,
        clock: context.fetch(:clock),
        on_yield: context.fetch(:on_yield),
        cancelled: context.fetch(:cancelled)
      )
      current_stage_index = -1
      advance = lambda do |target, candidate_bytes = nil, savings_bytes = nil|
        target_stage = normalize_stage(target)
        target_index = STAGES.index(target_stage)
        return if target_index.nil? || target_index <= current_stage_index
        ((current_stage_index + 1)..target_index).each do |index|
          transition(
            controller,
            STAGES[index],
            candidate_bytes: candidate_bytes,
            source_bytes: source && source[:bytes],
            savings_bytes: savings_bytes
          )
        end
        current_stage_index = target_index
      end
      checkpoint = lambda do |**event|
        payload = event.dup
        payload[:stage] = normalize_stage(payload[:stage])
        payload[:source_bytes] = source[:bytes] if source && !payload.key?(:source_bytes)
        advance.call(payload[:stage], payload[:candidate_bytes])
        if STAGES.index(payload[:stage]).to_i < current_stage_index
          payload[:stage] = STAGES[current_stage_index]
        end
        controller.checkpoint(**payload)
      end

      work = lambda do
        advance.call(:INITIALIZE)
        source = PerformanceTrace.stage(:source_info) { context.fetch(:source_info).call(model) }
        advance.call(:SCAN_MODEL)
        graph = PerformanceTrace.stage(:snapshot) do
          snapshot = context.fetch(:snapshot)
          snapshot.arity == 2 ? snapshot.call(model, checkpoint) : snapshot.call(model, checkpoint, source)
        end
        advance.call(:BUILD_INSTANCES)
        result = PerformanceTrace.stage(:compile) { context.fetch(:compile).call(graph, source, output_path, checkpoint) }
        advance.call(:SIZE_GATE, result[:candidate_bytes])
        advance.call(:VALIDATE, result[:candidate_bytes])
        validation = PerformanceTrace.stage(:validate) do
          begin
            context.fetch(:validate).call(result, graph)
          rescue ArgumentError => e
            if e.message.include?('wrong number of arguments')
              context.fetch(:validate).call(result)
            else
              raise
            end
          end
        end
        if context[:publish]
          advance.call(:PUBLISH, result[:candidate_bytes], result[:savings_bytes])
          published = PerformanceTrace.stage(:publish) { context[:publish].call(result, validation, output_path) }
          result = result.merge(published: published)
        end
        result.delete(:normalized_source)
        advance.call(:DONE, result[:candidate_bytes], result[:savings_bytes])

        container_bytes = result[:bytes] if result[:bytes].is_a?(String)
        result = result.merge(
          path: result[:path] || output_path,
          bytes: result[:candidate_bytes] || (container_bytes && container_bytes.bytesize),
          validation: validation,
          source_info: source,
          mode: settings[:mode]
        )
        result.delete(:container_bytes)
        result
      end

      if trace && trace.enabled
        PerformanceTrace.with(trace) { work.call }
      else
        work.call
      end
    rescue StandardError => error
      trace_status = PerformanceTrace.cancellation_error?(error) ? :cancelled : :error
      trace_error = error
      raise
    ensure
      if trace
        begin
          artifact_bytes = if result.is_a?(Hash)
                             result[:candidate_bytes] || (result[:bytes].is_a?(String) ? result[:bytes].bytesize : result[:bytes])
                           end
          trace_metadata = {
            source: source && {
              path: source[:path], bytes: source[:bytes], sha256: source[:sha256], available: source[:available]
            },
            artifact: result.is_a?(Hash) ? {
              path: result[:path] || output_path,
              bytes: artifact_bytes,
              sha256: result[:sha256],
              status: result[:status],
              strategy: result[:strategy]
            } : nil,
            processing_mode: settings[:mode]
          }.reject { |_key, value| value.nil? }
          receipt = trace.finish(status: trace_status, error: trace_error, metadata: trace_metadata)
          result[:performance_trace] = receipt if result.is_a?(Hash)
          if context && context[:performance_receipt]
            context[:performance_receipt].call(receipt)
          end
        rescue StandardError => performance_error
          if result.is_a?(Hash)
            result[:performance_receipt_error] = "#{performance_error.class}: #{performance_error.message}"
          end
        end
      end
      graph = nil
      context[:graph_cleared].call if context && context[:graph_cleared]
      context[:cleanup].call if context && context[:cleanup]
    end

    def transition(controller, stage, candidate_bytes: nil, source_bytes: nil, savings_bytes: nil)
      controller.checkpoint(
        stage: stage,
        processed: STAGES.index(stage).to_i,
        total: STAGES.length - 1,
        candidate_bytes: candidate_bytes,
        source_bytes: source_bytes,
        savings_bytes: savings_bytes,
        phase: phase_for_stage(stage),
        force: true
      )
    end
    private_class_method :transition

    def normalize_stage(stage)
      value = stage || :INITIALIZE
      value.to_s.upcase.to_sym
    end
    private_class_method :normalize_stage

    def phase_for_stage(stage)
      index = STAGES.index(stage).to_i
      return :capturing if index <= STAGES.index(:BUILD_INSTANCES)
      return :compiling if index <= STAGES.index(:SIZE_GATE)
      return :validating if stage == :VALIDATE

      :publishing
    end
    private_class_method :phase_for_stage
  end
end
