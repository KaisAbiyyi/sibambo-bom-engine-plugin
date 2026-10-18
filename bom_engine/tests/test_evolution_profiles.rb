# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'zlib'
require 'base64'
require_relative '../evolution_document'
require_relative '../evolution_tree_writer'
require_relative '../evolution_canonical_writer'
require_relative '../evolution_cleanpkg_writer'
require_relative '../evolution_validator'
require_relative '../canonical_json_writer'
require_relative '../performance_trace'
require_relative 'support/evolution_fixture'

class TestEvolutionProfiles < Test::Unit::TestCase
  BASELINES = { e1: 'a' * 40, e2: 'b' * 40, e3: 'c' * 40 }.freeze

  def with_document(engine, profile)
    Dir.mktmpdir('evolution-profile') do |dir|
      texture = File.join(dir, 'fixture.png')
      File.binwrite(texture, "\x89PNG\r\nfixture-displayed-alpha".b)
      document = BOMEngine::EvolutionDocument.prepare(
        EvolutionFixture.graph(texture_path: texture), engine: engine, profile: profile,
        source_tree_sha256: 'd' * 64, historical_baseline_sha: BASELINES.fetch(engine)
      )
      yield dir, document
    end
  end

  def test_nine_new_writer_profile_combinations_round_trip
    %i[e1 e2 e3].product(%i[visual research exact]).each do |engine, profile|
      with_document(engine, profile) do |dir, document|
        extension = engine == :e1 ? '.json' : engine == :e2 ? '.json.gz' : '.cleanpkg'
        path = File.join(dir, "fixture#{extension}")
        writer(engine).write(path, document)
        report = BOMEngine::EvolutionValidator.validate_file!(path, engine: engine, expected_profile: profile, source_document: document)
        assert_equal true, report[:passed], "#{engine}/#{profile} validates"
        assert_equal 2, report.dig(:comparison, :occurrences), "#{engine}/#{profile} preserves both occurrences"
        assert_equal 2, report.dig(:comparison, :edges), "#{engine}/#{profile} preserves edge occurrences"
        assert_equal 2, report.dig(:comparison, :scenes)
        assert_equal 1, report.dig(:comparison, :clip_planes)
        assert_equal 1, report.dig(:comparison, :assets)
      end
    end
  end

  def test_e1_world_expansion_handles_nonuniform_and_mirrored_occurrences
    with_document(:e1, :exact) do |_dir, document|
      tree = BOMEngine::EvolutionTreeWriter.build(document)
      faces = collect_faces(tree['entities'])
      assert_equal 2, faces.length
      scaled = faces.find { |face| face['instance_path'].include?('node:a') }
      mirrored = faces.find { |face| face['instance_path'].include?('node:b') }
      assert_in_delta 8.0, scaled['area_m2'], 1.0e-12
      assert_in_delta 10.0, mirrored['area_m2'], 1.0e-12
      assert_equal true, mirrored['mirrored']
      assert_equal [0.0, 0.0, 1.0], mirrored['normal']
      assert_equal [0.0, 1.0], mirrored.dig('uv', 'front_outer', 0)
      assert_equal 1, mirrored['holes'].length
    end
  end

  def test_e3_contract_uses_float64_and_uint32_full_matrices
    with_document(:e3, :exact) do |_dir, document|
      built = BOMEngine::EvolutionCleanPKGWriter.build(document)
      manifest = built.fetch(:manifest)
      descriptors = manifest.dig('buffers', 'sections')
      assert descriptors.any? { |row| row[4] == 'float64' && row[3] == 16 }, 'instance matrices are full 4x4 Float64'
      assert descriptors.none? { |row| row[4] == 'float32' || row[4] == 'uint16' }, 'new CleanPKG does not narrow geometry/material precision'
      assert_equal '1.1.0', manifest.dig('format', 'version')
    end
  end

  def test_performance_trace_covers_detach_writer_and_readback_without_changing_bytes
    Dir.mktmpdir('evolution-performance') do |dir|
      texture = File.join(dir, 'fixture.png')
      File.binwrite(texture, "\x89PNG\r\nfixture-displayed-alpha".b)
      baseline_document = BOMEngine::EvolutionDocument.prepare(
        EvolutionFixture.graph(texture_path: texture), engine: :e2, profile: :visual,
        source_tree_sha256: 'd' * 64, historical_baseline_sha: BASELINES.fetch(:e2)
      )
      baseline_path = File.join(dir, 'baseline.json.gz')
      BOMEngine::EvolutionCanonicalWriter.write(baseline_path, baseline_document)
      baseline_bytes = File.binread(baseline_path)

      trace = BOMEngine::PerformanceTrace.new(enabled: true)
      observed_path = File.join(dir, 'observed.json.gz')
      BOMEngine::PerformanceTrace.with(trace) do
        document = BOMEngine::EvolutionDocument.prepare(
          EvolutionFixture.graph(texture_path: texture), engine: :e2, profile: :visual,
          source_tree_sha256: 'd' * 64, historical_baseline_sha: BASELINES.fetch(:e2)
        )
        BOMEngine::EvolutionCanonicalWriter.write(observed_path, document)
        BOMEngine::EvolutionValidator.validate_file!(observed_path, engine: :e2, expected_profile: :visual, source_document: document)
      end
      receipt = trace.finish(status: :success)
      names = receipt.fetch(:stages).map { |row| row[:name] }
      assert_equal baseline_bytes, File.binread(observed_path), 'Evolution trace does not alter deterministic E2 bytes'
      %w[graph_detach e2_payload e2_serialize evolution_readback evolution_compare artifact_hash].each do |name|
        assert_include names, name, "trace includes #{name}"
      end
    end
  end

  def test_streaming_writers_preserve_legacy_payload_bytes
    %i[e1 e2 e3].each do |engine|
      with_document(engine, :exact) do |dir, document|
        expected = File.join(dir, "expected-#{engine}")
        observed = File.join(dir, "observed-#{engine}")
        case engine
        when :e1
          File.binwrite(expected, JSON.generate(BOMEngine::EvolutionTreeWriter.build(document)))
          result = BOMEngine::EvolutionTreeWriter.write(observed, document)
        when :e2
          BOMEngine::CanonicalJSONWriter.write(expected, BOMEngine::EvolutionCanonicalWriter.build(document), pretty: false, compress: true)
          result = BOMEngine::EvolutionCanonicalWriter.write(observed, document)
        when :e3
          built = BOMEngine::EvolutionCleanPKGWriter.build(document)
          entries = {
            'manifest.json' => JSON.generate(built.fetch(:manifest)),
            'buffers.bin' => built.fetch(:buffers)
          }
          Array(document.fetch('assets')).each { |asset| entries[asset.fetch('path')] = asset.fetch('bytes') }
          BOMEngine::EvolutionCleanPKG::DeterministicZip.write(expected, entries)
          result = BOMEngine::EvolutionCleanPKGWriter.write(observed, document)
        end
        assert_equal File.binread(expected), File.binread(observed), "#{engine} streaming output stays byte deterministic"
        assert_equal File.size(observed), result.fetch(:bytes)
        assert_equal Digest::SHA256.file(observed).hexdigest, result.fetch(:sha256)
      end
    end
  end

  def test_e1_streaming_readback_detects_mutation_truncation_and_trailing_bytes
    with_document(:e1, :exact) do |dir, document|
      path = File.join(dir, 'stream-readback.json')
      BOMEngine::EvolutionTreeWriter.write(path, document)
      expected = File.binread(path)
      assert_equal expected.bytesize, BOMEngine::EvolutionTreeWriter.verify_stream!(path, document)
      proof = BOMEngine::EvolutionValidator.verify_large_e1!(path, document)
      assert_equal 'world-expanded-byte-exact-stream', proof.fetch(:mode)
      assert_equal 2, proof.fetch(:occurrences)

      File.open(path, 'r+b') { |file| file.seek(1); file.write('x') }
      assert_raise(BOMEngine::EvolutionValidator::ValidationError) do
        BOMEngine::EvolutionValidator.verify_large_e1!(path, document)
      end

      File.binwrite(path, expected.byteslice(0, expected.bytesize - 1))
      assert_raise(BOMEngine::EvolutionValidator::ValidationError) do
        BOMEngine::EvolutionValidator.verify_large_e1!(path, document)
      end

      File.binwrite(path, expected + 'junk')
      assert_raise(BOMEngine::EvolutionValidator::ValidationError) do
        BOMEngine::EvolutionValidator.verify_large_e1!(path, document)
      end
    end
  end

  def test_compact_e2_e3_validation_never_builds_world_e1_tree
    original = BOMEngine::EvolutionTreeWriter.method(:build)
    BOMEngine::EvolutionTreeWriter.define_singleton_method(:build) do |_document|
      raise 'E1 world expansion must not run for compact validation'
    end
    %i[e2 e3].each do |engine|
      with_document(engine, :research) do |dir, document|
        extension = engine == :e2 ? '.json.gz' : '.cleanpkg'
        path = File.join(dir, "compact#{extension}")
        result = writer(engine).write(path, document)
        report = BOMEngine::EvolutionValidator.validate_file!(
          path, engine: engine, expected_profile: :research, source_document: document,
          artifact_sha256: result.fetch(:sha256)
        )
        assert_equal 'compact-definition-occurrence', report.dig(:comparison, :mode)
        assert_equal result.fetch(:sha256), report.fetch(:sha256)
      end
    end
  ensure
    BOMEngine::EvolutionTreeWriter.define_singleton_method(:build) { |document| original.call(document) } if original
  end

  def test_e2_artifact_corruption_is_detected_across_compact_contract
    with_document(:e2, :research) do |dir, document|
      valid = File.join(dir, 'valid.json.gz')
      BOMEngine::EvolutionCanonicalWriter.write(valid, document)
      baseline_json = Zlib::GzipReader.open(valid) { |gzip| gzip.read }
      baseline = JSON.parse(baseline_json)
      mutations = {
        geometry: ->(graph) { graph['meshes'][0]['positions_m'][0] += 0.125 },
        transform: ->(graph) { graph['transforms'][1][12] += 1.0 },
        material_ref: ->(graph) { graph['meshes'][0]['faces'][0]['front_material_id'] = 'material:corrupt' },
        uv: ->(graph) { graph['meshes'][0]['faces'][0]['uv']['front_outer'][0][0] += 0.25 },
        scene: ->(graph) { graph['scenes'][0]['visibility_signature'] = 'corrupt-scene' },
        clip: ->(graph) { graph['clip_planes'][0]['plane_constant'] -= 2.0 },
        asset_bytes: lambda do |graph|
          raw = Base64.strict_decode64(graph['assets'][0]['data_base64'])
          graph['assets'][0]['data_base64'] = Base64.strict_encode64(raw + 'x')
        end,
        asset_hash: ->(graph) { graph['assets'][0]['sha256'] = '0' * 64 }
      }
      mutations.each do |label, mutate|
        graph = JSON.parse(JSON.generate(baseline))
        mutate.call(graph)
        corrupt = File.join(dir, "corrupt-#{label}.json.gz")
        write_gzip_json(corrupt, JSON.generate(graph))
        assert_raise(BOMEngine::EvolutionValidator::ValidationError, "#{label} corruption must fail") do
          BOMEngine::EvolutionValidator.validate_file!(corrupt, engine: :e2, expected_profile: :research, source_document: document)
        end
      end
      truncated = File.join(dir, 'truncated.json.gz')
      write_gzip_json(truncated, baseline_json.byteslice(0, baseline_json.bytesize - 13))
      assert_raise(BOMEngine::EvolutionValidator::ValidationError) do
        BOMEngine::EvolutionValidator.validate_file!(truncated, engine: :e2, expected_profile: :research, source_document: document)
      end
    end
  end

  private

  def writer(engine)
    case engine
    when :e1 then BOMEngine::EvolutionTreeWriter
    when :e2 then BOMEngine::EvolutionCanonicalWriter
    when :e3 then BOMEngine::EvolutionCleanPKGWriter
    end
  end

  def collect_faces(entities, result = [])
    Array(entities).each do |entity|
      if entity['type'] == 'Face'
        result << entity
      else
        collect_faces(entity['children'], result)
      end
    end
    result
  end

  def write_gzip_json(path, payload)
    Zlib::GzipWriter.open(path) do |gzip|
      gzip.mtime = 0
      gzip.write(payload)
    end
  end
end
