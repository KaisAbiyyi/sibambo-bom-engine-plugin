# frozen_string_literal: true

require 'digest'
require 'json'
require 'fileutils'
require_relative '../bom_engine/clean_analysis/clean_package'

abort 'usage: ruby dev/clean_package_benchmark.rb INPUT_MODEL_JSON OUTPUT.cleanpkg [PREVIOUS_ZIP] [SOURCE_SKP]' if ARGV.length < 2

input_path = File.expand_path(ARGV.fetch(0))
output_path = File.expand_path(ARGV.fetch(1))
previous_zip = ARGV[2] && File.expand_path(ARGV[2])
source_skp = ARGV[3] && File.expand_path(ARGV[3])
document = JSON.parse(File.binread(input_path))
input_directory = File.dirname(input_path)
assets = document.fetch('materials', []).map { |item| item.dig('texture', 'asset') }.compact.uniq.each_with_object({}) do |name, result|
  result[name] = File.binread(File.join(input_directory, name))
end

stats = BOMEngine::CleanAnalysis::CleanPackage.write(output_path, document, assets)
manifest = stats.fetch(:entry_statistics).fetch('manifest.json'.b)
buffer = stats.fetch(:entry_statistics).fetch('buffers.bin'.b)
encoded = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.encode(document)
sections = encoded.dig(:statistics, :section_descriptors).each_with_object({}) do |(name, descriptor), result|
  result[name] = descriptor.fetch('byte_length')
end
section_groups = Hash.new(0)
encoded.dig(:statistics, :section_descriptors).each do |name, descriptor|
  category = case name
             when /positions\z/ then 'positions'
             when /uvs\z|uv_offsets\z|uv_indices\z/ then 'uv'
             when /transforms\z/ then 'transforms'
             when /normals\z/ then 'normals'
             when /areas\z/ then 'areas'
             when /material_indices\z|definition_indices\z|parent_indices\z/ then 'references'
             when /surface_flags\z/ then 'surface_flags'
             when /loop_vertex_indices\z|loop_offsets\z|polygon_loop_offsets\z|edges\z/ then 'topology'
             else 'other'
             end
  section_groups[category] += descriptor.fetch('byte_length')
end
index_width_savings = encoded.dig(:statistics, :section_descriptors).inject(0) do |sum, (name, descriptor)|
  index_section = name.match?(/indices\z|offsets\z|edges\z/)
  sum + (index_section && descriptor.fetch('component_type') == 'uint16' ? descriptor.fetch('byte_length') : 0)
end
position_codecs = encoded.dig(:statistics, :position_codecs)
position_errors = {
  'max_error' => position_codecs.map { |item| item.dig(:metrics, :max_error) }.max || 0.0,
  'worst_section_p95_error' => position_codecs.map { |item| item.dig(:metrics, :p95_error) }.max || 0.0,
  'worst_section_rms_error' => position_codecs.map { |item| item.dig(:metrics, :rms_error) }.max || 0.0
}
uv_errors = []
collect_uv_errors = lambda do |value|
  case value
  when Hash
    uv_errors << value.fetch('max_error') if value['component_type'] == 'float32' && value.key?('max_error')
    value.each_value { |child| collect_uv_errors.call(child) }
  when Array
    value.each { |child| collect_uv_errors.call(child) }
  end
end
collect_uv_errors.call(encoded.fetch(:manifest))
archive_payload = stats.fetch(:entry_statistics).values.inject(0) { |sum, item| sum + item.fetch(:archive_bytes) }

groups = Hash.new(0)
walk = lambda do |value, path|
  case value
  when Hash
    value.each do |key, child|
      child_path = path + [key]
      category = case key
                 when 'transform' then 'json_transforms'
                 when 'uvs', 'front_uv', 'back_uv' then 'json_uv'
                 when 'vertices' then path.include?('visual_edges') ? 'json_visual_geometry' : 'json_positions'
                 when 'outer', 'holes'
                   path.include?('definitions') ? 'json_topology' : 'json_positions'
                 when 'edges' then 'json_topology'
                 else
                   key.end_with?('material_id') ? 'json_material_references' : nil
                 end
      if category
        groups[category] += JSON.generate(key => child).bytesize
      else
        walk.call(child, child_path)
      end
    end
  when Array
    value.each { |child| walk.call(child, path) }
  end
