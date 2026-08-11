# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'binary/document_encoder'
require_relative 'deterministic_zip'

module BOMEngine
  module CleanAnalysis
    module CleanPackage
      ASSET_PATTERN = %r{\Aassets/tex-[0-9a-f]{64}\.[a-z0-9]+\z}.freeze

      module_function

      def write(path, document, assets, compression_level: Zlib::BEST_COMPRESSION)
        output_path = File.expand_path(path.to_s)
        raise ArgumentError, 'clean package output path is required' if path.to_s.strip.empty?

        encoded = Binary::DocumentEncoder.encode(document)
        manifest_json = JSON.generate(encoded.fetch(:manifest))
        selected = select_assets(document, assets)
        entries = {
          'manifest.json' => manifest_json,
          'buffers.bin' => encoded.fetch(:buffers)
        }.merge(selected)
        FileUtils.mkdir_p(File.dirname(output_path))
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        entry_statistics = DeterministicZip.write(
          output_path, entries, compression_level: compression_level
        )
        packaging_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        {
          path: output_path,
          bytes: File.size(output_path),
          manifest_bytes: manifest_json.bytesize,
          manifest_compressed_bytes: archive_size(entry_statistics, 'manifest.json'),
          buffer_bytes: encoded.fetch(:buffers).bytesize,
          buffer_compressed_bytes: archive_size(entry_statistics, 'buffers.bin'),
          texture_asset_bytes: selected.values.inject(0) { |sum, bytes| sum + bytes.bytesize },
          texture_archive_bytes: selected.keys.inject(0) { |sum, name| sum + archive_size(entry_statistics, name) },
          unique_texture_count: selected.length,
          section_count: encoded.dig(:statistics, :section_count),
          position_codecs: encoded.dig(:statistics, :position_codecs),
          padding_bytes: encoded.dig(:statistics, :padding_bytes),
          packaging_seconds: packaging_seconds,
          compression_level: compression_level,
          counts: document.fetch('diagnostics').fetch('counts').dup,
          entry_statistics: entry_statistics,
          document: document
        }
      end

      def select_assets(document, assets)
        document.fetch('materials', []).map { |item| item.dig('texture', 'asset') }.compact.uniq.sort.each_with_object({}) do |asset, result|
          unless asset.is_a?(String) && asset.match?(ASSET_PATTERN)
            raise ArgumentError, "invalid portable texture asset path: #{asset.inspect}"
          end
          result[asset] = assets.fetch(asset) { raise ArgumentError, "missing texture asset: #{asset}" }
        end
      end
      private_class_method :select_assets

      def archive_size(statistics, name)
        statistics.fetch(name.to_s.b).fetch(:archive_bytes)
      end
      private_class_method :archive_size
    end
  end
end
