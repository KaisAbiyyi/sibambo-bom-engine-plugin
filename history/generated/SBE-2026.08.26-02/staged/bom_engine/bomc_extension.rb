# SketchUp-facing BOMC exporter. Pure helper methods remain testable standalone.

require 'fileutils'
require 'tmpdir'
require_relative 'bomc_decoder'
require_relative 'bomc_export_job'
require_relative 'bomc_processing'
require_relative 'bomc_size_gate'
require_relative 'bomc_writer'
require_relative 'conversion_job'

if defined?(Sketchup) && defined?(UI)
  require_relative 'core'
  require_relative 'canonical_graph_builder'
  require_relative 'material_extractor'
end

module SibamboHistory
  module V20260826_02
  module BOMCExtension
    DEFAULT_PROFILE = :production
    FORMAT_EXTENSION = '__SBE-2026.08.26-02.bomc'.freeze

    module_function

    def output_directory(model)
      path = model.path.to_s
      return File.join(File.dirname(path), 'model-eval-exports') unless path.empty?

      profile = ENV['USERPROFILE'].to_s
      profile = Dir.home if profile.empty?
      File.join(profile, 'Documents', 'BOMEngineExports')
    end

    def output_path(model)
      source_path = model.path.to_s
      base_name = source_path.empty? ? 'Untitled' : File.basename(source_path, File.extname(source_path))
      File.join(output_directory(model), "#{base_name}#{FORMAT_EXTENSION}")
    end

    def publish_graph(path, graph, profile: DEFAULT_PROFILE, base_path: nil)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
      BOMCWriter.write(path, graph, profile: profile, base_path: base_path)
    end

    def export(model, output_path:, profile: DEFAULT_PROFILE, progress: nil, settings: nil)
      processing = settings || BOMCProcessing.settings(:balanced)
      yield_callback = progress || ->(_event) {}
      context = export_context(output_path, yield_callback)
      BOMCExportJob.run(
        model: model,
        output_path: output_path,
        settings: processing,
        context: context
      ).merge(format: 'bomc', profile: profile)
    end

    def export_interactive
      model = Sketchup.active_model
      return UI.messagebox('Model SketchUp tidak tersedia.', MB_OK) if model.nil?

      suggested = output_path(model)
      chosen = UI.savepanel('Export Compiled BOMC', File.dirname(suggested), File.basename(suggested))
      return nil if chosen.nil?
      chosen += FORMAT_EXTENSION unless chosen.downcase.end_with?(FORMAT_EXTENSION)
      settings = choose_processing_settings
      return nil if settings.nil?
      ConversionJob.start(
        title: 'Export Compiled BOMC 1.1',
        output_path: chosen,
        batch_size: settings[:max_items]
      ) do |progress|
        export(
          model,
          output_path: chosen,
          profile: DEFAULT_PROFILE,
          progress: progress,
          settings: settings
        )
      end
    rescue StandardError => error
      Logger.error("BOMC export failed: #{error.message}\n#{Array(error.backtrace).first(8).join("\n")}") if defined?(Logger)
      UI.messagebox("BOMC export gagal:\n#{error.message}", MB_OK)
      nil
    end

    def register_menu(menu)
      menu.add_item('BOM Engine: Export Compiled BOMC...') do
        export_interactive
      end
    end

    def choose_processing_settings
      answer = UI.inputbox(
        ['Processing preset'],
        ['Balanced'],
        ['Light / Stable|Balanced|Fast|Custom'],
        'BOMC Responsiveness'
      )
      return nil if answer.nil?
      label = answer[0].to_s.downcase
      mode = label.start_with?('light') ? :light : label.to_sym
      return BOMCProcessing.settings(mode) unless mode == :custom

      custom = UI.inputbox(
        ['Maximum items per slice', 'Maximum milliseconds per slice'],
        [256, 24.0],
        'Custom BOMC Budget'
      )
      return nil if custom.nil?
      BOMCProcessing.settings(:custom, custom: { max_items: custom[0], max_ms: custom[1] })
    end
    private_class_method :choose_processing_settings

    def export_context(output_path, yield_callback)
      texture_directory = Dir.mktmpdir('bomc-textures')
      {
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        on_yield: yield_callback,
        cancelled: -> { false },
        source_info: ->(model) { BOMCSizeGate.source_info(model.path.to_s) },
        snapshot: lambda do |model, checkpoint|
          snapshot_model(model, texture_directory, checkpoint)
        end,
        compile: lambda do |graph, source, path, checkpoint|
          BOMCSizeGate.compile(
            graph: graph,
            source_info: source,
            base_path: texture_directory,
            checkpoint: checkpoint,
            output_path: path
          )
        end,
        validate: ->(result) { validate_compiled_result(result) },
        cleanup: lambda do
          FileUtils.remove_entry(texture_directory) if Dir.exist?(texture_directory)
          partial = "#{output_path}.#{Process.pid}.part"
          File.delete(partial) if File.file?(partial)
        end
      }
    end
    private_class_method :export_context

    def snapshot_model(model, texture_directory, checkpoint)
      texture_writer = begin
        Sketchup.create_texture_writer
      rescue StandardError
        nil
      end
      extracted_materials = MaterialExtractor.extract(
        model,
        texture_writer,
        texture_directory,
        checkpoint: checkpoint,
        optimize_textures: true
      )
      entity_total = model.entities.respond_to?(:length) ? model.entities.length : 0
      graph = CanonicalGraphBuilder.build(
        model: model,
        entities: model.entities,
        parent_transform: Geom::Transformation.new,
        settings: {
          selection_only: false,
          include_edges: true,
          export_textures: true,
          output_format: 'bomc_v1_1',
          scene_scope: 'all',
          texture_directory: texture_directory
        },
        spatial: {},
        texture_writer: texture_writer,
        progress: lambda do |event|
          checkpoint.call(
            stage: :snapshot_entities,
            processed: event[:processed].to_i,
            total: entity_total
          )
        end,
        batch_size: 1
      )
      attach_staged_textures(graph, extracted_materials, texture_directory)
    end
    private_class_method :snapshot_model

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

    def attach_staged_textures(graph, extracted_materials, texture_directory)
      by_name = {}
      Array(extracted_materials).each { |material| by_name[material[:name].to_s] = material }
      Array(graph[:materials]).each do |material|
        extracted = by_name[material[:name].to_s]
        next unless extracted && extracted[:texture]
        staged_path = File.join(texture_directory, extracted[:texture][:filename].to_s)
        source_path = extracted[:texture][:source_path].to_s
        source_supported = File.file?(source_path) && supported_texture_path?(source_path)
        path = source_supported ? source_path : staged_path
        next unless File.file?(path)
        material[:texture] ||= {}
        material[:texture][:source_path] = path
        material[:texture][:filename] = File.basename(path)
        material[:texture][:encoding_evidence] = {
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

if defined?(Sketchup) && defined?(UI) && defined?(file_loaded?)
  unless defined?(SibamboHistory::EVOLUTION_LAB_EMBEDDED) || file_loaded?(__FILE__)
    SibamboHistory::V20260826_02::BOMCExtension.register_menu(UI.menu('Plugins'))
    file_loaded(__FILE__)
  end
end

end # SibamboHistory
