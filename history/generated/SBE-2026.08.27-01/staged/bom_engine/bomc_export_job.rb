# Staged cooperative BOMC export orchestration. SketchUp-specific snapshotting is
# injected by the extension so this state machine stays pure-Ruby testable.

require_relative 'bomc_processing'

module SibamboHistory
  module V20260827_01
  module BOMCExportJob
    STAGES = [
      :INITIALIZE, :SCAN_MODEL, :SNAPSHOT_MATERIALS, :SNAPSHOT_TEXTURES,
      :SNAPSHOT_ENTITIES, :CLASSIFY, :BUILD_COVERAGE, :BUILD_DEFINITIONS,
      :BUILD_INSTANCES, :COMPILE_METADATA, :ENCODE_POSITIONS, :ENCODE_TOPOLOGY,
      :ENCODE_NORMALS, :ENCODE_UV, :ENCODE_TRANSFORMS, :ENCODE_TEXTURES,
      :COMPRESS_SECTIONS, :WRITE_CONTAINER, :SIZE_GATE, :VALIDATE, :DONE
    ].freeze

    SNAPSHOT_STAGES = STAGES[1, 8].freeze
    COMPILE_STAGES = STAGES[9, 9].freeze

    module_function

    def run(model:, output_path:, settings:, context:)
      graph = nil
      source = nil
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

      advance.call(:INITIALIZE)
      source = context.fetch(:source_info).call(model)
      advance.call(:SCAN_MODEL)
      graph = context.fetch(:snapshot).call(model, checkpoint)
      advance.call(:BUILD_INSTANCES)
      result = context.fetch(:compile).call(graph, source, output_path, checkpoint)
      advance.call(:SIZE_GATE, result[:candidate_bytes])
      advance.call(:VALIDATE, result[:candidate_bytes])
      validation = context.fetch(:validate).call(result)
      advance.call(:DONE, result[:candidate_bytes], result[:status] == :pass ? result[:savings_bytes] : nil)

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
    ensure
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
        force: true
      )
    end
    private_class_method :transition

    def normalize_stage(stage)
      value = stage || :INITIALIZE
      value.to_s.upcase.to_sym
    end
    private_class_method :normalize_stage
  end
end

end # SibamboHistory
