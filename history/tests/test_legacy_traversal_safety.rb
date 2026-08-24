# frozen_string_literal: true

module Sketchup
  class Entity
    def deleted?
      false
    end
  end

  class Face < Entity; end
  class Edge < Entity; end

  class Group < Entity
    attr_reader :entities

    def initialize(entities)
      @entities = entities
    end
  end

  class ComponentInstance < Entity
    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end
  end
end

class CountingEntities < Array
  attr_reader :passes

  def initialize(*items)
    super(items)
    @passes = 0
  end

  def inject(*args, &block)
    @passes += 1
    super
  end
end

Definition = Struct.new(:entities)

module SibamboHistory; end

VERSIONS = {
  '2026.05.11-01' => 'V20260511_01',
  '2026.05.11-02' => 'V20260511_02',
  '2026.05.11-EXP' => 'V20260511_EXP',
  '2026.05.11-03' => 'V20260511_03'
}.freeze

VERSIONS.each do |directory, namespace|
  version_module = if SibamboHistory.const_defined?(namespace, false)
                     SibamboHistory.const_get(namespace)
                   else
                     SibamboHistory.const_set(namespace, Module.new)
                   end
  constants = version_module.const_set(:Constants, Module.new)
  constants.const_set(:MAX_RECURSION_DEPTH, 32)

  require_relative "../generated/SBE-#{directory}/staged/bom_engine/traversal"

  traversal = version_module.const_get(:Traversal)
  leaf_entities = CountingEntities.new(Sketchup::Face.new)
  leaf_definition = Definition.new(leaf_entities)
  repeated_leaf_instances = CountingEntities.new(
    *Array.new(50) { Sketchup::ComponentInstance.new(leaf_definition) }
  )
  outer_definition = Definition.new(repeated_leaf_instances)
  root_entities = CountingEntities.new(
    *Array.new(20) { Sketchup::ComponentInstance.new(outer_definition) }
  )

  face_count = traversal.count_faces(root_entities)
  raise "#{directory}: expected 1000 faces, got #{face_count}" unless face_count == 1_000
  raise "#{directory}: outer definition rescanned #{repeated_leaf_instances.passes} times" unless repeated_leaf_instances.passes == 1
  raise "#{directory}: leaf definition rescanned #{leaf_entities.passes} times" unless leaf_entities.passes == 1
end

puts 'legacy traversal safety: PASS (4 versions, repeated definitions memoized)'
