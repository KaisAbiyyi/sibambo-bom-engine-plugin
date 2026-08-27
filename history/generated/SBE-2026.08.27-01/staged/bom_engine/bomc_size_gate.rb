# Strict saved-SKP size gate with bounded, deterministic lossless escalation.

require 'fileutils'
require_relative 'bomc_writer'

module SibamboHistory
  module V20260827_01
  module BOMCSizeGate
    STRATEGIES = [
      { name: :standard, compression_level: 6, minimal_metadata: false },
      { name: :compact, compression_level: 9, minimal_metadata: false },
      { name: :maximum_lossless, compression_level: 9, minimal_metadata: true }
    ].freeze

    class TargetNotMet < StandardError
      attr_reader :source_bytes, :best_candidate_bytes, :delta_bytes, :attempts, :dominant_sections

      def initialize(source_bytes:, best_candidate_bytes:, attempts:, dominant_sections:)
        @source_bytes = source_bytes
        @best_candidate_bytes = best_candidate_bytes
        @delta_bytes = best_candidate_bytes - source_bytes
        @attempts = attempts
        @dominant_sections = dominant_sections
        labels = dominant_sections.map { |section| "#{section[:name]}=#{section[:stored_bytes]}" }.join(', ')
        super("BOMC target not met: source=#{source_bytes}, best=#{best_candidate_bytes}, delta=+#{@delta_bytes}; dominant sections: #{labels}")
      end
    end

    module_function

    def source_info(path)
      source_path = path.to_s
      unless !source_path.empty? && File.file?(source_path)
        return { path: source_path.empty? ? nil : source_path, bytes: nil, available: false, reason: :unsaved_or_missing }
      end
      { path: File.expand_path(source_path), bytes: File.size(source_path), available: true }
    end

    def evaluate(candidate_bytes:, source_info:)
      return :unavailable unless source_info && source_info[:available]
      Integer(candidate_bytes) < Integer(source_info.fetch(:bytes)) ? :pass : :fail
    end

    def compile(graph:, source_info:, base_path:, checkpoint: nil, output_path: nil)
      info = source_info || { available: false, bytes: nil }
      strategies = info[:available] ? STRATEGIES : [STRATEGIES.first]
      attempts = []
      best = nil

      strategies.each_with_index do |strategy, index|
        result = BOMCWriter.pack(
          graph,
          profile: :production,
          base_path: base_path,
          sparse: true,
          compact_directory: true,
          compression_level: strategy[:compression_level],
          minimal_metadata: strategy[:minimal_metadata],
          checkpoint: checkpoint
        )
        coverage = result.dig(:metrics, :coverage) || {}
        unless coverage[:unaccounted].to_i.zero?
          raise 'BOMC export refused: detached graph contains unaccounted geometry.'
        end
        candidate_size = result[:bytes].bytesize
        status = evaluate(candidate_bytes: candidate_size, source_info: info)
        attempt = {
          strategy: strategy[:name],
          candidate_bytes: candidate_size,
          status: status,
          compression_level: strategy[:compression_level],
          minimal_metadata: strategy[:minimal_metadata]
        }
        attempts << attempt
        invoke_checkpoint(
          checkpoint,
          stage: :size_gate,
          processed: index + 1,
          total: strategies.length,
          candidate_bytes: candidate_size,
          force: true
        )
        best = best_result(best, result, strategy)

        if status == :pass || status == :unavailable
          if output_path
            invoke_checkpoint(
              checkpoint,
              stage: :write_container,
              processed: 0,
              total: result[:bytes].bytesize,
              candidate_bytes: candidate_size,
              force: true
            )
            publish(output_path, result[:bytes])
            invoke_checkpoint(
              checkpoint,
              stage: :write_container,
              processed: result[:bytes].bytesize,
              total: result[:bytes].bytesize,
              candidate_bytes: candidate_size,
              force: true
            )
          end
          return result.merge(
            status: status,
            strategy: strategy[:name],
            candidate_bytes: candidate_size,
            source_bytes: info[:bytes],
            savings_bytes: info[:available] ? info[:bytes] - candidate_size : nil,
            attempts: attempts
          )
        end
        result = nil
      end

      raise TargetNotMet.new(
        source_bytes: Integer(info.fetch(:bytes)),
        best_candidate_bytes: best[:candidate_bytes],
        attempts: attempts,
        dominant_sections: dominant_sections(best[:metrics])
      )
    ensure
      best = nil
    end

    def best_result(current, result, strategy)
      candidate = {
        candidate_bytes: result[:bytes].bytesize,
        metrics: result[:metrics],
        strategy: strategy[:name]
      }
      return candidate if current.nil? || candidate[:candidate_bytes] < current[:candidate_bytes]
      current
    end
    private_class_method :best_result

    def dominant_sections(metrics)
      sections = metrics.fetch(:sections, {})
      sections.map do |name, values|
        { name: name, stored_bytes: values[:stored_bytes], raw_bytes: values[:raw_bytes] }
      end.sort_by { |section| [-section[:stored_bytes].to_i, section[:name].to_s] }.first(5)
    end
    private_class_method :dominant_sections

    def invoke_checkpoint(checkpoint, payload)
      checkpoint.call(**payload) if checkpoint
    end
    private_class_method :invoke_checkpoint

    def publish(path, bytes)
      temporary_path = "#{path}.#{Process.pid}.part"
      begin
        File.open(temporary_path, 'wb') do |file|
          file.write(bytes)
          file.flush
          file.fsync rescue nil
        end
        FileUtils.mv(temporary_path, path, force: true)
      ensure
        File.delete(temporary_path) if File.file?(temporary_path)
      end
    end
    private_class_method :publish
  end
end

end # SibamboHistory
