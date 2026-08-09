# frozen_string_literal: true

require 'json'
require 'minitest/autorun'

SEMANTIC_V2_LOAD_ERROR = begin
  require_relative '../semantic_v2'
  nil
rescue LoadError => error
  error
end

class SemanticV2CanonicalJSONTest < Minitest::Test
  FIXTURE_PATH = File.expand_path('fixtures/sha256-jcs-v1.json', __dir__)

  def setup
    assert_nil SEMANTIC_V2_LOAD_ERROR,
               "Semantic v2 namespace must load: #{SEMANTIC_V2_LOAD_ERROR&.message}"
  end

  def test_every_shared_jcs_vector_matches_canonical_bytes_and_digest
    fixture = JSON.parse(File.read(FIXTURE_PATH, encoding: 'UTF-8'))

    fixture.fetch('vectors').each do |vector|
      actual = BOMEngine::SemanticV2::CanonicalJSON.generate(vector.fetch('input'))
      assert_equal Encoding::UTF_8, actual.encoding, vector.fetch('name')
      assert_equal vector.fetch('canonical'), actual, vector.fetch('name')
      assert_equal vector.fetch('sha256'),
                   BOMEngine::SemanticV2::CanonicalJSON.sha256(vector.fetch('input')),
                   vector.fetch('name')
    end
  end

  def test_accepts_symbol_object_keys_but_detects_duplicate_json_names
    assert_equal '{"a":1,"b":2}',
                 BOMEngine::SemanticV2::CanonicalJSON.generate({ b: 2, a: 1 })

    error = assert_raises(ArgumentError) do
      BOMEngine::SemanticV2::CanonicalJSON.generate({ a: 1, 'a' => 2 })
    end
    assert_match(/duplicate object key/, error.message)
  end

  def test_rejects_non_finite_numbers_and_invalid_unicode
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |number|
      assert_raises(ArgumentError) do
        BOMEngine::SemanticV2::CanonicalJSON.generate(number)
      end
    end

    invalid_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    assert_raises(ArgumentError) do
      BOMEngine::SemanticV2::CanonicalJSON.generate(invalid_utf8)
    end
  end
end

