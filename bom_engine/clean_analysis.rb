# frozen_string_literal: true

require_relative 'semantic_v2/snapshot'
require_relative 'clean_analysis/build_info'
require_relative 'clean_analysis/coverage_ledger'
require_relative 'clean_analysis/completeness_report'
require_relative 'clean_analysis/surface_validator'
require_relative 'clean_analysis/progress_batcher'
require_relative 'clean_analysis/visual_edge_extractor'
require_relative 'clean_analysis/batch_options'
require_relative 'clean_analysis/conversion_job'
require_relative 'clean_analysis/compiler'
require_relative 'clean_analysis/writer'
require_relative 'clean_analysis/profiler'
require_relative 'clean_analysis/exporter'
require_relative 'clean_analysis/sketchup_extension'

module BOMEngine
  module CleanAnalysis
    module_function

    def compile(snapshot_document, progress: nil, visual_edges: [], debug: false)
      Compiler.compile(
        snapshot_document,
        progress: progress,
        visual_edges: visual_edges,
        debug: debug
      )
    end
  end
end
