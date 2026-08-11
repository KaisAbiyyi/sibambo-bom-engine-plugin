# frozen_string_literal: true

require 'digest'

module BOMEngine
  module CleanAnalysis
    # Runtime identity diagnostic. This is deliberately not serialized in
    # CleanV1 documents, so deterministic exports remain byte-for-byte stable.
    module BuildInfo
      TRACKED_FILES = %w[
        ../semantic_v2/extractor.rb
        coverage_ledger.rb
        completeness_report.rb
        compiler.rb
        visual_edge_extractor.rb
        texture_bundle.rb
        texture_extractor.rb
        deterministic_zip.rb
        visual_package.rb
        writer.rb
        exporter.rb
      ].freeze

      module_function

      def source_root
        File.expand_path('..', __dir__)
      end

      def fingerprint
        digest = Digest::SHA256.new
        TRACKED_FILES.each do |relative_path|
          path = File.expand_path(relative_path, __dir__)
          digest.update(relative_path)
          digest.update(File.binread(path))
        end
        digest.hexdigest[0, 12]
      end

      def diagnostic
        "CleanV1 exporter build: #{fingerprint}\nActive extension source: #{source_root}"
      end
    end
  end
end
