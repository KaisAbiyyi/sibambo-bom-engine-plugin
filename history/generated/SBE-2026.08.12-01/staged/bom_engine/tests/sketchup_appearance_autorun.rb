# frozen_string_literal: true

# Copy this file temporarily into SketchUp's Plugins directory and launch a
# fresh SketchUp process with the BOM_ENGINE_APPEARANCE_* environment values.
require 'json'

root = ENV.fetch('BOM_ENGINE_APPEARANCE_ROOT')
require File.join(root, 'bom_engine', 'clean_analysis')
require File.join(root, 'bom_engine', 'tests', 'sketchup_appearance_acceptance')

UI.start_timer(2.0, false) do
  SibamboHistory::V20260812_01::Tests::SketchupAppearanceAcceptance.run(
    fixture_path: ENV.fetch('BOM_ENGINE_APPEARANCE_FIXTURE'),
    output_path: ENV.fetch('BOM_ENGINE_APPEARANCE_OUTPUT'),
    report_path: ENV.fetch('BOM_ENGINE_APPEARANCE_REPORT')
  )
  UI.start_timer(0.5, false) { Sketchup.quit }
end
