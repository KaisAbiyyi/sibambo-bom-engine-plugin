# frozen_string_literal: true

require_relative '../semantic_v2/identity_coordinator'
require_relative '../semantic_v2/extractor'

module BOMEngine
  module CleanAnalysis
    module Exporter
      EXTRACTION_POLICY_ID = 'bom-clean-analysis/1.0.0'.freeze

      module_function

      def export(model:, roots:, parent_transform:, output_path:, identity_plan: nil, settings: {},
                 progress: nil, batch_size: 24, pretty_print: false, profile: false)
        root_items = Array(roots)
        batcher = ProgressBatcher.new(progress, batch_size)
        batcher.force('Preparing clean export')
        plan = identity_plan || SemanticV2::IdentityCoordinator.plan(
          model: model,
          roots: root_items,
          progress: batcher.method(:step),
          prepare_model_writes: false,
          deterministic_virtual_identities: true
        )
        extraction_settings = {
          include_hidden: false,
          extraction_policy_id: EXTRACTION_POLICY_ID
        }.merge(settings || {})
        snapshot = SemanticV2::Extractor.extract(
          model: model,
          roots: root_items,
          parent_transform: parent_transform,
          identity_plan: plan,
          settings: extraction_settings,
          progress: batcher.method(:step)
        )
        visual_edges = VisualEdgeExtractor.extract(
          roots: root_items,
          identity_plan: plan,
          snapshot: snapshot,
          include_hidden: extraction_settings.fetch(:include_hidden, false),
          progress: batcher.method(:step)
        )
        batcher.force('Compiling architectural surfaces')
        profiler = profile ? Profiler.new(snapshot) : nil
        document = Compiler.compile(
          snapshot,
          progress: batcher.method(:step),
          profiler: profiler,
          visual_edges: visual_edges,
          debug: extraction_settings.fetch(:debug, false) == true
        )
        batcher.force('Writing clean JSON')
        result = Writer.write(
          output_path,
          document,
          pretty_print: pretty_print,
          progress: batcher.method(:step)
        ).merge(document: document)
        result[:profile] = profiler.report(document, progress: batcher.method(:step)) if profiler
        batcher.force('Clean export complete')
        result
      end

      def export_visual(model:, roots:, parent_transform:, output_path:, identity_plan: nil, settings: {},
                        progress: nil, batch_size: 24, profile: false)
        root_items = Array(roots)
        batcher = ProgressBatcher.new(progress, batch_size)
        batcher.force('Preparing clean visual export')
        plan = identity_plan || SemanticV2::IdentityCoordinator.plan(
          model: model,
          roots: root_items,
          progress: batcher.method(:step),
          prepare_model_writes: false,
          deterministic_virtual_identities: true
        )
        extraction_settings = {
          include_hidden: false,
          extraction_policy_id: EXTRACTION_POLICY_ID
        }.merge(settings || {})
        snapshot = SemanticV2::Extractor.extract(
          model: model,
          roots: root_items,
          parent_transform: parent_transform,
          identity_plan: plan,
          settings: extraction_settings,
          progress: batcher.method(:step)
        )
        visual_edges = VisualEdgeExtractor.extract(
          roots: root_items,
          identity_plan: plan,
          snapshot: snapshot,
          include_hidden: extraction_settings.fetch(:include_hidden, false),
          progress: batcher.method(:step)
        )
        textures = TextureExtractor.extract(
          model: model,
          roots: root_items,
          identity_plan: plan,
          snapshot: snapshot,
          include_hidden: extraction_settings.fetch(:include_hidden, false),
          progress: batcher.method(:step)
        )
        batcher.force('Compiling textured architectural surfaces')
        profiler = profile ? Profiler.new(snapshot) : nil
        document = Compiler.compile(
          snapshot,
          progress: batcher.method(:step),
          profiler: profiler,
          visual_edges: visual_edges,
          debug: extraction_settings.fetch(:debug, false) == true,
          texture_data: textures
        )
        batcher.force('Writing clean visual package')
        result = VisualPackage.write(
          output_path,
          document,
          textures.assets,
          progress: batcher.method(:step)
        )
        result[:profile] = profiler.report(document, progress: batcher.method(:step)) if profiler
        batcher.force('Clean visual export complete')
        result
      end
    end
  end
end
