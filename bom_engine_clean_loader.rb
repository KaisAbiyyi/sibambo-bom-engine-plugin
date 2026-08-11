# frozen_string_literal: true

require 'sketchup'
require 'extensions'

module BOMEngineCleanLoader
  extension = SketchupExtension.new(
    'BOM Engine Clean Analysis (Experimental)',
    File.join(File.dirname(__FILE__), 'bom_engine_clean', 'clean_analysis', 'sketchup_entry.rb')
  )
  extension.description = 'Compact polygon-first architectural analysis JSON exporter.'
  extension.version = '1.0.0'
  extension.creator = 'Sibambo Research Team'
  Sketchup.register_extension(extension, true)
end
