# Entry point for the BOM Engine Hypercompression RC extension.

require 'sketchup'
require 'extensions'

module SibamboHistory
  module V20260825_01
  PLUGIN_VERSION = '3.3.0-rc.1'.freeze unless const_defined?(:PLUGIN_VERSION)
  PLUGIN_DISPLAY_NAME = 'BOM Engine Cooperative BOMC RC'.freeze unless const_defined?(:PLUGIN_DISPLAY_NAME)
  PLUGIN_PATH = File.dirname(__FILE__) unless const_defined?(:PLUGIN_PATH)

  extension = SketchupExtension.new(
    PLUGIN_DISPLAY_NAME,
    File.join(PLUGIN_PATH, 'bom_engine', 'bomc_extension.rb')
  )
  extension.description = 'Cooperative BOMC 1.1 exporter with a strict saved-SKP size gate and legacy export compatibility.'
  extension.version = PLUGIN_VERSION
  extension.creator = 'Sibambo Research Team'
  extension.copyright = 'Copyright 2026 Sibambo'

  Sketchup.register_extension(extension, true)
end

end # SibamboHistory
