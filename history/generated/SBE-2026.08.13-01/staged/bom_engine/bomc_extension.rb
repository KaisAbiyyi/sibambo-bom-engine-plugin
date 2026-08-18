# SketchUp-facing BOMC exporter. Pure helper methods remain testable standalone.

require 'fileutils'
require 'tmpdir'
require_relative 'bomc_writer'

if defined?(Sketchup) && defined?(UI)
  require_relative 'core'
  require_relative 'canonical_graph_builder'
  require_relative 'material_extractor'
  require_relative 'spatial_analyzer'
end

module SibamboHistory
  module V20260813_01
  module BOMCExtension
    DEFAULT_PROFILE = :production
    FORMAT_EXTENSION = '__SBE-2026.08.13-01.bomc'.freeze

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

    def export(model, output_path:, profile: DEFAULT_PROFILE, progress: nil)
      texture_directory = Dir.mktmpdir('bomc-textures')
      begin
        texture_writer = begin
          Sketchup.create_texture_writer
        rescue StandardError
          nil
        end
        extracted_materials = MaterialExtractor.extract(model, texture_writer, texture_directory)
        progress.call(stage: 'Building canonical graph', processed: 0) if progress
        build_arguments = {
          model: model,
          entities: model.entities,
          parent_transform: Geom::Transformation.new,
          settings: {
            selection_only: false,
            include_edges: true,
            export_textures: true,
            output_format: 'bomc_v1',
            texture_directory: texture_directory
          },
          spatial: SpatialAnalyzer.analyze(model),
          texture_writer: texture_writer
        }
        supports_progress = CanonicalGraphBuilder.method(:build).parameters.any? do |kind, name|
          [:key, :keyreq].include?(kind) && name == :progress
        end
        build_arguments[:progress] = progress if supports_progress
        graph = CanonicalGraphBuilder.build(**build_arguments)
        attach_staged_textures(graph, extracted_materials, texture_directory)
        progress.call(stage: 'Compiling BOMC sections', processed: 0) if progress
        result = publish_graph(output_path, graph, profile: profile, base_path: texture_directory)
        result.merge(format: 'bomc', profile: profile)
      ensure
        FileUtils.remove_entry(texture_directory) if texture_directory && Dir.exist?(texture_directory)
      end
    end

    def export_interactive
      model = Sketchup.active_model
      return UI.messagebox('Model SketchUp tidak tersedia.', MB_OK) if model.nil?

      suggested = output_path(model)
      chosen = UI.savepanel('Export Compiled BOMC', File.dirname(suggested), File.basename(suggested))
      return nil if chosen.nil?
      chosen += FORMAT_EXTENSION unless chosen.downcase.end_with?(FORMAT_EXTENSION)
      started_at = Time.now
      result = export(model, output_path: chosen, profile: DEFAULT_PROFILE)
      elapsed = (Time.now - started_at).round(3)
      message = "BOMC export selesai!\n\nFile: #{result[:path]}\nUkuran: #{result[:bytes]} bytes\nWaktu: #{elapsed}s\nFormat: BOMC 1.0"
      Logger.info(message.gsub("\n", ' | ')) if defined?(Logger)
      UI.messagebox(message, MB_OK)
      result
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

    def attach_staged_textures(graph, extracted_materials, texture_directory)
      by_name = {}
      Array(extracted_materials).each { |material| by_name[material[:name].to_s] = material }
      Array(graph[:materials]).each do |material|
        extracted = by_name[material[:name].to_s]
        next unless extracted && extracted[:texture]
        path = File.join(texture_directory, extracted[:texture][:filename].to_s)
        next unless File.file?(path)
        material[:texture] ||= {}
        material[:texture][:source_path] = path
        material[:texture][:filename] = extracted[:texture][:filename]
      end
      graph
    end
    private_class_method :attach_staged_textures
  end
end

if defined?(Sketchup) && defined?(UI) && defined?(file_loaded?)
  unless file_loaded?(__FILE__)
    SibamboHistory::V20260813_01::BOMCExtension.register_menu(UI.menu('Plugins'))
    file_loaded(__FILE__)
  end
end

end # SibamboHistory
