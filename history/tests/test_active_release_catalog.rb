# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'tmpdir'
require_relative '../../tools/history/active_release_catalog'

class TestActiveReleaseCatalog < Test::Unit::TestCase
  def setup
    @root = File.expand_path('../..', __dir__)
    @catalog_path = File.join(@root, 'history', 'active-releases.json')
    @temp_dir = Dir.mktmpdir('active_catalog_test')
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.directory?(@temp_dir)
  end

  def test_active_releases_json_contract_selection
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    assert_equal 4, records.length
    assert_equal 4, records.map { |r| r.fetch('id') }.uniq.length

    next_release = records.find { |r| r.fetch('order') == 4 }
    assert_not_nil next_release
    assert_equal '8082541d852cd68b9874231e41c6b9c967c74d26', next_release.fetch('baseProducerSha')

    packages = EvolutionActiveCatalog.packagable(records)
    assert_false packages.any? { |r| r['producerSha'].nil? }
    assert_equal ['baseline-8082541'], packages.map { |r| r['id'] }
  end

  def test_rejects_non_four_slots
    manifest_path = File.join(@temp_dir, 'fewer_slots.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path).take(3)
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_rejects_duplicate_release_ids
    manifest_path = File.join(@temp_dir, 'dup_ids.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[1]['id'] = records[0]['id']
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_rejects_duplicate_order
    manifest_path = File.join(@temp_dir, 'dup_order.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[1]['order'] = records[0]['order']
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_rejects_wrong_e4_ancestry
    manifest_path = File.join(@temp_dir, 'wrong_ancestry.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[3]['baseProducerSha'] = '0' * 40
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_rejects_invalid_sha_format
    manifest_path = File.join(@temp_dir, 'bad_sha.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[0]['baseProducerSha'] = 'invalid_not_hex'
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_rejects_unknown_entry_kind
    manifest_path = File.join(@temp_dir, 'bad_kind.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[0]['entryKind'] = 'arbitrary-unsupported-kind'
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_rejects_ready_state_without_certification
    manifest_path = File.join(@temp_dir, 'ready_no_cert.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    # Turn slot 1 into ready without certification
    records[0]['state'] = 'ready'
    records[0]['certificationId'] = nil
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_candidate_selection
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    candidate = EvolutionActiveCatalog.find_candidate(records, 'scene-resilient-a158b75')
    assert_not_nil candidate
    assert_equal 'scene-resilient-a158b75', candidate['id']

    unbuilt_cand = EvolutionActiveCatalog.find_candidate(records, 'next-from-8082541')
    assert_nil unbuilt_cand # unbuilt candidate with nil producerSha cannot be selected
  end
end
