# Run with standalone Ruby:
#   ruby bom_engine/tests/test_semantic_labeler.rb

require_relative '../semantic_labeler'

module SibamboHistory
  module V20260827_02
  module Tests
    module SemanticLabelerTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        attached = SemanticLabeler.build(
          instance_name: 'Pintu cadangan',
          definition_name: 'Door Component',
          tag_name: 'Bukaan',
          attached_labels: [{ value: 'Pintu Utama' }]
        )
        assert(attached[:label] == 'Pintu Utama', 'attached leader text has highest precedence')
        assert(attached[:source] == 'attached_text', 'attached leader text source is explicit')
        assert(attached[:role] == 'door', 'Indonesian door label maps deterministically')
        assert(attached[:classification_policy] == 'label_first', 'labeled object uses label-first policy')

        definition = SemanticLabeler.build(
          instance_name: '',
          definition_name: 'Jendela Kamar',
          tag_name: 'Untagged'
        )
        assert(definition[:label] == 'Jendela Kamar', 'component definition is a label fallback')
        assert(definition[:role] == 'window', 'window definition maps deterministically')

        unlabeled = SemanticLabeler.build(
          instance_name: '',
          definition_name: 'Component#46',
          tag_name: 'Untagged'
        )
        assert(unlabeled[:label].nil?, 'generated names are not treated as labels')
        assert(unlabeled[:classification_policy] == 'geometry_fallback', 'unlabeled object permits geometric fallback')
        puts 'Semantic Labeler Tests: ALL PASSED'
      end
    end
  end
end

SibamboHistory::V20260827_02::Tests::SemanticLabelerTest.run

end # SibamboHistory
