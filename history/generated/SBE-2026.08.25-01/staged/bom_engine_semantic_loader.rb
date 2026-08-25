# Entry point for the separately named label-aware SketchUp plugin.

require 'sketchup'
require 'extensions'

module SibamboHistory
  module V20260825_01
  PLUGIN_VERSION = '3.1.0' unless const_defined?(:PLUGIN_VERSION, false)
  PLUGIN_DISPLAY_NAME = 'BOM Engine Semantic Exporter' unless const_defined?(:PLUGIN_DISPLAY_NAME, false)
  PLUGIN_PATH = File.dirname(__FILE__) unless const_defined?(:PLUGIN_PATH, false)

  extension = SketchupExtension.new(
    PLUGIN_DISPLAY_NAME,
    File.join(PLUGIN_PATH, 'bom_engine_semantic', 'core.rb')
  )
  extension.description = 'Label-aware SketchUp exporter for canonical JSON and Model-Eval JSON v1.1.'
  extension.version = PLUGIN_VERSION
  extension.creator = 'Sibambo Research Team'
  extension.copyright = '© 2026 Sibambo'

  Sketchup.register_extension(extension, true)
end

end # SibamboHistory