class SemanticV2IdentityRegistryTest < Minitest::Test
  MODEL_ID = '10000000-0000-4000-8000-000000000001'
  SOURCE_ID = '20000000-0000-4000-8000-000000000002'
  SEMANTIC_ID = '30000000-0000-4000-8000-000000000003'
  GENERATION_ID = '40000000-0000-4000-8000-000000000004'

  def setup
    assert_nil SEMANTIC_V2_LOAD_ERROR,
               "Semantic v2 namespace must load: #{SEMANTIC_V2_LOAD_ERROR&.message}"
  end

  def test_load_preserves_model_revision_prepared_generation_and_is_clean
    raw = JSON.generate(
      'model_id' => MODEL_ID,
      'revision' => 7,
      'prepared_generation' => {
        'generation_uuid' => GENERATION_ID,
        'revision' => 7
      },
      'source_claims' => {},
      'semantic_lineage' => {}
    )

    registry = registry_from(raw)

    refute registry.changed?
    assert_equal 7, registry.next_revision
    assert_equal JSON.parse(raw), registry.to_h
  end

  def test_load_preserves_a_prepared_generation_uuid
    raw = JSON.generate(
      'model_id' => MODEL_ID,
      'revision' => 7,
      'prepared_generation' => GENERATION_ID,
      'source_claims' => {},
      'semantic_lineage' => {}
    )

    registry = begin
      registry_from(raw)
    rescue ArgumentError => error
      error
    end

    refute_kind_of ArgumentError, registry
    refute registry.changed?
    assert_equal GENERATION_ID, registry.to_h.fetch('prepared_generation')
  end

  def test_new_registry_allocates_model_and_namespaced_entity_ids
    generated = [MODEL_ID, SOURCE_ID, SOURCE_ID]
    registry = registry_from(nil, generated)

    claim = registry.plan_source_claim(
      source_uuid: SOURCE_ID,
      owner_pid: 42,
      origin_model_id: MODEL_ID
    )
    semantic = registry.resolve_semantic(
      type: 'Wall',
      exact_key: 'wall-lineage-key',
      candidates: []
    )

    assert_equal SOURCE_ID, claim.source_uuid
    assert_equal SOURCE_ID, semantic.semantic_uuid
    assert_equal 'new_identity', semantic.outcome
    assert_equal SOURCE_ID, registry.to_h.dig('source_claims', SOURCE_ID, 'source_uuid')
    assert_equal SOURCE_ID,
                 registry.to_h.dig('semantic_lineage', 'Wall', 'wall-lineage-key', 'semantic_uuid')
    assert_equal 1, registry.next_revision
    assert registry.changed?
  end

  def test_idempotent_plans_do_not_advance_revision_more_than_once
    registry = registry_from(nil, [MODEL_ID])
    registry.plan_source_claim(
      source_uuid: SOURCE_ID,
      owner_pid: 9,
      origin_model_id: MODEL_ID
    )
    first_revision = registry.next_revision

    registry.plan_source_claim(
      source_uuid: SOURCE_ID,
      owner_pid: 9,
      origin_model_id: MODEL_ID
    )

    assert_equal 1, first_revision
    assert_equal first_revision, registry.next_revision
    assert_equal first_revision, registry.to_h.fetch('revision')
  end

  def test_registry_owner_wins_source_collision
    registry = registry_from(nil, [MODEL_ID])
    registry.plan_source_claim(
      source_uuid: SOURCE_ID,
      owner_pid: 44,
      origin_model_id: MODEL_ID
    )

    winner = registry.resolve_source_collision(
      source_uuid: SOURCE_ID,
      claims: [{ owner_pid: 12 }, { owner_pid: 44 }]
    )

    assert_equal 44, winner.owner_pid
    assert_empty winner.diagnostics
  end

  def test_lowest_persistent_id_wins_when_registry_has_no_owner
    registry = registry_from(nil, [MODEL_ID])

    winner = registry.resolve_source_collision(
      source_uuid: SOURCE_ID,
      claims: [{ owner_pid: 44 }, { owner_pid: 12 }]
    )

    assert_equal 12, winner.owner_pid
    assert_includes winner.diagnostics, 'identity.collision_without_registry_owner'
  end

  def test_exact_semantic_lineage_reuses_registry_identity_without_change
    raw = JSON.generate(
      'model_id' => MODEL_ID,
      'revision' => 3,
      'prepared_generation' => nil,
      'source_claims' => {},
      'semantic_lineage' => {
        'Wall' => {
          'wall-lineage-key' => {
            'semantic_uuid' => SEMANTIC_ID,
            'type' => 'Wall',
            'exact_key' => 'wall-lineage-key'
          }
        }
      }
    )
    registry = registry_from(raw, [])

    resolution = registry.resolve_semantic(
      type: 'Wall',
      exact_key: 'wall-lineage-key',
      candidates: [{ semantic_uuid: '50000000-0000-4000-8000-000000000005' }]
    )

    assert_equal SEMANTIC_ID, resolution.semantic_uuid
    assert_equal 'exact_lineage_match', resolution.outcome
    refute registry.changed?
    assert_equal 3, registry.next_revision
  end

  def test_returned_source_claim_cannot_mutate_registry_state
    raw = JSON.generate(
      'model_id' => MODEL_ID,
      'revision' => 7,
      'prepared_generation' => nil,
      'source_claims' => {
        SOURCE_ID => {
          'source_uuid' => SOURCE_ID,
          'owner_pid' => 42,
          'origin_model_id' => MODEL_ID
        }
      },
      'semantic_lineage' => {}
    )
    registry = registry_from(raw, [])
    claim = registry.plan_source_claim(
      source_uuid: SOURCE_ID,
      owner_pid: 42,
      origin_model_id: MODEL_ID
    )
    persisted = registry.to_h

    claim.source_uuid.replace(SEMANTIC_ID) unless claim.source_uuid.frozen?
    claim.origin_model_id.replace(GENERATION_ID) unless claim.origin_model_id.frozen?

    assert_equal persisted, registry.to_h
    refute registry.changed?
    assert_equal 7, registry.next_revision
  end

  def test_returned_semantic_resolution_cannot_mutate_registry_state
    raw = JSON.generate(
      'model_id' => MODEL_ID,
      'revision' => 7,
      'prepared_generation' => nil,
      'source_claims' => {},
      'semantic_lineage' => {
        'Wall' => {
          'wall-lineage-key' => {
            'semantic_uuid' => SEMANTIC_ID,
            'type' => 'Wall',
            'exact_key' => 'wall-lineage-key'
          }
        }
      }
    )
    registry = registry_from(raw, [])
    resolution = registry.resolve_semantic(
      type: 'Wall',
      exact_key: 'wall-lineage-key',
      candidates: []
    )
    persisted = registry.to_h

    resolution.semantic_uuid.replace(SOURCE_ID) unless resolution.semantic_uuid.frozen?

    assert_equal persisted, registry.to_h
    refute registry.changed?
    assert_equal 7, registry.next_revision
  end

  def test_caller_owned_semantic_strings_cannot_mutate_registry_state
    type = String.new('Wall')
    exact_key = String.new('wall-lineage-key')
    registry = registry_from(nil, [MODEL_ID, SEMANTIC_ID])
    registry.resolve_semantic(type: type, exact_key: exact_key, candidates: [])
    persisted = registry.to_h

    type.replace('Door')
    exact_key.replace('mutated-lineage-key')

    assert_equal persisted, registry.to_h
  end

  def test_rejects_invalid_uuids_in_loaded_and_planned_state
    assert_raises(ArgumentError) do
      registry_from(JSON.generate('model_id' => 'not-a-uuid', 'revision' => 0))
    end

    registry = registry_from(nil, [MODEL_ID])
    assert_raises(ArgumentError) do
      registry.plan_source_claim(
        source_uuid: 'bad',
        owner_pid: 1,
        origin_model_id: MODEL_ID
      )
    end
  end

  private

  def registry_from(raw, generated = [])
    generator = lambda do
      raise 'unexpected UUID allocation' if generated.empty?

      generated.shift
    end
    BOMEngine::SemanticV2::IdentityRegistry.load(raw, uuid_generator: generator)
  end
end
