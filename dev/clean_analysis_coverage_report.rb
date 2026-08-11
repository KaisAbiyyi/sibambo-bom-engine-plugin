# frozen_string_literal: true

require 'json'
require_relative '../bom_engine/clean_analysis'

path = ARGV.first.to_s
abort('Usage: ruby dev/clean_analysis_coverage_report.rb CLEANV1.json') if path.empty?

document = JSON.parse(File.binread(File.expand_path(path)))
report = BOMEngine::CleanAnalysis::CompletenessReport.generate(document)
puts JSON.pretty_generate(report)
