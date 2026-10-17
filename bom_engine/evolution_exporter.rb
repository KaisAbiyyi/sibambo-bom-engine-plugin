# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'
require 'time'
require_relative 'bomc_extension'
require_relative 'bomc_size_gate'
require_relative 'evolution_document'
require_relative 'evolution_tree_writer'
require_relative 'evolution_canonical_writer'
require_relative 'evolution_cleanpkg_writer'
require_relative 'evolution_validator'
require_relative 'performance_trace'

module BOMEngine
  module EvolutionExporter
    HISTORICAL_BASELINES = {
      e1: 'abdc70bbfd176c481be4a6a3e71f4a9944d4faee',
      e2: '657d8671a66a78d643935d891e5c8b07154b8948',
      e3: 'd245b6873a992c87f7647c6b816c13e6ab7815e0'
    }.freeze
    WRITERS = {
      e1: { writer: EvolutionTreeWriter, id: 'evolution-tree-2.2', extension: '.json', format: 'tiered-json', version: '2.2' },
      e2: { writer: EvolutionCanonicalWriter, id: 'evolution-canonical-3.1.0', extension: '.json.gz', format: 'canonical-v3', version: '3.1.0' },
      e3: { writer: EvolutionCleanPKGWriter, id: 'evolution-cleanpkg-1.1.0', extension: '.cleanpkg', format: 'cleanpkg', version: '1.1.0' }
    }.freeze
    PROFILES = %i[visual research exact].freeze
    SOURCE_EXCLUDED = %w[tests tools benchmarks graphify-out].freeze

    class ModelChanged < StandardError; end

    ObserverBase = if defined?(Sketchup::ModelObserver)
                     Sketchup::ModelObserver
                   else
                     Object
                   end

    class RevisionObserver < ObserverBase
      attr_reader :revision

      def initialize
        @revision = 0
      end

      def onTransactionCommit(_model)
        @revision += 1
      end

      def onEraseAll(_model)
        @revision += 1
      end

      def onDeleteModel(_model)
        @revision += 1
      end
    end

    class ModelRevisionGuard
      attr_reader :observer

      def initialize(model, active_model: nil)
        @model = model
        @active_model = active_model
        @observer = RevisionObserver.new
        @identity = identity(model)
        @path = model.respond_to?(:path) ? model.path.to_s : ''
        @start_revision = @observer.revision
        @attached = false
      end

      def attach
        @model.add_observer(@observer) if @model.respond_to?(:add_observer)
        @attached = true
        self
      end

      def check!
        raise ModelChanged, 'The active SketchUp model changed during Evolution export.' if @active_model && !@active_model.call.equal?(@model)
        raise ModelChanged, 'The SketchUp model identity changed during Evolution export.' unless identity(@model) == @identity
        current_path = @model.respond_to?(:path) ? @model.path.to_s : ''
        raise ModelChanged, 'The SketchUp model path changed during Evolution export.' unless current_path == @path
        raise ModelChanged, 'The SketchUp model was edited during Evolution export.' unless @observer.revision == @start_revision
        true
      end

      def detach
        @model.remove_observer(@observer) if @attached && @model.respond_to?(:remove_observer)
      ensure
        @attached = false
      end

      private

      def identity(model)
        if model.respond_to?(:guid) && !model.guid.to_s.empty?
          "guid:#{model.guid}"
        else
          "object:#{model.object_id}"
        end
      end
    end

    module_function

    def source_tree_files(root = File.expand_path('..', __dir__))
      prefix = root.tr('\\', '/') + '/'
      Dir.glob(File.join(root, 'bom_engine', '**', '*')).sort.each_with_object({}) do |path, files|
        next unless File.file?(path)
        relative = path.tr('\\', '/').delete_prefix(prefix)
        parts = relative.split('/')
        next if (parts & SOURCE_EXCLUDED).any? || File.basename(path) == 'BUILD_SHA.txt'
        raise "Symlink not allowed in Evolution runtime: #{path}" if File.symlink?(path)
        files[relative] = Digest::SHA256.file(path).hexdigest
      end
    end

    def source_tree_sha256(root = File.expand_path('..', __dir__))
      packaged_identity = File.join(root, 'bom_engine', 'BUILD_SHA.txt')
      if File.file?(packaged_identity)
        value = File.read(packaged_identity, encoding: 'UTF-8').strip.downcase
        raise 'Packaged Evolution BUILD_SHA is invalid' unless value.match?(/\A[0-9a-f]{64}\z/)
        return value
      end
      Digest::SHA256.hexdigest(JSON.generate(source_tree_files(root).sort.to_h))
    end

    def normalize_engine(value)
      engine = value.to_s.downcase.to_sym
      raise ArgumentError, "Unsupported Evolution engine: #{value}" unless WRITERS.key?(engine)
      engine
    end

    def normalize_profile(value)
      profile = value.to_s.downcase.to_sym
      raise ArgumentError, "Unsupported Evolution profile: #{value}" unless PROFILES.include?(profile)
      profile
    end

    def normalize_output_path(path, engine:, profile:)
      engine = normalize_engine(engine)
      profile = normalize_profile(profile)
      text = path.to_s.strip
      raise ArgumentError, 'Evolution output path is empty.' if text.empty?
      base = text.sub(/__E[1-3]__(?:VISUAL|RESEARCH|EXACT)(?:\.json(?:\.gz)?|\.cleanpkg)\z/i, '')
      base = base.sub(/(?:\.json(?:\.gz)?|\.cleanpkg)\z/i, '')
      "#{base}__#{engine.to_s.upcase}__#{profile.to_s.upcase}#{WRITERS.fetch(engine).fetch(:extension)}"
    end

    def performance_receipt_path(output_path, status: :success)
      normalized = status.to_s
      return "#{output_path}.performance.json" if normalized == 'success'

      "#{output_path}.performance.#{normalized}.json"
    end

    def finalize_performance_trace(output_path, trace, status:, error: nil, metadata: nil)
      receipt = trace.finish(status: status, error: error, metadata: metadata)
      path = performance_receipt_path(output_path, status: status)
      PerformanceTrace.write_receipt(path, receipt)
      { path: path, receipt: receipt }
    end

    def export(model, engine:, profile:, output_path:, processing: nil, progress: nil, active_model: nil, performance_trace: nil)
      engine = normalize_engine(engine)
      profile = normalize_profile(profile)
      output_path = normalize_output_path(output_path, engine: engine, profile: profile)
      info = WRITERS.fetch(engine)
      trace = performance_trace || PerformanceTrace.new(
        enabled: true,
        metadata: { engine: engine, profile: profile, format: info.fetch(:format), writer_id: info.fetch(:id) },
        resource_sampling: :selected
      )
      trace_status = :success
      trace_error = nil
      guard = nil
      result = nil
      performance_metadata = { requested_output_path: output_path }
      PerformanceTrace.with(trace) do
        source_tree = PerformanceTrace.stage(:source_tree_hash) { source_tree_sha256 }
        performance_metadata[:source_tree_sha256] = source_tree
        source_info = BOMCSizeGate.source_info(model.respond_to?(:path) ? model.path.to_s : '')
        guard = ModelRevisionGuard.new(model, active_model: active_model).attach
        parent = File.dirname(File.expand_path(output_path))
        FileUtils.mkdir_p(parent)
        Dir.mktmpdir('.evolution-export-', parent) do |job_dir|
          texture_dir = File.join(job_dir, 'textures')
          FileUtils.mkdir_p(texture_dir)
          checkpoint = lambda do |event = {}|
            guard.check!
            progress.call(event.merge(phase: :capturing)) if progress
          end
          checkpoint.call(stage: :capture, processed: 0, total: 1, force: true)
          graph = PerformanceTrace.stage(:evolution_capture) do
            BOMCExtension.capture_graph(
              model,
              texture_directory: texture_dir,
              checkpoint: checkpoint,
              profile: profile,
              processing: processing,
              texture_representation: :portable,
              source_info: source_info
            )
          end
          guard.check!
          progress.call(phase: :compiling, stage: :graph_detach, processed: 0, total: 2, force: true) if progress
          document = EvolutionDocument.prepare(
            graph,
            engine: engine,
            profile: profile,
            source_tree_sha256: source_tree,
            historical_baseline_sha: HISTORICAL_BASELINES.fetch(engine)
          )
          candidate = File.join(job_dir, "candidate#{info.fetch(:extension)}")
          progress.call(phase: :compiling, stage: :evolution_writer, processed: 1, total: 2, force: true) if progress
          PerformanceTrace.stage(:evolution_writer, details: { engine: engine }) do
            info.fetch(:writer).write(candidate, document)
          end
          progress.call(phase: :validating, stage: :evolution_readback, processed: 0, total: 1, force: true) if progress
          validation = EvolutionValidator.validate_file!(candidate, engine: engine, expected_profile: profile, source_document: document)
          guard.check!
          sidecar = PerformanceTrace.stage(:provenance_build) do
            build_provenance(model, candidate, engine: engine, profile: profile, source_tree_sha256: source_tree,
              format: info.fetch(:format), writer_id: info.fetch(:id), source_info: source_info)
          end
          performance_metadata[:source_model] = sidecar[:model]
          performance_metadata[:artifact] = sidecar[:artifact]
          sidecar_candidate = File.join(job_dir, 'candidate.provenance.json')
          File.binwrite(sidecar_candidate, JSON.pretty_generate(sidecar) + "\n")
          guard.check!
          sidecar_path = "#{output_path}.provenance.json"
          progress.call(phase: :publishing, stage: :publication, processed: 0, total: 1, force: true) if progress
          PerformanceTrace.stage(:publication) do
            publish_pair(candidate, sidecar_candidate, output_path, sidecar_path)
          end
          artifact_sha = PerformanceTrace.stage(:published_artifact_hash, counts: { bytes: File.size(output_path) }) do
            Digest::SHA256.file(output_path).hexdigest
          end
          result = {
            path: output_path,
            sidecar_path: sidecar_path,
            bytes: File.size(output_path),
            sha256: artifact_sha,
            engine: engine,
            profile: profile,
            writer_id: info.fetch(:id),
            output_version: info.fetch(:version),
            source_tree_sha256: source_tree,
            validation: validation.reject { |key, _| key == :decoded }
          }
          performance_metadata[:artifact] = performance_metadata[:artifact].merge(path: output_path, sha256: artifact_sha, bytes: File.size(output_path))
        end
      end
      result
    rescue StandardError => error
      trace_status = PerformanceTrace.cancellation_error?(error) ? :cancelled : :error
      trace_error = error
      raise
    ensure
      guard&.detach
      if trace && output_path
        begin
          if trace_status != :success && File.file?(output_path)
            performance_metadata[:preserved_existing_artifact] = {
              path: output_path,
              bytes: File.size(output_path),
              sha256: Digest::SHA256.file(output_path).hexdigest
            }
          end
          finalized = finalize_performance_trace(output_path, trace, status: trace_status, error: trace_error, metadata: performance_metadata)
          result[:performance_receipt_path] = finalized[:path] if result.is_a?(Hash)
        rescue StandardError => performance_error
          if result.is_a?(Hash)
            result[:performance_receipt_error] = "#{performance_error.class}: #{performance_error.message}"
          end
        end
      end
    end

    def build_provenance(model, artifact_path, engine:, profile:, source_tree_sha256:, format:, writer_id:, source_info: nil)
      bytes = File.size(artifact_path)
      sha = Digest::SHA256.file(artifact_path).hexdigest
      model_record = model_source_record(model, source_info: source_info)
      now = Time.now.utc.iso8601
      {
        schema: 'sibambo-research-provenance-v1',
        engine: engine.to_s,
        artifact: { sha256: sha, bytes: bytes, format: format, profile: profile.to_s },
        producer: { label: "Sibambo Evolution #{writer_id}", sourceTreeSha256: source_tree_sha256 },
        model: model_record,
        capture: {
          id: "evolution-#{engine}-#{SecureRandom.uuid}",
          exportedAt: now,
          evidence: "Evolution exporter capture #{engine.to_s.upcase}/#{profile.to_s.upcase}",
          method: 'exporter-capture'
        }
      }
    end

    def model_source_record(model, source_info: nil)
      path = model.respond_to?(:path) ? model.path.to_s : ''
      id = if model.respond_to?(:guid) && !model.guid.to_s.empty?
             model.guid.to_s
           elsif model.respond_to?(:name) && !model.name.to_s.empty?
             model.name.to_s
           else
             "sketchup-model-#{model.object_id}"
           end
      record = { id: id }
      if source_info && source_info[:available]
        record[:sourceSha256] = source_info[:sha256]
        record[:sourceBytes] = source_info[:bytes]
      elsif !path.empty? && File.file?(path)
        record[:sourceSha256] = Digest::SHA256.file(path).hexdigest
        record[:sourceBytes] = File.size(path)
      end
      record
    end

    def publish_pair(artifact_candidate, sidecar_candidate, output_path, sidecar_path, move: nil)
      mover = move || lambda { |source, destination| FileUtils.mv(source, destination, force: true) }
      token = "#{Process.pid}-#{SecureRandom.hex(6)}"
      backup_artifact = "#{output_path}.#{token}.bak"
      backup_sidecar = "#{sidecar_path}.#{token}.bak"
      artifact_had_old = File.file?(output_path)
      sidecar_had_old = File.file?(sidecar_path)
      FileUtils.mv(output_path, backup_artifact) if artifact_had_old
      FileUtils.mv(sidecar_path, backup_sidecar) if sidecar_had_old
      begin
        mover.call(artifact_candidate, output_path)
        mover.call(sidecar_candidate, sidecar_path)
        File.delete(backup_artifact) if File.file?(backup_artifact)
        File.delete(backup_sidecar) if File.file?(backup_sidecar)
      rescue StandardError
        File.delete(output_path) if File.file?(output_path)
        File.delete(sidecar_path) if File.file?(sidecar_path)
        FileUtils.mv(backup_artifact, output_path) if File.file?(backup_artifact)
        FileUtils.mv(backup_sidecar, sidecar_path) if File.file?(backup_sidecar)
        raise
      ensure
        File.delete(backup_artifact) if File.file?(backup_artifact)
        File.delete(backup_sidecar) if File.file?(backup_sidecar)
      end
      { path: output_path, sidecar_path: sidecar_path }
    end
  end
end
