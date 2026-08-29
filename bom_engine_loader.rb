# bom_engine_loader.rb
# Entry point for BOM Engine SketchUp Plugin
# Auto-loaded by SketchUp from the Plugins directory.

require 'sketchup'
require 'extensions'
require File.join(__dir__, 'bom_engine', 'branding')

module BOMEngine
  PLUGIN_VERSION = Branding::EXTENSION_VERSION
  PLUGIN_DISPLAY_NAME = Branding::EXTENSION_NAME
  PLUGIN_PATH    = File.dirname(__FILE__)

  # Register as SketchUp Extension (enables/disables via Preferences > Extensions)
  extension = SketchupExtension.new(
    PLUGIN_DISPLAY_NAME,
    File.join(PLUGIN_PATH, "bom_engine", "core.rb")
  )
  extension.description = Branding::DESCRIPTION
  extension.version     = PLUGIN_VERSION
  extension.creator     = "Sibambo Research Team"
  extension.copyright   = "© 2026 Sibambo"

  Sketchup.register_extension(extension, true)
end
