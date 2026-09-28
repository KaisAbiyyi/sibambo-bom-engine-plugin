# frozen_string_literal: true
# Saved-SKP size diagnostics with bounded, deterministic profile budget solving.

require 'digest'
require 'fileutils'
require_relative 'bomc_writer'
require_relative 'bomc_profile'
require_relative 'bomc_budget_solver'
require_relative 'bomc_export_cache'

module BOMEngine
  module BOMCSizeGate
    STRATEGIES = [
      { name: :standard, compression_level: 6, minimal_metadata: false },
      { name: :compact, compression_level: 9, minimal_metadata: false },
      { name: :maximum_lossless, compression_level: 9, minimal_metadata: true }
    ].freeze

    class TargetNotMet < StandardError
      attr_reader :source_bytes, :best_candidate_bytes, :delta_bytes, :attempts, :dominant_sections, :hard_budget_bytes, :texture_diagnostics

      def initialize(source_bytes:, best_candidate_bytes:, attempts:, dominant_sections:, hard_budget_bytes: nil, texture_diagnostics: [])
        @source_bytes = source_bytes
        @best_candidate_bytes = best_candidate_bytes
        @hard_budget_bytes = hard_budget_bytes || source_bytes
        @delta_bytes = best_candidate_bytes - @hard_budget_bytes
        @attempts = attempts
        @dominant_sections = dominant_sections
        @texture_diagnostics = texture_diagnostics
        labels = dominant_sections.map { |section| "#{section[:name]}=#{section[:stored_bytes]}" }.join(', ')
        super("BOMC target not met: source=#{source_bytes}, hard_budget=#{@hard_budget_bytes}, best=#{best_candidate_bytes}, delta=+#{@delta_bytes}; dominant sections: #{labels}")
      end
    end

    module_function

    def source_info(path)
      source_path = path.to_s
      unless !source_path.empty? && File.file?(source_path)
        return { path: source_path.empty? ? nil : source_path, bytes: nil, available: false, reason: :unsaved_or_missing }
      end
      { path: File.expand_path(source_path), bytes: File.size(source_path),
        sha256: Digest::SHA256.file(source_path).hexdigest, available: true }
    end

    def evaluate(candidate_bytes:, source_info:, profile: :visual, profile_contract: nil)
      contract = if profile_contract
                   profile_contract.is_a?(BOMCProfile::Profile) ? profile_contract : BOMCProfile.fetch(profile_contract)
                 elsif [:exact, :research, :visual, :production, :debug].include?(profile.to_sym)
                   BOMCProfile.fetch(profile.to_sym)
                 else
                   BOMCProfile.fetch(:visual)
                 end

      return :pass unless contract.requires_source_size?
      return :unavailable unless source_info && source_info[:available] && source_info[:bytes].to_i > 0

      hard_target = if contract.name == :production || contract.hard_ratio.nil? || contract.hard_ratio >= 1.0
                      Integer(source_info.fetch(:bytes)) - 1
                    else
                      (Integer(source_info.fetch(:bytes)) * contract.hard_ratio).floor
                    end
      Integer(candidate_bytes) <= hard_target ? :pass : :fail
    end

    def compile_candidate(snapshot_or_graph = nil, profile: :visual, graph: nil, source_info: nil, base_path: nil, checkpoint: nil, target_bytes: nil, export_cache: nil)
      graph_obj = snapshot_or_graph || graph
      src_info = source_info
      b_path = base_path
      chk = checkpoint

      if graph_obj.is_a?(Hash)
        if graph_obj.key?(:graph)
          src_info ||= graph_obj[:source_info]
          b_path ||= graph_obj[:base_path] || graph_obj[:texture_directory]
          chk ||= graph_obj[:checkpoint]
          graph_obj = graph_obj[:graph]
        else
          src_info ||= graph_obj[:source_info]
          b_path ||= graph_obj[:base_path] || graph_obj[:texture_directory]
          chk ||= graph_obj[:checkpoint]
        end
      end

      compile(
        graph: graph_obj,
        source_info: src_info,
        base_path: b_path,
        profile: profile,
        checkpoint: chk,
        output_path: nil,
        enforce_smaller: false,
        target_bytes: target_bytes,
        export_cache: export_cache
      )
    end

    def compile(graph:, source_info:, base_path:, profile: :visual, profile_contract: nil, checkpoint: nil, output_path: nil, enforce_smaller: true, target_bytes: nil, export_cache: nil)
      contract = if profile_contract
                   profile_contract.is_a?(BOMCProfile::Profile) ? profile_contract : BOMCProfile.fetch(profile_contract)
                 elsif [:exact, :research, :visual, :production, :debug].include?(profile.to_sym)
                   BOMCProfile.fetch(profile.to_sym)
                 else
                   BOMCProfile.fetch(:visual)
                 end

      info = source_info || { available: false, bytes: nil }
      cache = export_cache || BOMCExportCache::Cache.new

      if contract.profile == :exact
        result = BOMCWriter.pack(
          graph,
          profile: :exact,
          profile_contract: contract,
          base_path: base_path,
          sparse: true,
          compact_directory: true,
          checkpoint: checkpoint,
          export_cache: cache
        )
        candidate_size = result[:bytes].bytesize
        publish_result(output_path, result, candidate_size, checkpoint, nil) if output_path
        return result.merge(
          status: :pass,
          strategy: :exact,
          candidate_bytes: candidate_size,
          source_bytes: info[:bytes],
          savings_bytes: info[:available] ? info[:bytes] - candidate_size : nil,
          attempts: [{ strategy: :exact, candidate_bytes: candidate_size, status: :pass }]
        )
      end

      if contract.requires_source_size? && (!info[:available] || info[:bytes].to_i <= 0)
        raise BOMCBudgetSolver::SourceSizeRequiredError.new(
          "Profile #{contract.name} requires positive source SKP byte size.",
          profile: contract.name,
          source_info: info
        )
      end

      strategies = info[:available] ? STRATEGIES : [STRATEGIES.first]
      attempts = []
      best = nil
      hard_target = if info[:available]
                      if contract.name == :production || contract.hard_ratio.nil? || contract.hard_ratio >= 1.0
                        Integer(info[:bytes]) - 1
                      else
                        (Integer(info[:bytes]) * contract.hard_ratio).floor
                      end
                    else
                      nil
                    end
      preferred_target = contract.preferred_ratio && info[:available] ? (Integer(info[:bytes]) * contract.preferred_ratio).floor : hard_target
      effective_target = target_bytes ? Integer(target_bytes) : (preferred_target || hard_target || 0)

      strategies.each_with_index do |strategy, index|
        result = BOMCWriter.pack(
          graph,
          profile: contract.name,
          profile_contract: contract,
          source_skp_bytes: info[:bytes].to_i,
          target_bytes: effective_target,
          base_path: base_path,
          sparse: true,
          compact_directory: true,
          compression_level: strategy[:compression_level],
          minimal_metadata: strategy[:minimal_metadata],
          checkpoint: checkpoint,
          export_cache: cache
        )
        coverage = result.dig(:metrics, :coverage) || {}
        unless coverage[:unaccounted].to_i.zero?
          raise 'BOMC export refused: detached graph contains unaccounted geometry.'
        end
        candidate_size = result[:bytes].bytesize
        status = evaluate(candidate_bytes: candidate_size, source_info: info, profile_contract: contract)
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

        if status == :pass || (status == :unavailable && !contract.requires_source_size?)
          publish_result(output_path, result, candidate_size, checkpoint, hard_target) if output_path
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

      # For backward compatibility with legacy non-profile calls only
      if !enforce_smaller && [:production, :debug].include?(contract.name)
        selected = best.fetch(:result)
        candidate_size = best.fetch(:candidate_bytes)
        publish_result(output_path, selected, candidate_size, checkpoint, nil) if output_path
        return selected.merge(
          status: :over_budget,
          strategy: best.fetch(:strategy),
          candidate_bytes: candidate_size,
          source_bytes: info[:bytes],
          savings_bytes: info[:bytes] - candidate_size,
          attempts: attempts,
          dominant_sections: dominant_sections(best[:metrics])
        )
      end

      raise TargetNotMet.new(
        source_bytes: Integer(info.fetch(:bytes)),
        hard_budget_bytes: hard_target,
        best_candidate_bytes: best[:candidate_bytes],
        attempts: attempts,
        dominant_sections: dominant_sections(best[:metrics]),
        texture_diagnostics: Array(graph[:materials]).map do |material|
          decision = material.dig(:texture, :encoding_evidence, :staging)
          next unless decision && decision[:policy_revision]
          { material: material[:name], decision: decision }
        end.compact
      )
    ensure
      best = nil
    end

    def best_result(current, result, strategy)
      candidate = {
        candidate_bytes: result[:bytes].bytesize,
        metrics: result[:metrics],
        strategy: strategy[:name],
        result: result
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

    def publish_result(output_path, result, candidate_size, checkpoint, hard_budget_bytes)
      invoke_checkpoint(
        checkpoint,
        stage: :write_container,
        processed: 0,
        total: result[:bytes].bytesize,
        candidate_bytes: candidate_size,
        force: true
      )
      publish(output_path, result[:bytes], hard_budget_bytes: hard_budget_bytes)
      invoke_checkpoint(
        checkpoint,
        stage: :write_container,
        processed: result[:bytes].bytesize,
        total: result[:bytes].bytesize,
        candidate_bytes: candidate_size,
        force: true
      )
    end
    private_class_method :publish_result

    def publish(path, bytes, hard_budget_bytes: nil)
      temporary_path = "#{path}.#{Process.pid}.part"
      begin
        File.open(temporary_path, 'wb') do |file|
          file.write(bytes)
          file.flush
          file.fsync rescue nil
        end
        actual_bytes = File.size(temporary_path)
        if hard_budget_bytes && actual_bytes > hard_budget_bytes
          raise BOMCBudgetSolver::BudgetNotFeasibleError.new(
            "Final published file size #{actual_bytes} exceeds hard budget #{hard_budget_bytes}.",
            actual_bytes: actual_bytes,
            hard_budget_bytes: hard_budget_bytes
          )
        end
        FileUtils.mv(temporary_path, path, force: true)
      ensure
        File.delete(temporary_path) if File.file?(temporary_path)
      end
    end
    private_class_method :publish
  end
end
