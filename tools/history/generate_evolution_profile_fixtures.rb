# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative '../../bom_engine/evolution_exporter'
require_relative '../../bom_engine/evolution_document'
require_relative '../../bom_engine/evolution_tree_writer'
require_relative '../../bom_engine/evolution_canonical_writer'
require_relative '../../bom_engine/evolution_cleanpkg_writer'
require_relative '../../bom_engine/evolution_validator'
require_relative '../../bom_engine/tests/support/evolution_fixture'

module EvolutionProfileFixtureGenerator
  BASELINES = BOMEngine::EvolutionExporter::HISTORICAL_BASELINES
  WRITERS = {
    e1: [BOMEngine::EvolutionTreeWriter, '.json'],
    e2: [BOMEngine::EvolutionCanonicalWriter, '.json.gz'],
    e3: [BOMEngine::EvolutionCleanPKGWriter, '.cleanpkg']
  }.freeze
  PROFILES = %i[visual research exact].freeze

  module_function

  def generate(output:)
    output = File.expand_path(output)
    raise ArgumentError, 'Fixture output already exists; use a new directory.' if File.exist?(output)
    FileUtils.mkdir_p(output)
    source_tree = BOMEngine::EvolutionExporter.source_tree_sha256
    rows = []
    texture = File.join(output, '.fixture-texture.png')
    File.binwrite(texture, fixture_png)

    WRITERS.each do |engine, (writer, extension)|
      PROFILES.each do |profile|
        document = BOMEngine::EvolutionDocument.prepare(
          EvolutionFixture.graph(texture_path: texture),
          engine: engine,
          profile: profile,
          source_tree_sha256: source_tree,
          historical_baseline_sha: BASELINES.fetch(engine)
        )
        filename = "ruby-#{engine}-#{profile}#{extension}"
        path = File.join(output, filename)
        writer.write(path, document)
        validation = BOMEngine::EvolutionValidator.validate_file!(
          path, engine: engine, expected_profile: profile, source_document: document
        )
        rows << {
          'engine' => engine.to_s,
          'profile' => profile.to_s,
          'file' => filename,
          'bytes' => File.size(path),
          'sha256' => Digest::SHA256.file(path).hexdigest,
          'sourceTreeSha256' => source_tree,
          'occurrences' => validation.dig(:comparison, :occurrences),
          'assets' => validation.dig(:comparison, :assets),
          'scenes' => validation.dig(:comparison, :scenes),
          'clipPlanes' => validation.dig(:comparison, :clip_planes)
        }
      end
    end
    File.delete(texture) if File.file?(texture)
    manifest = {
      'schemaVersion' => 'sibambo-evolution-ruby-fixtures-v1',
      'sourceTreeSha256' => source_tree,
      'generatedBy' => 'tools/history/generate_evolution_profile_fixtures.rb',
      'synthetic' => true,
      'rows' => rows
    }
    File.write(File.join(output, 'manifest.json'), JSON.pretty_generate(manifest) + "\n", encoding: 'UTF-8')
    manifest
  ensure
    File.delete(texture) if defined?(texture) && texture && File.file?(texture)
  end

  def fixture_png
    # Tiny valid PNG; image bytes only need to exercise portable asset transport.
    require 'base64'
    Base64.strict_decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
  end
  private_class_method :fixture_png
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new { |parser| parser.on('--output PATH') { |path| options[:output] = path } }.parse!
  raise ArgumentError, 'Pass --output with a new directory' unless options[:output]
  puts JSON.pretty_generate(EvolutionProfileFixtureGenerator.generate(output: options.fetch(:output)))
end
