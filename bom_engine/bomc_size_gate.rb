# frozen_string_literal: true
# Saved-SKP size diagnostics with bounded, deterministic profile budget solving.

require 'digest'
require 'fileutils'
require_relative 'bomc_writer'
require_relative 'bomc_profile'
require_relative 'bomc_budget_solver'
require_relative 'bomc_export_cache'
require_relative 'performance_trace'

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
      size = File.size(source_path)
      sha256 = PerformanceTrace.stage(:source_hash, counts: { bytes: size }) do
        Digest::SHA256.file(source_path).hexdigest
      end
      { path: File.expand_path(source_path), bytes: size, sha256: sha256, available: true }
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

    def compile_candidate(snapshot_or_graph = nil, profile: :visual, graph: nil, source_info: nil, base_path: nil, checkpoint: nil, target_bytes: nil, export_cache: nil, strict_exact_source: false)
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
        export_cache: export_cache,
        strict_exact_source: strict_exact_source
      )
    end

    def compile(graph:, source_info:, base_path:, profile: :visual, profile_contract: nil, checkpoint: nil, output_path: nil, enforce_smaller: true, target_bytes: nil, export_cache: nil, strict_exact_source: false)
      contract = if profile_contract
                   profile_contract.is_a?(BOMCProfile::Profile) ? profile_contract : BOMCProfile.fetch(profile_contract)
                 elsif [:exact, :research, :visual, :production, :debug].include?(profile.to_sym)
                   BOMCProfile.fetch(profile.to_sym)
                 else
                   BOMCProfile.fetch(:visual)
                 end

      info = source_info || { available: false, bytes: nil }
      cache = export_cache || BOMCExportCache::Cache.new
      source_digest = info[:sha256].to_s.downcase
      unless source_digest.match?(/\A[0-9a-f]{64}\z/)
        capture_digest = graph.respond_to?(:source_digest) ? graph.source_digest.to_s.downcase : ''
        source_digest = capture_digest.match?(/\A[0-9a-f]{64}\z/) ? capture_digest : BOMCExportCache::Cache.stable_source_digest(graph)
      end

      if contract.profile == :exact
        if strict_exact_source
          unless info[:available] == true && info[:path].is_a?(String) &&
              File.file?(info[:path]) && info[:bytes].is_a?(Integer) && info[:bytes] > 0 &&
              info[:sha256].to_s.match?(/\A[0-9a-f]{64}\z/i) &&
              File.size(info[:path]) == info[:bytes] &&
              Digest::SHA256.file(info[:path]).hexdigest == info[:sha256].downcase
            raise BOMCBudgetSolver::SourceSizeRequiredError.new(
              'Exact export requires unchanged saved SKP bytes and SHA-256.',
              profile: :exact, source_info: info
            )
          end
        end
        result = BOMCWriter.pack(
          graph,
          profile: :exact,
          profile_contract: contract,
          source_skp_bytes: strict_exact_source ? info[:bytes] : 0,
          target_bytes: strict_exact_source ? info[:bytes] - 1 : 0,
          base_path: base_path,
          sparse: true,
          compact_directory: true,
          checkpoint: checkpoint,
          export_cache: cache,
          source_digest: source_digest
        )
        candidate_size = result[:bytes].bytesize
        if strict_exact_source && candidate_size >= info[:bytes]
          raise TargetNotMet.new(
            source_bytes: info[:bytes], hard_budget_bytes: info[:bytes] - 1,
            best_candidate_bytes: candidate_size,
            attempts: [{ strategy: :exact, candidate_bytes: candidate_size, status: :fail }],
            dominant_sections: dominant_sections(result[:metrics]),
            texture_diagnostics: texture_diagnostics(graph)
          )
        end
        publish_result(output_path, result, candidate_size, checkpoint, strict_exact_source ? info[:bytes] - 1 : nil) if output_path
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
      normalized_model = nil
      prepared_candidates = nil
      prepared_solver_result = nil

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
          export_cache: cache,
          normalized_model: normalized_model,
          source_digest: source_digest,
          candidate_groups: strategy[:minimal_metadata] ? prepared_candidates : nil,
          solver_result: strategy[:minimal_metadata] ? prepared_solver_result : nil
        )
        normalized_model ||= result[:normalized_source]
        prepared_candidates ||= result[:prepared_candidates]
        prepared_solver_result ||= result[:solver_result]
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
        texture_diagnostics: texture_diagnostics(graph)
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

    # Source graph stores the actual per-material selection under
    # :staging_evidence. Previously failure reporting looked only for
    # :encoding_evidence/:staging, which is produced later by normalization,
    # so the native size-gate error silently dropped all codec decisions.
    # Preserve the original internal :material / :decision API for consumers
    # of TargetNotMet. Public receipts strip these private fields and retain
    # only the bounded, path-free summary below.
    def texture_diagnostics(graph, limit: 12)
      materials = graph.is_a?(Hash) ? Array(graph[:materials]) : []
      materials.filter_map do |material|
        next unless material.is_a?(Hash)
        texture = material[:texture]
        next unless texture.is_a?(Hash)

        evidence = texture[:staging_evidence] ||
          texture.dig(:encoding_evidence, :staging) || {}
        attempts = Array(evidence[:attempts] || evidence['attempts'])
        fallback = evidence[:semantic_fallback] || evidence['semantic_fallback'] || {}
        {
          material: material[:name], decision: evidence,
          bytes: Integer(texture[:byte_length] || texture[:bytes]&.bytesize || 0),
          width_px: texture[:image_width_px].to_i,
          height_px: texture[:image_height_px].to_i,
          selected: (evidence[:selected] || evidence['selected']).to_s,
          reason: (evidence[:reason] || evidence['reason']).to_s,
          semantic_fallback: (fallback[:reason] || fallback['reason']).to_s,
          attempt_reasons: attempts.filter_map { |attempt|
            next unless attempt.is_a?(Hash)
            (attempt[:reason] || attempt['reason'])&.to_s
          }.uniq.first(8)
        }
      end.sort_by { |row| [-row[:bytes], row[:selected]] }.first(limit)
    end

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
      publish(
        output_path,
        result[:bytes],
        hard_budget_bytes: hard_budget_bytes,
        expected_sha256: result[:sha256]
      )
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

    def publish(path, bytes, hard_budget_bytes: nil, expected_sha256: nil)
      temporary_path = "#{path}.#{Process.pid}.part"
      digest = Digest::SHA256.new
      begin
        File.open(temporary_path, 'wb') do |file|
          offset = 0
          while offset < bytes.bytesize
            chunk = bytes.byteslice(offset, [1024 * 1024, bytes.bytesize - offset].min)
            file.write(chunk)
            digest.update(chunk)
            offset += chunk.bytesize
          end
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
        emitted_sha256 = digest.hexdigest
        if expected_sha256 && emitted_sha256 != expected_sha256
          raise IOError, 'Published BOMC digest does not match the compiled candidate.'
        end
        FileUtils.mv(temporary_path, path, force: true)
      ensure
        File.delete(temporary_path) if File.file?(temporary_path)
      end
    end
    private_class_method :publish
  end
end
