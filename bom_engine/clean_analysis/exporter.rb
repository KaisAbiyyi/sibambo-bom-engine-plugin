# frozen_string_literal: true

require_relative '../semantic_v2/identity_coordinator'
require_relative '../semantic_v2/extractor'

module BOMEngine
  module CleanAnalysis
    module Exporter
      EXTRACTION_POLICY_ID = 'bom-clean-analysis/1.0.0'.freeze

      module_function

      def export(model:, roots:, parent_transform:, output_path:, identity_plan: nil, settings: {})
        root_items = Array(roots)
        plan = identity_plan || SemanticV2::IdentityCoordinator.plan(
          model: model,
          roots: root_items
        )
        extraction_settings = {
          include_hidden: false,
          extraction_policy_id: EXTRACTION_POLICY_ID
        }.merge(settings || {})
        snapshot = SemanticV2::Extractor.extract(
          model: model,
          roots: root_items,
          parent_transform: parent_transform,
          identity_plan: plan,
          settings: extraction_settings
        )
        document = Compiler.compile(snapshot)
        Writer.write(output_path, document).merge(document: document)
      end
    end
  end
end
