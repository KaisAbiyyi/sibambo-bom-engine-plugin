# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../clean_analysis/build_info'

module SibamboHistory
  module V20260812_01
  module Tests
    class CleanAnalysisBuildInfoTest < Minitest::Test
      def test_fingerprint_is_compact_and_source_derived
        fingerprint = CleanAnalysis::BuildInfo.fingerprint

        assert_match(/\A[0-9a-f]{12}\z/, fingerprint)
        assert_includes(CleanAnalysis::BuildInfo.diagnostic, fingerprint)
      end

      def test_source_root_is_runtime_folder
        assert_equal(
          File.dirname(__dir__),
          CleanAnalysis::BuildInfo.source_root
        )
      end
    end
  end
end

end # SibamboHistory
