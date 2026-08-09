# frozen_string_literal: true

require_relative 'semantic_v2/snapshot'
require_relative 'clean_analysis/surface_validator'
require_relative 'clean_analysis/compiler'
require_relative 'clean_analysis/writer'
require_relative 'clean_analysis/exporter'
require_relative 'clean_analysis/sketchup_extension'

module BOMEngine
  module CleanAnalysis
    module_function

    def compile(snapshot_document)
      Compiler.compile(snapshot_document)
    end
  end
end
