# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'json'
require_relative '../evolution_document'
require_relative '../evolution_cleanpkg_writer'
require_relative '../evolution_validator'
require_relative '../evolution_cleanpkg/deterministic_zip'
require_relative '../evolution_cleanpkg/section_writer'
require_relative 'support/evolution_fixture'

class TestEvolutionCleanPKG < Test::Unit::TestCase
  def document
    BOMEngine::EvolutionDocument.prepare(
      EvolutionFixture.graph,
      engine: :e3,
      profile: :exact,
      source_tree_sha256: 'e' * 64,
      historical_baseline_sha: 'f' * 40
    )
  end

  def test_uint32_and_float64_boundaries_are_not_narrowed
    writer = BOMEngine::EvolutionCleanPKG::SectionWriter.new
    writer.add('large-index', [70_000, 0xffff_ffff], component_type: 'uint32', components: 1)
    writer.add('precision', [1.0000000000003, -123_456.78901234567], component_type: 'float64', components: 1)
    assert_equal [70_000, 0xffff_ffff], writer.bytes.byteslice(0, 8).unpack('L<*')
    precision_offset = writer.sections.fetch('precision').fetch('byte_offset')
    precision = writer.bytes.byteslice(precision_offset, 16).unpack('E*')
    assert_equal 1.0000000000003, precision[0]
    assert_equal(-123_456.78901234567, precision[1])
  end

  def test_wrong_version_is_rejected
    Dir.mktmpdir do |dir|
      built = BOMEngine::EvolutionCleanPKGWriter.build(document)
      manifest = built.fetch(:manifest)
      manifest['format']['version'] = '9.9.9'
      path = File.join(dir, 'wrong.cleanpkg')
      BOMEngine::EvolutionCleanPKG::DeterministicZip.write(path, { 'manifest.json' => JSON.generate(manifest), 'buffers.bin' => built.fetch(:buffers) })
      assert_raise(BOMEngine::EvolutionValidator::ValidationError) { BOMEngine::EvolutionValidator.read(path, engine: :e3) }
    end
  end

  def test_truncated_section_descriptor_is_rejected
    Dir.mktmpdir do |dir|
      built = BOMEngine::EvolutionCleanPKGWriter.build(document)
      manifest = built.fetch(:manifest)
      manifest['buffers']['sections'][0][1] += 8
      path = File.join(dir, 'truncated.cleanpkg')
      BOMEngine::EvolutionCleanPKG::DeterministicZip.write(path, { 'manifest.json' => JSON.generate(manifest), 'buffers.bin' => built.fetch(:buffers) })
      assert_raise(BOMEngine::EvolutionValidator::ValidationError) { BOMEngine::EvolutionValidator.read(path, engine: :e3) }
    end
  end

  def test_full_matrix_and_high_precision_uv_survive_real_file_readback
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'exact.cleanpkg')
      BOMEngine::EvolutionCleanPKGWriter.write(path, document)
      decoded = BOMEngine::EvolutionValidator.read(path, engine: :e3)
      assert_equal 1.0000000000003, decoded.dig(:graph, 'meshes', 0, 'faces', 0, 'uv', 'front_outer', 1, 0)
      assert_equal 16, decoded.dig(:graph, 'transforms', 1).length
      assert_equal(-4.0, decoded.dig(:graph, 'transforms', 2, 12))
    end
  end
end
