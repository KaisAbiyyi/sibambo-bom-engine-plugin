# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../semantic_v2'

class SemanticV2RuntimeCompatibilityTest < Minitest::Test
  def test_eager_semantic_v2_namespace_loads_on_the_running_ruby
    assert defined?(BOMEngine::SemanticV2::CanonicalJSON)
    assert defined?(BOMEngine::SemanticV2::IdentityRegistry)
    assert defined?(BOMEngine::SemanticV2::IdentityCoordinator)
    assert defined?(BOMEngine::SemanticV2::Snapshot)
    assert defined?(BOMEngine::SemanticV2::Extractor)
  end
end
