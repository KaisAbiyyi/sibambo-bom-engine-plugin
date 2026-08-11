# frozen_string_literal: true

require 'sketchup'
require 'extensions'

module BOMEngineCleanDevLoader
  root = ENV.fetch('BOM_ENGINE_CLEAN_DEV_ROOT')
  entry = File.join(root, 'bom_engine', 'clean_analysis', 'sketchup_entry.rb')
  raise "CleanV1 development entry is missing: #{entry}" unless File.file?(entry)

  extension = SketchupExtension.new(
    'BOM Engine Clean Analysis (Development)',
    entry
  )
  extension.description = "CleanV1 development source: #{root}"
  extension.version = '1.0.0-dev'
  extension.creator = 'Sibambo Research Team'
  Sketchup.register_extension(extension, true)
end
