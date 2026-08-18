# frozen_string_literal: true

require 'fileutils'
require_relative 'deterministic_zip'

module SibamboHistory
  module V20260812_01
  module CleanAnalysis
    module VisualPackage
      module_function

      def write(path, document, assets, progress: nil, compression_level: Zlib::BEST_COMPRESSION)
        output_path = File.expand_path(path.to_s)
        raise ArgumentError, 'visual package output path is required' if path.to_s.strip.empty?

        model_json = Writer.generate(document, progress: progress)
        material_assets = document.fetch('materials', []).each_with_object({}) do |item, result|
          asset = item.dig('texture', 'asset')
          result[item.fetch('id')] = asset unless asset.nil?
        end
        asset_references = material_assets.values
        selected = asset_references.uniq.sort.each_with_object({}) do |asset, result|
          unless asset.is_a?(String) && asset.match?(%r{\Aassets/tex-[0-9a-f]{64}\.[a-z0-9]+\z})
            raise ArgumentError, "invalid portable texture asset path: #{asset.inspect}"
          end
          result[asset] = assets.fetch(asset) { raise ArgumentError, "missing texture asset: #{asset}" }
        end
        FileUtils.mkdir_p(File.dirname(output_path))
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        entry_statistics = DeterministicZip.write(
          output_path,
          { 'model.json' => model_json }.merge(selected),
          compression_level: compression_level
        )
        packaging_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        asset_bytes = selected.values.inject(0) { |sum, bytes| sum + bytes.bytesize }
        {
          path: output_path,
          bytes: File.size(output_path),
          model_json_bytes: model_json.bytesize,
          model_json_compressed_bytes: entry_statistics.fetch('model.json'.b).fetch(:archive_bytes),
          texture_asset_bytes: asset_bytes,
          texture_archive_bytes: selected.keys.inject(0) do |sum, name|
            sum + entry_statistics.fetch(name.to_s.b).fetch(:archive_bytes)
          end,
          packaging_seconds: packaging_seconds,
          compression_level: compression_level,
          unique_texture_count: selected.length,
          original_texture_references: count_texture_references(document, material_assets),
          dedup_ratio: dedup_ratio(document, material_assets, selected.length),
          counts: document.fetch('diagnostics').fetch('counts').dup,
          document: document
        }
      end

      def count_texture_references(value, material_assets)
        case value
        when Hash
          value.inject(0) do |sum, (key, child)|
            if Writer::MATERIAL_REFERENCE_KEYS.include?(key.to_s) && material_assets.key?(child)
              sum + 1
            else
              sum + count_texture_references(child, material_assets)
            end
          end
        when Array
          value.inject(0) { |sum, child| sum + count_texture_references(child, material_assets) }
        else
          0
        end
      end
      private_class_method :count_texture_references

      def dedup_ratio(document, material_assets, unique_count)
        references = count_texture_references(document, material_assets)
        references.zero? ? 1.0 : references.to_f / [unique_count, 1].max
      end
      private_class_method :dedup_ratio
    end
  end
end

end # SibamboHistory
