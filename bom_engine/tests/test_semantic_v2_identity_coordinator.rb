# frozen_string_literal: true

require 'json'
require 'minitest/autorun'

require_relative '../semantic_v2'
require_relative '../semantic_v2/identity_coordinator'
require_relative 'test_semantic_v2_identity_sketchup'

class SemanticV2IdentityCoordinatorTest < Minitest::Test
  DICTIONARY = 'BOMEngine.SemanticV2'
  MODEL_ID = '10000000-0000-4000-8000-000000000001'
  ORIGINAL_ID = '20000000-0000-4000-8000-000000000002'
  COPY_ID = '30000000-0000-4000-8000-000000000003'
  MISSING_ID = '40000000-0000-4000-8000-000000000004'
  MALFORMED_ID = '50000000-0000-4000-8000-000000000005'
  DEFINITION_ID = '60000000-0000-4000-8000-000000000006'
  SEMANTIC_ID = '70000000-0000-4000-8000-000000000007'
  SECOND_MATERIAL_ID = '80000000-0000-4000-8000-000000000008'

  class FakeAttributeOwner
    attr_reader :writes
    attr_accessor :fail_on_key

    def initialize(attributes = {})
      @attributes = attributes.transform_keys { |key| [key[0], key[1]] }
      @writes = []
    end

    def get_attribute(dictionary, key, default = nil)
      @attributes.fetch([dictionary, key], default)
    end

    def set_attribute(dictionary, key, value)
      raise 'injected write failure' if key == fail_on_key

      @writes << [dictionary, key, value]
      @attributes[[dictionary, key]] = value
    end

    def remove_attribute(dictionary, key)
      @attributes.delete([dictionary, key])
    end
  end

  class FakeEntity < FakeAttributeOwner
    attr_accessor :persistent_id, :entities, :definition, :name, :transformation,
                  :material, :back_material

    def initialize(persistent_id, attributes = {}, entities: nil, definition: nil)
      super(attributes)
      @persistent_id = persistent_id
      @entities = entities
      @definition = definition
      @name = 'mutable name'
      @transformation = 'mutable transform'
    end
  end

  class FakeModel < FakeAttributeOwner
    attr_reader :operation_calls

    def initialize(attributes = {})
      super
      @operation_calls = []
    end

    def start_operation(*arguments)
      @operation_calls << [:start, *arguments]
    end

    def commit_operation
      @operation_calls << [:commit]
    end

    def abort_operation
      @operation_calls << [:abort]
    end
  end

  def test_plan_is_read_only_and_assigns_virtual_ids_only_to_missing_or_malformed_entities
    valid = entity(11, ORIGINAL_ID)
    missing = FakeEntity.new(12)
    malformed = entity(13, 'not-a-uuid', origin_model_id: 'also-invalid')
    model = model_with_registry(claims: { ORIGINAL_ID => claim(ORIGINAL_ID, 11) })

    plan = coordinator.plan(
      model: model,
      roots: [valid, missing, malformed],
      uuid_generator: uuid_generator(MISSING_ID, MALFORMED_ID)
    )

    assert_equal ORIGINAL_ID, plan.source_uuid_for(valid)
    assert_equal MISSING_ID, plan.source_uuid_for(missing)
    assert_equal MALFORMED_ID, plan.source_uuid_for(malformed)
    assert_equal MODEL_ID, plan.model_id
    assert plan.write_required?
    assert_empty model.writes
    assert_empty model.operation_calls
    [valid, missing, malformed].each { |item| assert_empty item.writes }
  end

  def test_registry_owned_original_wins_a_copied_attribute_collision
    original = entity(44, ORIGINAL_ID)
    copied = entity(12, ORIGINAL_ID)
    model = model_with_registry(claims: { ORIGINAL_ID => claim(ORIGINAL_ID, 44) })

    plan = coordinator.plan(
      model: model,
      roots: [copied, original],
      uuid_generator: uuid_generator(COPY_ID)
    )

    assert_equal ORIGINAL_ID, plan.source_uuid_for(original)
    assert_equal COPY_ID, plan.source_uuid_for(copied)
    assert_empty plan.diagnostics
  end

  def test_lowest_persistent_id_wins_an_unowned_collision_and_reports_it
    higher = entity(44, ORIGINAL_ID)
    lower = entity(12, ORIGINAL_ID)
    model = model_with_registry

    plan = coordinator.plan(
      model: model,
      roots: [higher, lower],
      uuid_generator: uuid_generator(COPY_ID)
    )

    assert_equal ORIGINAL_ID, plan.source_uuid_for(lower)
    assert_equal COPY_ID, plan.source_uuid_for(higher)
    assert_includes plan.diagnostics, 'identity.collision_without_registry_owner'
  end

  def test_recursive_scan_assigns_definition_owned_identity_and_occurrence_token
    definition_face = FakeEntity.new(23)
    definition = FakeEntity.new(22, {}, entities: [definition_face])
    instance = FakeEntity.new(21, {}, definition: definition)
    model = model_with_registry

    plan = coordinator.plan(
      model: model,
      roots: [instance],
      uuid_generator: uuid_generator(ORIGINAL_ID, DEFINITION_ID, COPY_ID)
    )

    assert_equal ORIGINAL_ID, plan.occurrence_uuid_for(instance)
    assert_equal DEFINITION_ID, plan.source_uuid_for(definition)
    assert_equal COPY_ID, plan.source_uuid_for(definition_face)
  end

  def test_recursive_scan_assigns_distinct_virtual_identity_to_referenced_materials
    front_material = FakeEntity.new(31)
    back_material = FakeEntity.new(32)
    face = FakeEntity.new(30)
    face.material = front_material
    face.back_material = back_material
    model = model_with_registry

    plan = coordinator.plan(
      model: model,
      roots: [face],
      uuid_generator: uuid_generator(MISSING_ID, MALFORMED_ID, SECOND_MATERIAL_ID)
    )

    assert_equal MISSING_ID, plan.source_uuid_for(face)
    assert_equal MALFORMED_ID, plan.source_uuid_for(front_material)
    assert_equal SECOND_MATERIAL_ID, plan.source_uuid_for(back_material)
    assert_empty front_material.writes
    assert_empty back_material.writes
    assert_empty model.operation_calls
  end

  def test_second_clean_plan_is_byte_stable_across_order_names_and_transforms
    first = entity(11, ORIGINAL_ID)
    second = entity(12, COPY_ID)
    model = model_with_registry(
      claims: {
        ORIGINAL_ID => claim(ORIGINAL_ID, 11),
        COPY_ID => claim(COPY_ID, 12)
      }
    )

    first_plan = coordinator.plan(model: model, roots: [first, second])
    first.name = 'renamed'
    first.transformation = 'moved'
    second.name = 'also renamed'
    second_plan = coordinator.plan(model: model, roots: [second, first])

    assert_equal plan_bytes(first_plan, [first, second]), plan_bytes(second_plan, [first, second])
    refute first_plan.write_required?
    refute second_plan.write_required?
  end

  def test_dirty_plan_keeps_each_entity_uuid_when_root_traversal_is_reversed
    first = FakeEntity.new(11)
    second = FakeEntity.new(12)
    model = model_with_registry

    forward = coordinator.plan(
      model: model,
      roots: [first, second],
      uuid_generator: uuid_generator(MISSING_ID, MALFORMED_ID)
    )
    reversed = coordinator.plan(
      model: model,
      roots: [second, first],
      uuid_generator: uuid_generator(DEFINITION_ID, COPY_ID)
    )

    assert_equal MISSING_ID, forward.source_uuid_for(first)
    assert_equal MALFORMED_ID, forward.source_uuid_for(second)
    assert_equal forward.source_uuid_for(first), reversed.source_uuid_for(first)
    assert_equal forward.source_uuid_for(second), reversed.source_uuid_for(second)
  end

  def test_repeated_plan_of_unchanged_dirty_model_keeps_model_and_entity_uuid_mapping
    first = FakeEntity.new(11)
    second = FakeEntity.new(12)
    model = FakeModel.new

    initial = coordinator.plan(
      model: model,
      roots: [first, second],
      uuid_generator: uuid_generator(MODEL_ID, MISSING_ID, MALFORMED_ID)
    )
    repeated = coordinator.plan(
      model: model,
      roots: [first, second],
      uuid_generator: uuid_generator(DEFINITION_ID, COPY_ID, SEMANTIC_ID)
    )

    assert_equal MODEL_ID, initial.model_id
    assert_equal initial.model_id, repeated.model_id
    assert_equal initial.source_uuid_for(first), repeated.source_uuid_for(first)
    assert_equal initial.source_uuid_for(second), repeated.source_uuid_for(second)
    assert_equal plan_bytes(initial, [first, second]), plan_bytes(repeated, [first, second])
  end

  def test_pending_identity_survives_gc_after_first_plan_is_released
    first = FakeEntity.new(11)
    second = FakeEntity.new(12)
    model = FakeModel.new
    expected = detached_dirty_plan_ids(
      model,
      [first, second],
      [MODEL_ID, MISSING_ID, MALFORMED_ID]
    )

    3.times { GC.start(full_mark: true, immediate_sweep: true) }
    repeated = coordinator.plan(
      model: model,
      roots: [second, first],
      uuid_generator: uuid_generator(DEFINITION_ID, COPY_ID, SEMANTIC_ID)
    )

    assert_equal MODEL_ID, repeated.model_id
    assert_equal expected.fetch(first), repeated.source_uuid_for(first)
    assert_equal expected.fetch(second), repeated.source_uuid_for(second)
  end

  def test_pending_uuid_is_associated_with_the_live_entity_not_its_pid
    entity = FakeEntity.new(11)
    model = model_with_registry

    initial = coordinator.plan(
      model: model,
      roots: [entity],
      uuid_generator: uuid_generator(MISSING_ID)
    )
    entity.persistent_id = 99
    repeated = coordinator.plan(
      model: model,
      roots: [entity],
      uuid_generator: uuid_generator(COPY_ID)
    )

    assert_equal MISSING_ID, initial.source_uuid_for(entity)
    assert_equal MISSING_ID, repeated.source_uuid_for(entity)
  end

  def test_runtime_harness_refuses_any_model_that_is_not_provably_disposable
    guard = BOMEngine::Tests::SemanticV2IdentitySketchupTest
    disposable = Struct.new(:path, :entities, :modified?).new('', [], false)
    saved = Struct.new(:path, :entities, :modified?).new('user-model.skp', [], false)
    nonempty = Struct.new(:path, :entities, :modified?).new('', [Object.new], false)
    modified = Struct.new(:path, :entities, :modified?).new('', [], true)

    guard.assert_disposable_model!(disposable)
    [saved, nonempty, modified].each do |model|
      assert_raises(RuntimeError) { guard.assert_disposable_model!(model) }
    end
  end

  def test_commit_is_private_and_clean_plan_returns_without_an_operation
    valid = entity(11, ORIGINAL_ID)
    model = model_with_registry(claims: { ORIGINAL_ID => claim(ORIGINAL_ID, 11) })
    plan = coordinator.plan(model: model, roots: [valid])

    assert_includes coordinator.private_methods, :commit!
    assert_same plan, coordinator.send(:commit!, model: model, plan: plan)
    assert_empty model.operation_calls
    assert_empty model.writes
    assert_empty valid.writes
  end

  def test_commit_writes_the_plan_in_exactly_one_undoable_operation
    missing = FakeEntity.new(12)
    model = model_with_registry
    plan = coordinator.plan(
      model: model,
      roots: [missing],
      uuid_generator: uuid_generator(MISSING_ID)
    )

    coordinator.send(:commit!, model: model, plan: plan)

    assert_equal [[:start, 'BOM Engine Semantic v2 Identity', true], [:commit]],
                 model.operation_calls
    assert_equal [
      [DICTIONARY, 'source_uuid', MISSING_ID],
      [DICTIONARY, 'origin_model_id', MODEL_ID]
    ], missing.writes
    assert_equal %w[registry_json registry_revision], model.writes.map { |write| write[1] }.sort
    registry_json = model.writes.find { |write| write[1] == 'registry_json' }[2]
    assert_equal 8, JSON.parse(registry_json).fetch('revision')
  end

  def test_commit_aborts_and_reraises_when_any_planned_write_fails
    missing = FakeEntity.new(12)
    missing.fail_on_key = 'origin_model_id'
    model = model_with_registry
    plan = coordinator.plan(
      model: model,
      roots: [missing],
      uuid_generator: uuid_generator(MISSING_ID)
    )

    error = assert_raises(RuntimeError) do
      coordinator.send(:commit!, model: model, plan: plan)
    end

    assert_equal 'injected write failure', error.message
    assert_equal [[:start, 'BOM Engine Semantic v2 Identity', true], [:abort]], model.operation_calls
    assert_empty model.writes
  end

  def test_aborted_commit_retains_pending_identity_for_retry
    missing = FakeEntity.new(12)
    missing.fail_on_key = 'source_uuid'
    model = model_with_registry
    initial = coordinator.plan(
      model: model,
      roots: [missing],
      uuid_generator: uuid_generator(MISSING_ID)
    )
    assert_raises(RuntimeError) do
      coordinator.send(:commit!, model: model, plan: initial)
    end
    missing.fail_on_key = nil

    retry_plan = coordinator.plan(
      model: model,
      roots: [missing],
      uuid_generator: uuid_generator(COPY_ID)
    )

    assert_equal MISSING_ID, retry_plan.source_uuid_for(missing)
  end

  def test_successful_commit_invalidates_pending_entity_allocations
    missing = FakeEntity.new(12)
    model = model_with_registry
    initial = coordinator.plan(
      model: model,
      roots: [missing],
      uuid_generator: uuid_generator(MISSING_ID)
    )
    coordinator.send(:commit!, model: model, plan: initial)
    missing.remove_attribute(DICTIONARY, 'source_uuid')
    missing.remove_attribute(DICTIONARY, 'origin_model_id')

    after_commit = coordinator.plan(
      model: model,
      roots: [missing],
      uuid_generator: uuid_generator(COPY_ID)
    )

    assert_equal COPY_ID, after_commit.source_uuid_for(missing)
    refute_equal MISSING_ID, after_commit.source_uuid_for(missing)
  end

  def test_registry_changes_added_after_planning_are_committed
    valid = entity(11, ORIGINAL_ID)
    model = model_with_registry(claims: { ORIGINAL_ID => claim(ORIGINAL_ID, 11) })
    plan = coordinator.plan(
      model: model,
      roots: [valid],
      uuid_generator: uuid_generator(SEMANTIC_ID)
    )
    refute plan.write_required?

    resolution = plan.registry.resolve_semantic(
      type: 'Wall',
      exact_key: 'wall-lineage-key',
      candidates: []
    )

    assert_equal SEMANTIC_ID, resolution.semantic_uuid
    assert plan.write_required?
    coordinator.send(:commit!, model: model, plan: plan)
    registry_json = model.writes.find { |write| write[1] == 'registry_json' }[2]
    assert_equal SEMANTIC_ID,
                 JSON.parse(registry_json).dig(
                   'semantic_lineage', 'Wall', 'wall-lineage-key', 'semantic_uuid'
                 )
  end

  def test_no_production_file_calls_the_private_commit_before_publication
    production_files = Dir[File.expand_path('../**/*.rb', __dir__)].reject do |path|
      path.include?('/tests/') || path.end_with?('/semantic_v2/publication.rb')
    end
    forbidden = /IdentityCoordinator\s*\.\s*commit!|(?:send|__send__)\s*\(\s*:commit!/
    callers = production_files.select { |path| File.read(path).match?(forbidden) }

    assert_empty callers, "private commit callers: #{callers.join(', ')}"
  end

  private

  def coordinator
    BOMEngine::SemanticV2::IdentityCoordinator
  end

  def entity(pid, source_uuid, origin_model_id: MODEL_ID)
    FakeEntity.new(
      pid,
      [
        [[DICTIONARY, 'source_uuid'], source_uuid],
        [[DICTIONARY, 'origin_model_id'], origin_model_id]
      ].to_h
    )
  end

  def model_with_registry(claims: {})
    state = {
      'model_id' => MODEL_ID,
      'revision' => 7,
      'prepared_generation' => nil,
      'source_claims' => claims,
      'semantic_lineage' => {}
    }
    FakeModel.new(
      [
        [[DICTIONARY, 'model_id'], MODEL_ID],
        [[DICTIONARY, 'registry_json'], BOMEngine::SemanticV2::CanonicalJSON.generate(state)],
        [[DICTIONARY, 'registry_revision'], 7]
      ].to_h
    )
  end

  def claim(source_uuid, owner_pid)
    {
      'source_uuid' => source_uuid,
      'owner_pid' => owner_pid,
      'origin_model_id' => MODEL_ID
    }
  end

  def uuid_generator(*values)
    lambda do
      raise 'unexpected UUID allocation' if values.empty?

      values.shift
    end
  end

  def detached_dirty_plan_ids(model, entities, generated)
    plan = coordinator.plan(
      model: model,
      roots: entities,
      uuid_generator: uuid_generator(*generated)
    )
    entities.each_with_object({}) do |entity, ids|
      ids[entity] = plan.source_uuid_for(entity).dup
    end
  end

  def plan_bytes(plan, entities)
    BOMEngine::SemanticV2::CanonicalJSON.generate(
      'model_id' => plan.model_id,
      'registry' => plan.registry.to_h,
      'source_uuids' => entities.map { |item| plan.source_uuid_for(item) },
      'diagnostics' => plan.diagnostics.sort
    )
  end
end
