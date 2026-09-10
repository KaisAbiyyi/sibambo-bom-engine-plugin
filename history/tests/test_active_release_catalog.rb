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

    # Baseline 8082541 has been demoted to uncertified due to incomplete real-runtime evidence
    baseline = records.find { |r| r['id'] == 'baseline-8082541' }
    assert_not_nil baseline
    assert_equal 'uncertified', baseline['state']

    # 0 ready packages in production active catalog until completed in R8
    packages = EvolutionActiveCatalog.packagable(records)
    assert_equal [], packages

    # Buildable candidates (releases with producerSha) can still be built
    buildable = EvolutionActiveCatalog.buildable(records)
    assert_equal 4, buildable.length
    assert_equal ['scene-resilient-a158b75', 'scene-fidelity-a138fe6', 'baseline-8082541', 'next-from-8082541'], buildable.map { |r| r['id'] }
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

  def test_rejects_ready_state_without_certification_id
    manifest_path = File.join(@temp_dir, 'ready_no_cert.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[0]['state'] = 'ready'
    records[0]['certificationId'] = nil
    File.write(manifest_path, JSON.generate(records))

    assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
  end

  def test_rejects_declarative_ready_without_certification_artifact
    manifest_path = File.join(@temp_dir, 'ready_missing_artifact.json')
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[2]['state'] = 'ready'
    records[2]['certificationId'] = 'forged-nonexistent-cert'
    File.write(manifest_path, JSON.generate(records))

    err = assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
    assert_match(/no certification artifact could be resolved/, err.message)
  end

  def test_rejects_ready_with_incomplete_certification
    manifest_path = File.join(@temp_dir, 'ready_incomplete.json')
    cert_path = File.join(@temp_dir, 'cert_incomplete.json')

    incomplete_cert = {
      'schemaVersion' => 't7-evolution-certification-v1',
      'certificationId' => 'test-cert-incomplete',
      'releaseId' => 'baseline-8082541',
      'status' => 'incomplete',
      'ready' => false,
      'tuple' => {
        'producerSha' => '8082541d852cd68b9874231e41c6b9c967c74d26',
        'consumerSha' => 'd49270130502ce676c0ba5a9a7bb13f1e913c1c8',
        'packageSha256' => '9a9fbe162f021c6dfdd7cbfc0cd53946436bae2835d0b18de01f6f327a1060ef'
      }
    }
    File.write(cert_path, JSON.generate(incomplete_cert))

    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[2]['state'] = 'ready'
    records[2]['certificationId'] = 'test-cert-incomplete'
    records[2]['certificationPath'] = cert_path
    File.write(manifest_path, JSON.generate(records))

    err = assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
    assert_match(/ready=false in certification artifact/, err.message)
  end

  def test_rejects_ready_with_provisional_certification
    manifest_path = File.join(@temp_dir, 'ready_provisional.json')
    cert_path = File.join(@temp_dir, 'cert_provisional.json')

    provisional_cert = {
      'schemaVersion' => 't7-evolution-certification-v1',
      'certificationId' => 'test-cert-provisional',
      'releaseId' => 'baseline-8082541',
      'status' => 'ready',
      'ready' => true,
      'provisional' => true,
      'tuple' => {
        'producerSha' => '8082541d852cd68b9874231e41c6b9c967c74d26',
        'consumerSha' => 'd49270130502ce676c0ba5a9a7bb13f1e913c1c8',
        'packageSha256' => '9a9fbe162f021c6dfdd7cbfc0cd53946436bae2835d0b18de01f6f327a1060ef'
      }
    }
    File.write(cert_path, JSON.generate(provisional_cert))

    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[2]['state'] = 'ready'
    records[2]['certificationId'] = 'test-cert-provisional'
    records[2]['certificationPath'] = cert_path
    File.write(manifest_path, JSON.generate(records))

    err = assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
    assert_match(/provisional \(dirty consumer checkout\)/, err.message)
  end

  def test_rejects_ready_with_tuple_mismatch
    manifest_path = File.join(@temp_dir, 'ready_mismatch.json')
    cert_path = File.join(@temp_dir, 'cert_mismatch.json')

    mismatched_cert = {
      'schemaVersion' => 't7-evolution-certification-v1',
      'certificationId' => 'test-cert-mismatch',
      'releaseId' => 'baseline-8082541',
      'status' => 'ready',
      'ready' => true,
      'provisional' => false,
      'tuple' => {
        'producerSha' => '8082541d852cd68b9874231e41c6b9c967c74d26',
        'consumerSha' => '0' * 40, # mismatch
        'packageSha256' => '9a9fbe162f021c6dfdd7cbfc0cd53946436bae2835d0b18de01f6f327a1060ef'
      }
    }
    File.write(cert_path, JSON.generate(mismatched_cert))

    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[2]['state'] = 'ready'
    records[2]['certificationId'] = 'test-cert-mismatch'
    records[2]['certificationPath'] = cert_path
    File.write(manifest_path, JSON.generate(records))

    err = assert_raise(RuntimeError) do
      EvolutionActiveCatalog.load(path: manifest_path)
    end
    assert_match(/consumerSha mismatch/, err.message)
  end

  def test_accepts_ready_with_valid_complete_certification
    manifest_path = File.join(@temp_dir, 'ready_valid.json')
    cert_path = File.join(@temp_dir, 'cert_valid.json')

    valid_cert = {
      'schemaVersion' => 't7-evolution-certification-v1',
      'certificationId' => 'test-cert-valid',
      'releaseId' => 'baseline-8082541',
      'status' => 'ready',
      'ready' => true,
      'provisional' => false,
      'tuple' => {
        'producerSha' => '8082541d852cd68b9874231e41c6b9c967c74d26',
        'consumerSha' => 'd49270130502ce676c0ba5a9a7bb13f1e913c1c8',
        'packageSha256' => '9a9fbe162f021c6dfdd7cbfc0cd53946436bae2835d0b18de01f6f327a1060ef'
      }
    }
    File.write(cert_path, JSON.generate(valid_cert))

    records = EvolutionActiveCatalog.load(path: @catalog_path)
    records[2]['state'] = 'ready'
    records[2]['certificationId'] = 'test-cert-valid'
    records[2]['certificationPath'] = cert_path
    File.write(manifest_path, JSON.generate(records))

    loaded = EvolutionActiveCatalog.load(path: manifest_path)
    assert_equal 1, EvolutionActiveCatalog.packagable(loaded).length
    assert_equal 'baseline-8082541', EvolutionActiveCatalog.packagable(loaded)[0]['id']
  end

  def test_candidate_selection
    records = EvolutionActiveCatalog.load(path: @catalog_path)
    candidate = EvolutionActiveCatalog.find_candidate(records, 'scene-resilient-a158b75')
    assert_not_nil candidate
    assert_equal 'scene-resilient-a158b75', candidate['id']

    e4_cand = EvolutionActiveCatalog.find_candidate(records, 'next-from-8082541')
    assert_not_nil e4_cand
    assert_equal 'next-from-8082541', e4_cand['id']
    assert_equal '7284982b26834f2635a839c6c7a1e687f83dca35', e4_cand['producerSha']

    unbuilt_cand = EvolutionActiveCatalog.find_candidate(records, 'nonexistent-slot')
    assert_nil unbuilt_cand # nonexistent candidate cannot be selected
  end
end
