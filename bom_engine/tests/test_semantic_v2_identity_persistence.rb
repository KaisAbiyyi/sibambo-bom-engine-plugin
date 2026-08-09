# frozen_string_literal: true

# Run only from the SketchUp Ruby Console in a new, empty, unmodified model:
# load 'D:/projects/sibambo/bom_engine_plugin-semantic-v2-m1/bom_engine/tests/test_semantic_v2_identity_persistence.rb'

require 'fileutils'
require 'tmpdir'

require_relative '../semantic_v2'
require_relative '../semantic_v2/identity_coordinator'

module BOMEngine
  module Tests
    module SemanticV2IdentityPersistenceTest
      module_function

      COORDINATOR = BOMEngine::SemanticV2::IdentityCoordinator
      DICTIONARY = 'BOMEngine.SemanticV2'
      TEST_DICTIONARY = 'BOMEngine.Tests.SemanticV2Persistence'

      def run
        raise 'SketchUp API is unavailable' unless defined?(Sketchup)

        model = Sketchup.active_model
        assert_disposable_blank_model!(model)
        directory = Dir.mktmpdir('bom-engine-semantic-v2-identity')
        original_path = File.join(directory, 'identity-original.skp')
        save_as_path = File.join(directory, 'identity-save-as.skp')

        face = create_fixture(model)
        plan = COORDINATOR.plan(model: model, roots: model.entities)
        semantic = plan.registry.resolve_semantic(
          type: 'Wall',
          exact_key: 'persistence-fixture-wall',
          candidates: []
        )
        COORDINATOR.send(:commit!, model: model, plan: plan)
        baseline = identity_snapshot(model, face, semantic.semantic_uuid)
        raise 'failed to save persistence fixture' unless model.save(original_path)

        raise 'failed to reopen persistence fixture' unless Sketchup.open_file(original_path)
        reopened_model = Sketchup.active_model
        reopened_face = fixture_face(reopened_model)
        reopened = identity_snapshot(reopened_model, reopened_face, semantic.semantic_uuid)
        check_equal('save/reopen', baseline, reopened)

        raise 'failed to Save As persistence fixture' unless reopened_model.save(save_as_path)
        raise 'failed to reopen Save As persistence fixture' unless Sketchup.open_file(save_as_path)
        save_as_model = Sketchup.active_model
        save_as_face = fixture_face(save_as_model)
        saved_as = identity_snapshot(save_as_model, save_as_face, semantic.semantic_uuid)
        check_equal('Save As', baseline, saved_as)

        puts 'Semantic v2 identity persistence tests: ALL PASSED'
        true
      ensure
        # The precondition guarantees this closes only the disposable fixture.
        Sketchup.file_new if defined?(Sketchup) && directory
        FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
      end

      def assert_disposable_blank_model!(model)
        safe = model && model.path.to_s.empty? && model.entities.empty? && !model.modified?
        return if safe

        raise 'Persistence test refused: use a new, empty, unmodified SketchUp model'
      end

      def create_fixture(model)
        model.start_operation('BOM Engine identity persistence fixture', true)
        face = model.entities.add_face([0, 0, 0], [24, 0, 0], [24, 24, 0], [0, 24, 0])
        face.set_attribute(TEST_DICTIONARY, 'persistence_fixture', true)
        raise 'test fixture marker leaked into production identity dictionary' unless
          face.get_attribute(DICTIONARY, 'persistence_fixture', nil).nil?
        model.commit_operation
        face
      rescue Exception
        model.abort_operation
        raise
      end

      def fixture_face(model)
        face = model.entities.grep(Sketchup::Face).find do |item|
          item.get_attribute(TEST_DICTIONARY, 'persistence_fixture', false)
        end
        raise 'saved persistence fixture face is missing' unless face

        face
      end

      def identity_snapshot(model, face, expected_semantic_uuid)
        registry_json = model.get_attribute(DICTIONARY, 'registry_json', nil)
        registry = BOMEngine::SemanticV2::IdentityRegistry.load(registry_json)
        semantic_uuid = registry.to_h.dig(
          'semantic_lineage', 'Wall', 'persistence-fixture-wall', 'semantic_uuid'
        )
        raise 'semantic UUID was not persisted' unless semantic_uuid == expected_semantic_uuid

        {
          model_id: model.get_attribute(DICTIONARY, 'model_id', nil),
          source_uuid: face.get_attribute(DICTIONARY, 'source_uuid', nil),
          semantic_uuid: semantic_uuid,
          revision: model.get_attribute(DICTIONARY, 'registry_revision', nil)
        }
      end

      def check_equal(label, expected, actual)
        raise "#{label} identity mismatch: #{actual.inspect}" unless actual == expected

        puts "  PASS #{label} preserves model, source, semantic IDs, and revision"
      end
    end
  end
end

BOMEngine::Tests::SemanticV2IdentityPersistenceTest.run
