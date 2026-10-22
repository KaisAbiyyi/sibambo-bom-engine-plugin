# SketchUp-facing BOMC exporter. Pure helper methods remain testable standalone.

require 'fileutils'
require 'tmpdir'
require 'securerandom'
require 'json'
require 'digest'
require 'pathname'
require_relative 'branding'
require_relative 'bomc_dialog'
require_relative 'bomc_decoder'
require_relative 'bomc_export_job'
require_relative 'bomc_processing'
require_relative 'bomc_size_gate'
require_relative 'bomc_writer'
require_relative 'bomc_validator'
require_relative 'conversion_job'
require_relative 'capture_ir'
require_relative 'performance_trace'
require_relative 'evolution_export_policy'

if defined?(Sketchup) && defined?(UI)
  require_relative 'core'
  require_relative 'canonical_graph_builder'
  require_relative 'material_extractor'
end

module BOMEngine
  module BOMCExtension
    class ExportAllError < StandardError
      attr_reader :directory

      def initialize(directory, message)
        @directory = directory
        super(message)
      end
    end

    DEFAULT_PROFILE = :visual
    FORMAT_EXTENSION = '.bomc'.freeze
    VERSION_SUFFIX = "__SIBAMBO-BOMC-v#{Branding::EXTENSION_VERSION}#{FORMAT_EXTENSION}".freeze
    ALLOWED_BATCH_SIZES = [96, 128, 256, 512, 1_024, 2_048, 4_096, 8_192].freeze

    module_function

    def output_directory(model)
      path = model.path.to_s
      return File.join(File.dirname(path), 'model-eval-exports') if !path.empty? && (!Gem.win_platform? || path.match?(/\AD:[\\\/]/i))

      if Gem.win_platform? && Dir.exist?('D:/')
        return 'D:/SibamboExports'
      end

      profile = ENV['USERPROFILE'].to_s
      profile = Dir.home if profile.empty?
      File.join(profile, 'Documents', 'BOMEngineExports')
    end

    def output_path(model)
      output_path_for_profile(model, profile: DEFAULT_PROFILE)
    end

    def output_path_for_profile(model, profile: DEFAULT_PROFILE)
      source_path = model.path.to_s
      base_name = source_path.empty? ? 'Untitled' : File.basename(source_path, File.extname(source_path))
      normalize_output_path(File.join(output_directory(model), base_name), profile: profile)
    end

    def normalize_output_path(path, profile: DEFAULT_PROFILE)
      base = output_base_path(path)
      normalized_profile = EvolutionExportPolicy.profile(profile)
      "#{base}__SIBAMBO-BOMC-v#{Branding::EXTENSION_VERSION}__#{normalized_profile.to_s.upcase}#{FORMAT_EXTENSION}"
    end

    def performance_receipt_path(output_path, status: :success)
      normalized = status.to_s
      return "#{output_path}.performance.json" if normalized == 'success'

      "#{output_path}.performance.#{normalized}.json"
    end

    def output_base_path(path)
      base = path.to_s.strip
      base = base.sub(/(?:_(?:bom|canonical|model-eval|runtime))?\.(?:skp|json|bome2|cleanpkg|bomc)(?:\.gz)?\z/i, '')
      base = base.sub(/__SBE-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9A-Z]+\z/i, '')
      base = base.sub(/__SIBAMBO-BOMC-v[0-9]+\.[0-9]+\.[0-9]+(?:__(?:EXACT|RESEARCH|VISUAL))?\z/i, '')
      base
    end

    def normalize_dialog_settings(payload)
      values = payload.transform_keys(&:to_sym)
      requested = values[:profile].to_s.downcase
      EvolutionExportPolicy.profile(requested) unless requested == 'all'
      profile = requested.to_sym
      base = output_base_path(values[:output_path])
      raise ArgumentError, 'Pilih lokasi keluaran terlebih dahulu.' if base.empty?
      raise ArgumentError, 'Gunakan lokasi lengkap dengan nama dasar file, bukan folder.' unless absolute_output_base?(base) && !base.match?(/[\\\/]\z/)
      batch_mode = values[:batch_mode] || (values.key?(:batch_size) ? 'manual' : 'auto')
      processing = BOMCProcessing.from_ui(batch_mode: batch_mode, batch_size: values[:batch_size])
      {
        output_path: profile == :all ? base : normalize_output_path(base, profile: profile),
        profile: profile,
        processing: processing
      }
    end

    def absolute_output_base?(path)
      value = path.to_s
      Pathname.new(value).absolute? ||
        value.match?(/\A[A-Za-z]:[\\\\\/]/) ||
        value.start_with?('\\\\', '//')
    end
    private_class_method :absolute_output_base?

    def publish_validated(candidate:, report:, output_path:, source_info: nil)
      unless report && (report[:passed] == true || report['passed'] == true)
        raise BOMCValidator::ProfileValidationError.new('Cannot publish: validation report did not pass.', report: report)
      end

      bytes = candidate.is_a?(Hash) ? (candidate[:bytes] || candidate['bytes']) : candidate
      raise ArgumentError, 'Candidate bytes must be a binary String' unless bytes.is_a?(String)

      if source_info
        require_experimental_source!(source_info)
        if File.expand_path(output_path) == File.expand_path(source_info.fetch(:path))
          raise ArgumentError, 'Experimental Exact output path must differ from its saved SKP source.'
        end
        assert_source_identity!(source_info)
        if bytes.bytesize >= source_info.fetch(:bytes)
          raise_target_not_met!(candidate, source_info, bytes.bytesize)
        end
      end

      require_active_candidate_profile!(bytes, report)

      directory = File.dirname(output_path)
      FileUtils.mkdir_p(directory) unless Dir.exist?(directory)

      part_path = "#{output_path}.#{Process.pid}.part"
      emitted_digest = Digest::SHA256.new
      begin
        File.open(part_path, 'wb') do |file|
          offset = 0
          while offset < bytes.bytesize
            chunk = bytes.byteslice(offset, [1024 * 1024, bytes.bytesize - offset].min)
            file.write(chunk)
            emitted_digest.update(chunk)
            offset += chunk.bytesize
          end
          file.flush
          file.fsync rescue nil
        end
        written_bytes = File.size(part_path)
        raise IOError, 'Staged BOMC byte count does not match the validated candidate.' unless written_bytes == bytes.bytesize
        emitted_sha256 = emitted_digest.hexdigest
        expected_sha256 = candidate.is_a?(Hash) ? (candidate[:sha256] || candidate['sha256']) : nil
        if expected_sha256 && expected_sha256 != emitted_sha256
          raise IOError, 'Staged BOMC digest does not match the validated candidate.'
        end
        if source_info
          assert_source_identity!(source_info)
          raise_target_not_met!(candidate, source_info, written_bytes) unless written_bytes < source_info.fetch(:bytes)
        end
        FileUtils.mv(part_path, output_path, force: true)
      ensure
        File.delete(part_path) if File.file?(part_path)
      end

      {
        path: output_path,
        bytes: File.size(output_path),
        sha256: emitted_digest.hexdigest,
        published: true,
        report: report,
        source_skp_bytes: source_info && source_info[:bytes],
        source_skp_sha256: source_info && source_info[:sha256],
        size_target: source_info ? :under_source : nil
      }
    end

    # A passing historical validator report does not authorize a new export.
    # Inspect only the small encoding contract, without decoding model geometry.
    def require_active_candidate_profile!(bytes, report)
      sections = BOMC::Container.read_directory(bytes).fetch(:sections).select do |section|
        section[:type] == BOMC::SECTION_ENCODING_CONTRACT
      end
      unless sections.length == 1 && sections.first[:raw_size] == BOMCEncodingContract::SECTION_BYTE_SIZE
        raise ArgumentError, 'Cannot publish: expected one complete BOMC encoding contract.'
      end
      section = sections.first
      stored = bytes.byteslice(section[:offset], section[:stored_size])
      raise ArgumentError, 'Cannot publish: encoding contract checksum mismatch.' unless Zlib.crc32(stored) == section[:crc32]
      raw = case section[:codec]
            when BOMC::CODEC_STORE then stored
            when BOMC::CODEC_DEFLATE
              result = ''.b
              inflater = Zlib::Inflate.new
              begin
                inflater.inflate(stored) do |chunk|
                  if result.bytesize + chunk.bytesize > BOMCEncodingContract::SECTION_BYTE_SIZE
                    raise ArgumentError, 'Cannot publish: encoding contract exceeds its fixed size.'
                  end
                  result << chunk
                end
                raise ArgumentError, 'Cannot publish: truncated encoding contract.' unless inflater.finished?
                result
              ensure
                inflater.close
              end
            else
              raise ArgumentError, 'Cannot publish: unsupported encoding contract codec.'
            end
      actual = EvolutionExportPolicy.profile(BOMCEncodingContract.decode(raw).fetch(:profile))
      claimed = report[:profile] || report['profile']
      if claimed && EvolutionExportPolicy.profile(claimed) != actual
        raise ArgumentError, 'Cannot publish: validation report profile differs from candidate bytes.'
      end
      actual
    end
    private_class_method :require_active_candidate_profile!

    def publish_graph(path, graph, profile: DEFAULT_PROFILE, base_path: nil, source_info: nil, allow_jpeg_color_map: nil)
      prof = EvolutionExportPolicy.profile(profile)
      jcm_enabled = resolve_jpeg_color_map(prof, allow_jpeg_color_map)
      src_info = source_info || (graph.is_a?(Hash) ? graph[:source_info] : nil)
      if src_info.nil? && BOMCProfile.fetch(prof).requires_source_size?
        estimated = (graph.is_a?(Hash) && graph[:source_skp_bytes]) || 10_000_000
        src_info = { available: true, bytes: estimated }
      end
      candidate = BOMCSizeGate.compile_candidate(
        graph,
        source_info: src_info,
        profile: prof,
        base_path: base_path
      )
      decoded = BOMCDecoder.decode(candidate.fetch(:bytes), allow_jpeg_color_map: jcm_enabled)
      texture_evidence = (graph.is_a?(Hash) && graph[:materials]) ? graph[:materials].map { |m| m.dig(:texture, :encoding_evidence) }.compact : nil
      report = BOMCValidator.validate_profile!(
        source: graph,
        decoded: decoded,
        profile: prof,
        texture_evidence: texture_evidence,
        normalized_source: candidate[:normalized_source]
      )
      published = publish_validated(candidate: candidate, report: report, output_path: path)
      jcm_selected?(candidate) ? published.merge(required_loader: 'bomc-next-jcm-v1') : published
    end

    def export(model, output_path:, profile: DEFAULT_PROFILE, progress: nil, settings: nil, diagnostics: nil, allow_jpeg_color_map: nil, prepared_color_maps: nil, candidate_cache: nil, performance_trace: nil)
      profile = EvolutionExportPolicy.profile(profile)
      if Gem.win_platform? && Dir.exist?('D:/') && !File.expand_path(output_path).match?(/\AD:[\\\/]/i)
        raise ArgumentError, 'Simpan hasil ekspor BOMC di drive D:.'
      end
      jcm_enabled = resolve_jpeg_color_map(profile, allow_jpeg_color_map)
      processing = settings || BOMCProcessing.settings(:balanced)
      yield_callback = progress || ->(_event) {}
      trace = performance_trace || PerformanceTrace.new(
        enabled: true,
        metadata: { engine: 'e4', profile: profile, mode: processing[:mode], format: 'bomc-1.2' },
        resource_sampling: :selected
      )
      context = export_context(output_path, yield_callback, profile: profile, diagnostics: diagnostics,
        allow_jpeg_color_map: jcm_enabled, prepared_color_maps: prepared_color_maps,
        candidate_cache: candidate_cache, processing: processing, performance_trace: trace)
      result = BOMCExportJob.run(
        model: model,
        output_path: output_path,
        settings: processing,
        context: context
      ).merge(format: 'bomc', profile: profile, performance_receipt_path: performance_receipt_path(output_path))
      jcm_selected?(result) ? result.merge(required_loader: 'bomc-next-jcm-v1') : result
    end

    def export_all_profiles(model, output_path:, settings:, progress:)
      base = output_base_path(output_path)
      raise ArgumentError, 'Export All membutuhkan lokasi lengkap dan nama dasar keluaran.' unless absolute_output_base?(base) && !base.match?(/[\\\/]\z/)
      raise ArgumentError, 'Simpan model sebelum Export All agar kedua profil memakai sumber yang sama.' if model.path.to_s.empty? || (model.respond_to?(:modified?) && model.modified?)

      parent = File.dirname(base)
      FileUtils.mkdir_p(parent)
      directory = Dir.mktmpdir("#{File.basename(base)}__SIBAMBO-BOMC-v#{Branding::EXTENSION_VERSION}__ALL-", parent)
      records = {}
      active_profile = nil
      source_info = nil
      write_all_status(directory, 'in_progress', records)
      begin
        progress.call(stage: :PREPARING_ALL, processed: 0, total: 0, output_directory: directory, profile: :visual)
        Dir.mktmpdir('bomc-candidates', parent) do |cache_dir|
          cache = { directory: cache_dir, entries: {}, hits: 0, jpeg_quality: {}, jpeg_quality_hits: 0 }
          EvolutionExportPolicy::PROFILES.each do |profile|
            active_profile = profile
            assert_all_model_unchanged!(model)
            path = normalize_output_path(File.join(directory, File.basename(base)), profile: profile)
            report = export(model, output_path: path, profile: profile, settings: settings,
              candidate_cache: cache, progress: lambda do |event|
                assert_all_model_unchanged!(model)
                progress.call(event.merge(profile: profile))
              end)
            records[profile] = { path: report.fetch(:path), bytes: report.fetch(:bytes) }
            source_info ||= report[:source_info]
            write_all_status(directory, 'in_progress', records)
          end
        end
        write_all_status(directory, 'complete', records)
        { path: directory, profiles: records, source_info: source_info, mode: settings[:mode], status: 'complete' }
      rescue ConversionJob::Cancelled
        write_all_status(directory, 'cancelled', records, failed_profile: active_profile)
        raise
      rescue StandardError => error
        write_all_status(directory, 'partial_failed', records, failed_profile: active_profile, error: "#{error.class}: #{error.message}")
        raise ExportAllError.new(directory, "#{active_profile || 'Persiapan'} gagal; #{records.length} profil berhasil. Hasil parsial ada di #{directory}. #{error.message}")
      end
    end

    def assert_all_model_unchanged!(model)
      raise 'Model aktif berubah selama Export All.' if defined?(Sketchup) && Sketchup.active_model != model
      raise 'Model berubah selama Export All; hasil parsial belum satu sumber.' if model.respond_to?(:modified?) && model.modified?
    end
    private_class_method :assert_all_model_unchanged!

    def write_all_status(directory, status, records, failed_profile: nil, error: nil)
      data = { status: status, certified: false, profiles: records }
      data[:failed_profile] = failed_profile if failed_profile
      data[:error] = error if error
      File.write(File.join(directory, 'export-status.json'), JSON.pretty_generate(data) + "\n", encoding: 'UTF-8')
    end
    private_class_method :write_all_status

    def resolve_jpeg_color_map(profile, requested)
      unless requested.nil? || requested == true || requested == false
        raise ArgumentError, 'JPEG color-map capability must be true, false, or nil'
      end
      raise ArgumentError, 'JPEG color-map export is Exact-only' if requested == true && profile != :exact
      return false unless profile == :exact

      requested.nil? ? true : requested
    end
    private_class_method :resolve_jpeg_color_map

    def jcm_selected?(result)
      encodings = result.dig(:metrics, :textures, :encodings) || {}
      row = encodings[:jpeg_color_map] || encodings['jpeg_color_map']
      row && (row[:count] || row['count']).to_i > 0
    end
    private_class_method :jcm_selected?

    def require_experimental_source!(source)
      unless source && source[:available] == true && source[:bytes].is_a?(Integer) && source[:bytes] > 0 &&
          source[:path].is_a?(String) && !source[:path].empty? && source[:sha256].to_s.match?(/\A[0-9a-f]{64}\z/i)
        raise ArgumentError, 'Experimental Exact export requires a saved source path, byte count, and SHA-256 identity'
      end
    end
    private_class_method :require_experimental_source!

    def enforce_experimental_size!(candidate, source)
      require_experimental_source!(source)
      size = candidate.fetch(:bytes).bytesize
      return if size < source[:bytes]
      sections = candidate.fetch(:metrics).fetch(:sections, {}).map do |name, values|
        {name: name, stored_bytes: values[:stored_bytes], raw_bytes: values[:raw_bytes]}
      end.sort_by { |section| -section[:stored_bytes].to_i }.first(5)
      raise BOMCSizeGate::TargetNotMet.new(source_bytes: source[:bytes], hard_budget_bytes: source[:bytes]-1,
        best_candidate_bytes: size, attempts: [{strategy: :experimental_exact, candidate_bytes: size, status: :fail}],
        dominant_sections: sections)
    end
    private_class_method :enforce_experimental_size!

    def assert_source_identity!(source)
      path = source.fetch(:path)
      unless File.file?(path) && File.size(path) == source[:bytes] && Digest::SHA256.file(path).hexdigest == source[:sha256]
        raise ArgumentError, 'Saved SKP source changed since the Exact size candidate was measured.'
      end
      true
    end
    private_class_method :assert_source_identity!

    def raise_target_not_met!(candidate, source, actual_bytes)
      sections = candidate.is_a?(Hash) ? candidate.dig(:metrics, :sections) : nil
      dominant = (sections || {}).map do |name, values|
        { name: name, stored_bytes: values[:stored_bytes], raw_bytes: values[:raw_bytes] }
      end.sort_by { |section| -section[:stored_bytes].to_i }.first(5)
      raise BOMCSizeGate::TargetNotMet.new(source_bytes: source[:bytes], hard_budget_bytes: source[:bytes] - 1,
        best_candidate_bytes: actual_bytes, attempts: [{ strategy: :experimental_exact, candidate_bytes: actual_bytes, status: :fail }],
        dominant_sections: dominant)
    end
    private_class_method :raise_target_not_met!

    def export_interactive
      model = Sketchup.active_model
      return UI.messagebox('Model SketchUp tidak tersedia.', MB_OK) if model.nil?

      BOMCDialog.show(default_path: output_path(model)) do |dialog_settings|
        start_dialog_export(model, normalize_dialog_settings(dialog_settings))
      end
    rescue StandardError => error
      report_interactive_error(error)
    end

    def export_compact_exact_interactive
      model = Sketchup.active_model
      return UI.messagebox('Model SketchUp tidak tersedia.', MB_OK) if model.nil?
      if model.path.to_s.empty? || (model.respond_to?(:modified?) && model.modified?)
        return UI.messagebox('Simpan model SketchUp dan tutup perubahan yang belum disimpan sebelum membuat kandidat Exact ukuran.', MB_OK)
      end

      default = output_path_for_profile(model, profile: :exact)
      chosen = UI.savepanel('Save experimental Exact size candidate (requires JCM-capable model-eval)', File.dirname(default), File.basename(default))
      return unless chosen
      output = normalize_output_path(chosen, profile: :exact)
      settings = BOMCProcessing.settings(:balanced)
      ConversionJob.start(
        title: "#{Branding::EXTENSION_NAME} — Experimental Exact size candidate (not certified)",
        output_path: output,
        batch_size: settings[:max_items],
        kind: :export
      ) do |progress|
        export(model, output_path: output, profile: :exact, progress: progress, settings: settings,
          allow_jpeg_color_map: true)
      end
    rescue StandardError => error
      report_interactive_error(error)
    end
    private_class_method :export_compact_exact_interactive

    def start_dialog_export(model, options)
      chosen = options.fetch(:output_path)
      selected_profile = options.fetch(:profile)
      settings = options.fetch(:processing)
      all = selected_profile == :all
      ConversionJob.start(
        title: "#{Branding::EXTENSION_NAME} #{Branding::EXTENSION_VERSION} — Export BOMC #{Branding::BOMC_FORMAT_VERSION}",
        output_path: chosen,
        batch_size: settings[:max_items],
        kind: all ? :batch_export : :export
      ) do |progress|
        if all
          export_all_profiles(model, output_path: chosen, settings: settings, progress: progress)
        else
          export(model, output_path: chosen, profile: selected_profile, progress: progress, settings: settings)
        end
      end
    rescue StandardError => error
      report_interactive_error(error)
    end
    private_class_method :start_dialog_export

    def report_interactive_error(error)
      Logger.error("BOMC export failed: #{error.message}\n#{Array(error.backtrace).first(8).join("\n")}") if defined?(Logger)
      UI.messagebox("BOMC export gagal:\n#{error.message}", MB_OK)
      nil
    end
    private_class_method :report_interactive_error

    def register_menu(menu)
      menu.add_item('Sibambo BOMC Engine: Export BOMC 1.2...') do
        export_interactive
      end
      menu.add_item('About Sibambo BOMC Engine') do
        Core.show_about
      end
    end

    def export_context(output_path, yield_callback, profile: DEFAULT_PROFILE, diagnostics: nil, allow_jpeg_color_map: false, prepared_color_maps: nil, candidate_cache: nil, processing: nil, performance_trace: nil)
      parent = File.dirname(File.expand_path(output_path))
      FileUtils.mkdir_p(parent)
      texture_directory = Dir.mktmpdir('bomc-textures', parent)
      effective_cache = candidate_cache
      unless effective_cache
        cache_directory = File.join(texture_directory, 'candidate-cache')
        FileUtils.mkdir_p(cache_directory)
        effective_cache = { directory: cache_directory, entries: {}, hits: 0, jpeg_quality: {}, jpeg_quality_hits: 0 }
      end
      {
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        on_yield: yield_callback,
        cancelled: -> { false },
        performance_trace: performance_trace,
        performance_receipt: performance_trace ? lambda { |receipt|
          PerformanceTrace.write_receipt(performance_receipt_path(output_path, status: receipt[:status] || receipt['status']), receipt)
        } : nil,
        source_info: lambda do |model|
          BOMCSizeGate.source_info(model.path.to_s)
        end,
        snapshot: lambda do |model, checkpoint, source_info = nil|
          if effective_cache && source_info && source_info[:sha256]
            effective_cache[:scope_digest] = source_info[:sha256].to_s
          end
          graph = PerformanceTrace.stage(:capture_graph) do
            capture_graph(model, texture_directory: texture_directory, checkpoint: checkpoint, profile: profile,
              allow_jpeg_color_map: allow_jpeg_color_map, prepared_color_maps: prepared_color_maps,
              candidate_cache: effective_cache, processing: processing, texture_representation: :bomc,
              source_info: source_info)
          end
          diagnostics[:graph] = graph if diagnostics
          graph
        end,
        compile: lambda do |graph, source, _path, checkpoint|
          BOMCSizeGate.compile_candidate(
            graph,
            source_info: source,
            base_path: texture_directory,
            profile: profile,
            checkpoint: checkpoint
          )
        end,
        validate: lambda do |result, graph = nil|
          profiled = PerformanceTrace.stage(:decode_readback, counts: { bytes: result.fetch(:bytes).bytesize }) do
            BOMCDecoder.profile(result.fetch(:bytes), allow_jpeg_color_map: allow_jpeg_color_map)
          end
          decoded = profiled.fetch(:model)
          profiled.fetch(:timings, {}).each do |phase, milliseconds|
            PerformanceTrace.increment("decoder_#{phase}", milliseconds) if milliseconds.is_a?(Numeric)
          end
          texture_evidence = graph && graph[:materials] ? graph[:materials].map { |m| m.dig(:texture, :encoding_evidence) }.compact : nil
          report = PerformanceTrace.stage(:fidelity_validation) do
            if graph
              BOMCValidator.validate_profile!(
                source: graph,
                decoded: decoded,
                profile: profile,
                texture_evidence: texture_evidence,
                normalized_source: result[:normalized_source]
              )
            else
              { passed: true }
            end
          end
          triangles = decoded[:meshes].map do |mesh|
            mesh[:faces].map { |face| face[:triangles].length / 3 }.inject(0, :+)
          end.inject(0, :+)
          {
            nodes: decoded[:instances].length,
            triangles: triangles,
            unaccounted: decoded.dig(:coverage, :unaccounted),
            report: report
          }
        end,
          publish: lambda do |candidate, validation, path|
            publish_validated(
              candidate: candidate,
              report: validation[:report],
              output_path: path
            )
        end,
        cleanup: lambda do
          FileUtils.remove_entry(texture_directory) if Dir.exist?(texture_directory)
          partial = "#{output_path}.#{Process.pid}.part"
          File.delete(partial) if File.file?(partial)
        end
      }
    end
    private_class_method :export_context

    def normalize_profile(profile)
      value = profile.to_s.downcase.to_sym
      [:visual, :research, :exact].include?(value) ? value : DEFAULT_PROFILE
    end
    private_class_method :normalize_profile

    def compute_material_classes(model)
      return {} if model.nil?
      if model.respond_to?(:material_classes)
        supplied_classes = model.material_classes
        return supplied_classes if supplied_classes.is_a?(Hash)
      end
      return compute_material_classes_from_graph(model) if model.is_a?(Hash)

      # Hash-backed sets keep at most A/B/C per material and one membership
      # per texture/material pair, regardless of the number of faces using it.
      material_usages = Hash.new { |h, k| h[k] = {} }
      texture_materials = Hash.new { |h, k| h[k] = {} }
      visited_definitions = {}

      classify_entity = lambda do |entity, parent_role = nil|
        begin
          current_role = nil
          if entity.respond_to?(:name)
            defn_name = entity.definition.name if entity.respond_to?(:definition) && entity.definition.respond_to?(:name)
            tag_name = entity.layer.name if entity.respond_to?(:layer) && entity.layer.respond_to?(:name)
            if defined?(SemanticLabeler)
              built = SemanticLabeler.build(instance_name: entity.name, definition_name: defn_name, tag_name: tag_name)
              current_role = built[:role] if built
            end
          end
          role = current_role || (entity.respond_to?(:semantic_role) ? entity.semantic_role : nil) || parent_role
          klass = BOMCGeometryPolicy.classify_role(role)

          [:material, :back_material].each do |accessor|
            next unless entity.respond_to?(accessor)
            mat = entity.public_send(accessor)
            next unless mat
            material_usages[mat.name][klass] = true if mat.respond_to?(:name)
            material_usages[mat.object_id.to_s][klass] = true
            if mat.respond_to?(:texture) && mat.texture
              tex_key = mat.texture.respond_to?(:filename) ? mat.texture.filename : mat.texture.to_s
              texture_materials[tex_key][mat.respond_to?(:name) ? mat.name : mat.to_s] = true
            end
          end

          if entity.respond_to?(:definition) && entity.definition.respond_to?(:entities)
            definition = entity.definition
            definition_key = definition.object_id
            unless visited_definitions[definition_key]
              visited_definitions[definition_key] = true
              definition.entities.each { |child| classify_entity.call(child, role) }
            end
          end
        rescue StandardError => error
          Logger.warn("Skipping material classification for #{entity.class}: #{error.message}") if defined?(Logger)
        end
      end

      if model.respond_to?(:entities) && model.entities.respond_to?(:each)
        model.entities.each { |entity| classify_entity.call(entity) }
      end

      result = {}
      material_usages.each do |mat_key, classes|
        result[mat_key] = BOMCTexturePolicy.strictest_semantic_class(classes.keys)
      end

      texture_materials.each do |_tex_key, mat_names|
        all_classes = {}
        mat_names.each_key do |material_name|
          material_usages.fetch(material_name, {}).each_key { |klass| all_classes[klass] = true }
        end
        strictest = BOMCTexturePolicy.strictest_semantic_class(all_classes.keys)
        mat_names.each_key { |m| result[m] = strictest }
      end

      result
    end

    def compute_material_classes_from_graph(graph)
      material_usages = Hash.new { |h, k| h[k] = {} }
      texture_materials = Hash.new { |h, k| h[k] = {} }

      materials = Array(graph[:materials])
      mat_by_id = {}
      materials.each do |mat|
        mat_by_id[mat[:id].to_s] = mat
        mat_by_id[mat[:name].to_s] = mat
        if mat[:texture]
          tex_key = mat[:texture][:filename] || mat[:texture][:source_path] || mat[:texture][:name]
          texture_materials[tex_key][mat[:name].to_s] = true if tex_key
        end
      end

      Array(graph[:meshes]).each do |mesh|
        Array(mesh[:faces]).each do |face|
          role = face[:semantic_role] || face[:role]
          klass = BOMCGeometryPolicy.classify_role(role)
          [face[:front_material], face[:back_material], face[:material]].compact.each do |m_ref|
            mat = m_ref.is_a?(Integer) ? materials[m_ref] : (mat_by_id[m_ref.to_s] || { name: m_ref.to_s })
            if mat
              name = mat[:name].to_s
              material_usages[name][klass] = true
              material_usages[mat[:id].to_s][klass] = true if mat[:id]
            end
          end
        end
      end

      Array(graph[:nodes] || graph[:instances]).each do |node|
        role = node.dig(:semantic, :role) || node[:semantic_role]
        klass = BOMCGeometryPolicy.classify_role(role)
        m_ref = node[:material_override_id] || node[:material]
        if m_ref
          mat = m_ref.is_a?(Integer) ? materials[m_ref] : (mat_by_id[m_ref.to_s] || { name: m_ref.to_s })
          if mat
            name = mat[:name].to_s
            material_usages[name][klass] = true
            material_usages[mat[:id].to_s][klass] = true if mat[:id]
          end
        end
      end

      result = {}
      material_usages.each do |mat_key, classes|
        result[mat_key] = BOMCTexturePolicy.strictest_semantic_class(classes.keys)
      end

      texture_materials.each do |_tex_key, mat_names|
        all_classes = {}
        mat_names.each_key do |material_name|
          material_usages.fetch(material_name, {}).each_key { |klass| all_classes[klass] = true }
        end
        strictest = BOMCTexturePolicy.strictest_semantic_class(all_classes.keys)
        mat_names.each_key { |m| result[m] = strictest }
      end

      result
    end

    def capture_graph(model, texture_directory:, checkpoint:, profile: DEFAULT_PROFILE, processing: nil,
      texture_representation: :bomc, allow_jpeg_color_map: false, prepared_color_maps: nil, candidate_cache: nil,
      source_info: nil)
      representation = texture_representation.to_sym
      unless [:bomc, :portable].include?(representation)
        raise ArgumentError, "Unsupported texture representation: #{texture_representation}"
      end
      portable = representation == :portable
      snapshot_model(model, texture_directory, checkpoint, profile: profile,
        allow_jpeg_color_map: portable ? false : allow_jpeg_color_map,
        allow_semantic_colorize: !portable,
        prepared_color_maps: portable ? nil : prepared_color_maps,
        candidate_cache: candidate_cache,
        processing: processing,
        texture_representation: representation,
        source_info: source_info)
    end

    def snapshot_model(model, texture_directory, checkpoint, profile: DEFAULT_PROFILE, allow_jpeg_color_map: false,
      allow_semantic_colorize: true, prepared_color_maps: nil, candidate_cache: nil, processing: nil,
      texture_representation: :bomc, source_info: nil)
      texture_writer = begin
        Sketchup.create_texture_writer
      rescue StandardError
        nil
      end
      effective_cache = candidate_cache
      unless effective_cache
        cache_directory = File.join(texture_directory, '.candidate-cache')
        FileUtils.mkdir_p(cache_directory)
        effective_cache = { directory: cache_directory, entries: {}, hits: 0, jpeg_quality: {}, jpeg_quality_hits: 0 }
      end
      effective_cache[:scope_digest] = source_info[:sha256].to_s if source_info && source_info[:sha256]

      material_classes = PerformanceTrace.stage(:material_classification) { compute_material_classes(model) }
      extracted_materials = PerformanceTrace.stage(:material_extraction, sample_resources: true) do
        MaterialExtractor.extract(
          model,
          texture_writer,
          texture_directory,
          checkpoint: checkpoint,
          optimize_textures: true,
          profile: profile,
          material_classes: material_classes,
          allow_jpeg_color_map: allow_jpeg_color_map,
          allow_semantic_colorize: allow_semantic_colorize,
          record_reference_pixel_hash: texture_representation.to_sym == :portable,
          prepared_color_maps: prepared_color_maps,
          candidate_cache: effective_cache
        )
      end
      entity_total = model.entities.respond_to?(:length) ? model.entities.length : 0
      graph = PerformanceTrace.stage(:canonical_capture, counts: { root_entities: entity_total }, sample_resources: true) do
        if defined?(CanonicalGraphBuilder)
          CanonicalGraphBuilder.build(
                  model: model,
                  entities: model.entities,
                  parent_transform: defined?(Geom::Transformation) ? Geom::Transformation.new : nil,
                  settings: {
                    selection_only: false,
                    include_edges: true,
                    export_textures: true,
                    output_format: 'bomc_v1_1',
                    scene_scope: 'all',
                    preserve_hidden_geometry: profile.to_s == 'exact',
                    texture_directory: texture_directory
                  },
                  spatial: {},
                  texture_writer: texture_writer,
                  progress: lambda do |event|
                    # The export job checkpoint accepts keywords on SketchUp Ruby 3.
                    checkpoint.call(**canonical_work_checkpoint(event))
                  end,
                  # Probe the adaptive controller frequently without paying a
                  # callback on every entity. The controller still owns the
                  # actual 12 ms / item slice decision.
                  batch_size: 16
          )
        else
          { materials: extracted_materials, meshes: [], definitions: [], nodes: [], instances: [] }
        end
      end
      PerformanceTrace.stage(:texture_attach) do
        attach_staged_textures(graph, extracted_materials, texture_directory, profile: profile,
          texture_representation: texture_representation)
      end
      texture_evidence = Array(graph[:materials]).map do |material|
        texture = material[:texture]
        next unless texture

        {
          material_id: material[:id],
          filename: texture[:filename],
          byte_length: texture[:byte_length],
          sha256: texture[:sha256],
          displayed_rgba_sha256: texture[:displayed_rgba_sha256],
          encoding_evidence: texture[:encoding_evidence]
        }
      end.compact
      CaptureIR.wrap(
        graph,
        source_info: source_info,
        profile: profile,
        texture_representation: texture_representation,
        texture_evidence: texture_evidence
      )
    end
    private_class_method :snapshot_model

    def canonical_work_checkpoint(event)
      {
        stage: :snapshot_entities,
        processed: event[:processed].to_i,
        # CanonicalGraphBuilder counts recursive work checkpoints, NOT root
        # entities. Its final work count is unknown during traversal.
        total: 0,
        unit: 'langkah kanonis'
      }
    end
    private_class_method :canonical_work_checkpoint

    def validate_compiled_result(result)
      decoded = BOMCDecoder.decode(result.fetch(:bytes))
      triangles = decoded[:meshes].map do |mesh|
        mesh[:faces].map { |face| face[:triangles].length / 3 }.inject(0, :+)
      end.inject(0, :+)
      {
        nodes: decoded[:instances].length,
        triangles: triangles,
        unaccounted: decoded.dig(:coverage, :unaccounted)
      }
    end
    private_class_method :validate_compiled_result

    def attach_staged_textures(graph, extracted_materials, texture_directory, profile: DEFAULT_PROFILE, texture_representation: :bomc)
      by_name = {}
      Array(extracted_materials).each { |material| by_name[material[:name].to_s] = material }
      prof = normalize_profile(profile)
      Array(graph[:materials]).each do |material|
        extracted = by_name[material[:name].to_s]
        next unless extracted && extracted[:texture]
        material[:material_type]=extracted[:material_type] if extracted.key?(:material_type)
        material[:colorize_type]=extracted[:colorize_type] if extracted[:colorize_type]
        material[:colorize_deltas]=extracted[:colorize_deltas] if extracted[:colorize_deltas]
        material[:semantic_colorize_active]=extracted[:semantic_colorize_active]==true
        material[:colorize_output_sha256]=extracted[:colorize_output_sha256] if extracted[:colorize_output_sha256]
        staged_path = File.join(texture_directory, extracted[:texture][:filename].to_s)
        source_path = extracted[:texture][:source_path].to_s
        source_supported = texture_representation.to_sym == :bomc && File.file?(source_path) && supported_texture_path?(source_path)
        staging = extracted[:texture][:staging_evidence]
        if staging && staging[:policy_revision]
          captured_staged_bytes = extracted[:texture][:bytes]
          captured_staged_sha = extracted[:texture][:sha256].to_s.downcase
          expected_staged_sha = staging[:selected_sha256].to_s.downcase
          staged_valid = if captured_staged_bytes.is_a?(String) && captured_staged_sha.match?(/\A[0-9a-f]{64}\z/)
                           File.file?(staged_path) && captured_staged_bytes.bytesize == File.size(staged_path) &&
                             captured_staged_sha == expected_staged_sha
                         else
                           # Compatibility path for direct/legacy callers which did not
                           # originate from MaterialExtractor's detached capture payload.
                           File.file?(staged_path) && Digest::SHA256.file(staged_path).hexdigest == expected_staged_sha
                         end
          unless staged_valid
            raise 'Checked staged texture changed or is missing.'
          end
          # The original external path can be stale or contain uncolorized pixels.
          # It must not bypass the measured candidate from SketchUp's reference.
          source_supported = false
        end
        path = source_supported ? source_path : staged_path
        quality = staging && staging[:quality]
        verified_native_jpeg = staging && staging[:policy_revision] &&
          staging[:selected] == :native_jpeg_candidate && staging[:native_jpeg] == true &&
          staging[:profile].to_s == prof.to_s && staging[:alpha_preserved] == true &&
          quality && quality[:compatible] == true && quality[:alpha_preserved] == true &&
          quality[:mean_squared_error] == 0.0 && quality[:max_channel_error] == 0
        verified_semantic_native = staging && staging[:policy_revision] == BOMCTextureOptimizer::SEMANTIC_COLORIZE_REVISION &&
          staging[:selected] == :semantic_colorized_native && staging[:semantic_colorize_verified] == true &&
          quality && quality[:compatible] == true && quality[:alpha_preserved] == true &&
          quality[:mean_squared_error] == 0.0 && quality[:max_channel_error] == 0

        # An extracted JPEG is eligible only after complete displayed-pixel
        # equality and the staged-file digest check above, not filename alone.
        if prof == :exact && path.downcase.end_with?('.jpg', '.jpeg') && !source_supported && !verified_native_jpeg && !verified_semantic_native
          png_fallback = File.join(texture_directory, "#{File.basename(staged_path, '.*')}.png")
          path = png_fallback if File.file?(png_fallback)
        end

        next unless File.file?(path)
        if path == staged_path && extracted[:texture][:bytes].is_a?(String)
          texture_bytes = extracted[:texture][:bytes]
          texture_sha256 = extracted[:texture][:sha256].to_s.downcase
        else
          texture_bytes = File.binread(path).b.freeze
          texture_sha256 = Digest::SHA256.hexdigest(texture_bytes).freeze
        end
        material[:texture] ||= {}
        material[:texture][:source_path] = path
        material[:texture][:filename] = File.basename(path)
        material[:texture][:bytes] = texture_bytes
        material[:texture][:byte_length] = texture_bytes.bytesize
        material[:texture][:sha256] = texture_sha256
        displayed_rgba_sha256 = staging && (
          staging[:output_pixel_sha256] || staging[:reference_pixel_sha256] || staging[:displayed_rgba_sha256]
        )
        material[:texture][:displayed_rgba_sha256] = displayed_rgba_sha256 if displayed_rgba_sha256
        material[:texture][:encoding_evidence] = {
          filename: File.basename(path),
          byte_length: texture_bytes.bytesize,
          sha256: texture_sha256,
          displayed_rgba_sha256: displayed_rgba_sha256,
          material_type: extracted[:material_type],
          colorize_type: extracted[:colorize_type],
          semantic_colorize_active: extracted[:semantic_colorize_active] == true,
          semantic_colorize_candidate: extracted[:material_type].to_i == 2,
          native_jpeg: !!verified_native_jpeg,
          selected: source_supported ? :source : :staged,
          source_path: source_path.empty? ? nil : source_path,
          source_bytes: File.file?(source_path) ? File.size(source_path) : nil,
          staged_path: File.file?(staged_path) ? staged_path : nil,
          staged_bytes: File.file?(staged_path) ? File.size(staged_path) : nil,
          reason: source_supported ? :native_source_preserved : :source_unavailable_or_unsupported,
          staging: extracted[:texture][:staging_evidence]
        }
      end
      graph
    end
    private_class_method :attach_staged_textures

    def supported_texture_path?(path)
      extension = File.extname(path.to_s).downcase
      ['.png', '.jpg', '.jpeg', '.webp'].include?(extension)
    end
    private_class_method :supported_texture_path?
  end
end
