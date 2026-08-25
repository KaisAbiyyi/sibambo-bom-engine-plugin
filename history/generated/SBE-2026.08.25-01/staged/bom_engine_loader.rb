# bom_engine_loader.rb
# Entry point for BOM Engine SketchUp Plugin
# Auto-loaded by SketchUp from the Plugins directory.

require 'sketchup'
require 'extensions'

module SibamboHistory
  module V20260825_01
  PLUGIN_VERSION = "3.1.0"
  PLUGIN_DISPLAY_NAME = "BOM Engine Semantic Exporter"
  PLUGIN_PATH    = File.dirname(__FILE__)

  # Register as SketchUp Extension (enables/disables via Preferences > Extensions)
  extension = SketchupExtension.new(
    PLUGIN_DISPLAY_NAME,
    File.join(PLUGIN_PATH, "bom_engine", "core.rb")
  )
  extension.description = "Label-aware SketchUp exporter for canonical JSON and Model-Eval JSON v1.1."
  extension.version     = PLUGIN_VERSION
  extension.creator     = "Sibambo Research Team"
  extension.copyright   = "© 2026 Sibambo"

  Sketchup.register_extension(extension, true)
end

end # SibamboHistory