end
walk.call(document, [])
attributed = groups.values.inject(0, :+)
groups['json_metadata_and_structure_remainder'] = File.size(input_path) - attributed

scaling = {}
[1, 10, 100, 1_000, 10_000].each do |count|
  scaled = Marshal.load(Marshal.dump(document))
  template = scaled.fetch('instances').first
  scaled['instances'] = if template
                          count.times.map do |index|
                            item = Marshal.load(Marshal.dump(template))
                            item['id'] = format('benchmark-instance-%016x', index)
                            item.delete('parent_instance_id')
                            item
                          end
                        else
                          []
                        end
  scale_path = File.join(File.dirname(output_path), "scaling-#{count}.cleanpkg")
  scale_stats = BOMEngine::CleanAnalysis::CleanPackage.write(scale_path, scaled, assets)
  scale_encoded = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.encode(scaled)
  scale_sections = scale_encoded.dig(:statistics, :section_descriptors)
  scaling[count.to_s] = {
    'package_bytes' => scale_stats.fetch(:bytes),
    'buffer_bytes' => scale_stats.fetch(:buffer_bytes),
    'definition_position_bytes' => scale_sections.select { |name, _item| name.match?(/definition_.*_positions/) }.values.inject(0) { |sum, item| sum + item.fetch('byte_length') },
    'instance_transform_bytes' => scale_sections.fetch('instance_transforms').fetch('byte_length')
  }
end

report = {
  'input' => {
    'model_json_bytes' => File.size(input_path),
    'texture_asset_bytes' => assets.values.inject(0) { |sum, bytes| sum + bytes.bytesize },
    'previous_zip_bytes' => previous_zip && File.size(previous_zip),
    'source_skp_bytes' => source_skp && File.size(source_skp),
    'json_attribution' => groups
  },
  'output' => {
    'path' => output_path,
    'manifest_bytes' => stats.fetch(:manifest_bytes),
    'manifest_archive_bytes' => manifest.fetch(:archive_bytes),
    'buffers_bytes' => stats.fetch(:buffer_bytes),
    'buffers_archive_bytes' => buffer.fetch(:archive_bytes),
    'buffers_method' => buffer.fetch(:method),
    'buffers_stored_candidate_bytes' => buffer.fetch(:stored_candidate_bytes),
    'buffers_deflated_candidate_bytes' => buffer.fetch(:deflated_candidate_bytes),
    'sections' => sections,
    'section_groups' => section_groups,
    'uint16_index_width_savings_vs_uint32' => index_width_savings,
    'position_roundtrip_error' => position_errors,
    'uv_max_roundtrip_error' => uv_errors.max || 0.0,
    'padding_bytes' => stats.fetch(:padding_bytes),
    'texture_asset_bytes' => stats.fetch(:texture_asset_bytes),
    'texture_archive_bytes' => stats.fetch(:texture_archive_bytes),
    'container_overhead_bytes' => stats.fetch(:bytes) - archive_payload,
    'cleanpkg_bytes' => stats.fetch(:bytes),
    'sha256' => Digest::SHA256.file(output_path).hexdigest,
    'manifest_sha256' => Digest::SHA256.hexdigest(JSON.generate(encoded.fetch(:manifest))),
    'buffers_sha256' => Digest::SHA256.hexdigest(encoded.fetch(:buffers)),
    'coverage' => document.dig('diagnostics', 'coverage')
  },
  'scaling' => scaling
}
report_path = output_path + '.benchmark.json'
File.binwrite(report_path, JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(report)
puts "benchmark report: #{report_path}"
