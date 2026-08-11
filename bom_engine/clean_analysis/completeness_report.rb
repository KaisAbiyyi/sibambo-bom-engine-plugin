# frozen_string_literal: true

module BOMEngine
  module CleanAnalysis
    # Pure-Ruby view of the compact diagnostics emitted by a CleanV1 document.
    module CompletenessReport
      module_function

      def generate(document)
        diagnostics = document.fetch('diagnostics')
        coverage = diagnostics.fetch('coverage')
        topology = diagnostics.fetch('topology')
        materials = diagnostics.fetch('materials')
        definitions = diagnostics.fetch('definitions')
        {
          'source_eligible' => {
            'primitive_count' => coverage.values.inject(0, :+)
          },
          'output' => coverage.dup,
          'materials' => materials.dup,
          'topology' => {
            'polygon_count' => document.fetch('surfaces').length + document.fetch('definitions').inject(0) do |sum, definition|
              sum + definition.dig('geometry', 'surfaces').length
            end,
            'standalone_edges' => topology.fetch('standalone_edges'),
            'vertex_occurrences' => topology.fetch('top_level_vertex_occurrences'),
            'unique_pooled_vertices' => topology.fetch('top_level_unique_vertices') +
              topology.fetch('definition_pooled_vertices')
          },
          'definitions' => definitions.dup
        }
      end
    end
  end
end
