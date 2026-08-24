# frozen_string_literal: true

module SibamboHistory; end

VERSIONS = {
  'SBE-2026.07.16-01' => 'V20260716_01',
  'SBE-2026.07.16-02' => 'V20260716_02',
  'SBE-2026.07.16-03' => 'V20260716_03',
  'SBE-2026.08.13-01' => 'V20260813_01'
}.freeze

VERSIONS.each do |directory, namespace|
  require_relative "../generated/#{directory}/staged/bom_engine/canonical_graph_builder"
  version_module = SibamboHistory.const_get(namespace)
  traversal = version_module.const_get(:Traversal) if version_module.const_defined?(:Traversal, false)
  unless traversal
    traversal = version_module.const_set(:Traversal, Module.new)
    traversal.define_singleton_method(:exportable_entity?) { |_entity| true }
  end

  events = []
  builder = version_module.const_get(:CanonicalGraphBuilder).const_get(:Builder).allocate
  builder.instance_variable_set(:@progress, ->(event) { events << event })
  builder.instance_variable_set(:@batch_size, 2)
  builder.instance_variable_set(:@work_count, 0)
  builder.instance_variable_set(:@skipped, Hash.new(0))

  yielded = []
  builder.send(:each_entity, %i[a b c d e]) { |item| yielded << item }
  raise "#{directory}: traversal order changed" unless yielded == %i[a b c d e]
  raise "#{directory}: wrong checkpoint cadence #{events.inspect}" unless events.map { |event| event[:processed] } == [2, 4]
end

puts 'canonical checkpoint safety: PASS (4 versions, order preserved)'
