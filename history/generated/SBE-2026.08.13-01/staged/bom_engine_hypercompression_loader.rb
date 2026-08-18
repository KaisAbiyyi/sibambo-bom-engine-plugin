# Entry point for the BOM Engine Hypercompression RC extension.

require 'sketchup'
require 'extensions'

module SibamboHistory
  module V20260813_01
  PLUGIN_VERSION = '3.2.0-rc.1'.freeze unless const_defined?(:PLUGIN_VERSION)
  PLUGIN_DISPLAY_NAME = 'BOM Engine Hypercompression RC'.freeze unless const_defined?(:PLUGIN_DISPLAY_NAME)
  PLUGIN_PATH = File.dirname(__FILE__) unless const_defined?(:PLUGIN_PATH)

  extension = SketchupExtension.new(
    PLUGIN_DISPLAY_NAME,
    File.join(PLUGIN_PATH, 'bom_engine', 'bomc_extension.rb')
  )
  extension.description = 'BOMC 1.0 compiled exporter with legacy Canonical JSON, BOME2, and Model-Eval JSON compatibility.'
  extension.version = PLUGIN_VERSION
  extension.creator = 'Sibambo Research Team'
  extension.copyright = 'Copyright 2026 Sibambo'

  Sketchup.register_extension(extension, true)
end

end # SibamboHistory
