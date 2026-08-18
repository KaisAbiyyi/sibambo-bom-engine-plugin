# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../semantic_v2'

class SemanticV2RuntimeCompatibilityTest < Minitest::Test
  def test_eager_semantic_v2_namespace_loads_on_the_running_ruby
    assert defined?(SibamboHistory::V20260812_01::SemanticV2::CanonicalJSON)
    assert defined?(SibamboHistory::V20260812_01::SemanticV2::IdentityRegistry)
    assert defined?(SibamboHistory::V20260812_01::SemanticV2::IdentityCoordinator)
    assert defined?(SibamboHistory::V20260812_01::SemanticV2::Snapshot)
    assert defined?(SibamboHistory::V20260812_01::SemanticV2::Extractor)
  end
end
