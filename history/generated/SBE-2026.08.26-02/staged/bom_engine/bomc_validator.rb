# Independent logical differential validator for BOMC fixtures and exports.

require_relative 'bomc_format'
require_relative 'bomc_model_adapter'

module SibamboHistory
  module V20260826_02
  module BOMCValidator
    DEFAULT_TOLERANCES = {
      position_m: 0.001,
      normal_deg: 0.1,
      uv: 1.0e-4,
      transform: 1.0e-5,
      area_relative: 0.001,
      area_absolute_m2: 1.0e-6
    }.freeze

    def self.compare(source, decoded, tolerances: {})
      normalized = BOMC::ModelAdapter.normalize(source)
      limits = DEFAULT_TOLERANCES.merge(tolerances)
      position_errors = []
      normal_errors = []
      uv_errors = []
      transform_errors = []
      area_errors = []
      topology_exact = normalized[:meshes].length == decoded[:meshes].length
      visual_edges_exact = topology_exact
      materials_exact = compare_materials(normalized[:materials], decoded[:materials], decoded[:textures])
      tags_exact = normalized[:tags].each_with_index.all? do |tag, index|
        row = decoded[:tags][index]
        row && tag[:name].to_s == row[:name].to_s && tag[:visible] == row[:visible]
      end && normalized[:tags].length == decoded[:tags].length
      definitions_exact = normalized[:definitions].each_with_index.all? do |definition, index|
        row = decoded[:definitions][index]
        row && definition[:name].to_s == row[:name].to_s && definition[:kind].to_s == row[:kind].to_s && definition[:mesh] == row[:mesh]
      end && normalized[:definitions].length == decoded[:definitions].length
      instances_exact = normalized[:instances].each_with_index.all? do |instance, index|
        row = decoded[:instances][index]
        row &&
          instance[:name].to_s == row[:name].to_s &&
          instance[:kind].to_s == row[:kind].to_s &&
          instance[:owner_definition] == row[:owner_definition] &&
          instance[:definition] == row[:definition] &&
          instance[:transform] == row[:transform] &&
          instance[:material] == row[:material] &&
          instance[:tag] == row[:tag] &&
          instance[:visible] == row[:visible] &&
          normalize_role(instance[:semantic_role]) == row[:semantic_role].to_s &&
          optional_string(instance[:semantic_label]) == optional_string(row[:semantic_label])
      end && normalized[:instances].length == decoded[:instances].length
      fallback_exact = compare_fallback(normalized[:instances], decoded[:fallback], decoded[:textures])

      normalized[:meshes].each_with_index do |source_mesh, mesh_index|
        decoded_mesh = decoded[:meshes][mesh_index]
        unless decoded_mesh
          topology_exact = false
          visual_edges_exact = false
          next
        end
        position_errors.concat(point_errors(source_mesh[:positions], decoded_mesh[:positions]))
        topology_exact &&= source_mesh[:faces].length == decoded_mesh[:faces].length
        source_mesh[:faces].each_with_index do |source_face, face_index|
          decoded_face = decoded_mesh[:faces][face_index]
          unless decoded_face
            topology_exact = false
            next
          end
          topology_exact &&= source_face[:outer] == decoded_face[:outer]
          topology_exact &&= source_face[:holes] == decoded_face[:holes]
          topology_exact &&= source_face[:triangles] == decoded_face[:triangles]
          topology_exact &&= source_face[:front_material] == decoded_face[:front_material]
          topology_exact &&= source_face[:back_material] == decoded_face[:back_material]
          topology_exact &&= source_face[:front_appearance_required] == decoded_face[:front_appearance_required]
          topology_exact &&= source_face[:back_appearance_required] == decoded_face[:back_appearance_required]
          topology_exact &&= source_face[:tag] == decoded_face[:tag]
          topology_exact &&= normalize_surface(source_face[:surface_type]) == decoded_face[:surface_type].to_s
          topology_exact &&= normalize_role(source_face[:semantic_role]) == decoded_face[:semantic_role].to_s
          topology_exact &&= optional_string(source_face[:semantic_label]) == optional_string(decoded_face[:semantic_label])
          topology_exact &&= source_face[:hidden] == decoded_face[:hidden]
          normal_errors << angular_error(source_face[:normal], decoded_face[:normal])
          source_uv = flatten_uv(source_face[:uv])
          decoded_uv = flatten_uv(decoded_face[:uv])
          if source_uv.length == decoded_uv.length
            uv_errors.concat(pair_errors(source_uv, decoded_uv))
          else
            uv_errors << Float::INFINITY
          end
          area_errors << (source_face[:area_m2].to_f - decoded_face[:area_m2].to_f).abs
        end
        source_edges = source_mesh[:edges].map { |edge| [edge[:vertices], edge[:tag], edge[:hidden], edge[:soft], edge[:smooth]] }
        decoded_edges = decoded_mesh[:edges].map { |edge| [edge[:vertices], edge[:tag], edge[:hidden], edge[:soft], edge[:smooth]] }
        visual_edges_exact &&= source_edges == decoded_edges
      end

      normalized[:transforms].each_with_index do |matrix, index|
        decoded_matrix = decoded[:transforms][index]
        if decoded_matrix
          transform_errors << matrix.each_with_index.map { |value, component| (value.to_f - decoded_matrix[component].to_f).abs }.max
        else
          transform_errors << Float::INFINITY
        end
      end
      position_summary = summarize(position_errors)
      normal_summary = summarize(normal_errors)
      uv_summary = summarize(uv_errors)
      transform_summary = summarize(transform_errors)
      area_summary = summarize(area_errors)
      source_texture_hashes = normalized[:materials].map { |material| material[:texture] && material[:texture][:sha256] }
      source_texture_hashes += normalized[:instances].map { |instance| instance.dig(:fallback, :texture, :sha256) }
      source_texture_hashes = source_texture_hashes.compact.uniq.sort
      decoded_texture_hashes = decoded[:textures].map { |texture| texture[:sha256] }.sort
      counts = {
        materials: [normalized[:materials].length, decoded[:materials].length],
        tags: [normalized[:tags].length, decoded[:tags].length],
        meshes: [normalized[:meshes].length, decoded[:meshes].length],
        faces: [normalized[:meshes].map { |mesh| mesh[:faces].length }.inject(0, :+), decoded[:meshes].map { |mesh| mesh[:faces].length }.inject(0, :+)],
        definitions: [normalized[:definitions].length, decoded[:definitions].length],
        instances: [normalized[:instances].length, decoded[:instances].length],
        transforms: [normalized[:transforms].length, decoded[:transforms].length],
        textures: [source_texture_hashes.length, decoded_texture_hashes.length]
      }
      counts[:exact] = counts.reject { |key, _value| key == :exact }.values.all? { |pair| pair[0] == pair[1] }
      maximum_area_tolerance = normalized[:meshes].map do |mesh|
        mesh[:faces].map do |face|
          [limits[:area_absolute_m2], face[:area_m2].to_f.abs * limits[:area_relative]].max
        end
      end.flatten.max || limits[:area_absolute_m2]

      {
        counts: counts,
        materials: { exact: materials_exact },
        tags: { exact: tags_exact },
        definitions: { exact: definitions_exact },
        instances: { exact: instances_exact },
        fallback: { exact: fallback_exact },
        positions: {
          max_error_m: position_summary[:max], p95_error_m: position_summary[:p95], rms_error_m: position_summary[:rms],
          passed: position_summary[:max] <= limits[:position_m] + 1.0e-12
        },
        topology: { exact: topology_exact },
        normals: {
          max_angular_error_deg: normal_summary[:max], p95_angular_error_deg: normal_summary[:p95], rms_angular_error_deg: normal_summary[:rms],
          passed: normal_summary[:max] <= limits[:normal_deg] + 1.0e-12
        },
        uv: {
          max_error: uv_summary[:max], p95_error: uv_summary[:p95], rms_error: uv_summary[:rms],
          passed: uv_summary[:max] <= limits[:uv] + 1.0e-12
        },
        transforms: {
          max_error: transform_summary[:max], p95_error: transform_summary[:p95], rms_error: transform_summary[:rms],
          passed: transform_summary[:max] <= limits[:transform] + 1.0e-12
        },
        areas: {
          max_error_m2: area_summary[:max], p95_error_m2: area_summary[:p95], rms_error_m2: area_summary[:rms],
          tolerance_m2: maximum_area_tolerance,
          passed: area_summary[:max] <= maximum_area_tolerance + 1.0e-12
        },
        visual_edges: { exact: visual_edges_exact },
        textures: { exact: source_texture_hashes == decoded_texture_hashes, hashes: decoded_texture_hashes },
        coverage: decoded[:coverage]
      }
    end

    def self.validate!(source, decoded, tolerances: {})
      result = compare(source, decoded, tolerances: tolerances)
      failures = []
      failures << 'table counts' unless result[:counts][:exact]
      failures << 'materials' unless result[:materials][:exact]
      failures << 'tags' unless result[:tags][:exact]
      failures << 'definitions' unless result[:definitions][:exact]
      failures << 'instances' unless result[:instances][:exact]
      failures << 'fallback' unless result[:fallback][:exact]
      failures << 'topology' unless result[:topology][:exact]
      failures << 'positions' unless result[:positions][:passed]
      failures << 'normals' unless result[:normals][:passed]
      failures << 'UV' unless result[:uv][:passed]
      failures << 'transforms' unless result[:transforms][:passed]
      failures << 'areas' unless result[:areas][:passed]
      failures << 'visual edges' unless result[:visual_edges][:exact]
      failures << 'textures' unless result[:textures][:exact]
      failures << 'coverage' unless result[:coverage][:unaccounted].to_i.zero?
      raise "BOMC differential validation failed: #{failures.join(', ')}." unless failures.empty?

      result
    end

    def self.compare_materials(source, decoded, textures)
      return false unless source.length == decoded.length
      source.each_with_index.all? do |material, index|
        row = decoded[index]
        source_texture = material.dig(:texture, :sha256)
        decoded_texture = row[:texture].nil? ? nil : textures.dig(row[:texture], :sha256)
        color = material[:color]
        row &&
          material[:name].to_s == row[:name].to_s &&
          material[:display_name].to_s == row[:display_name].to_s &&
          [:r, :g, :b, :a].all? { |channel| color[channel].to_i == row.dig(:color, channel).to_i } &&
          (material[:opacity].to_f - row[:opacity].to_f).abs <= (1.0 / 65_535.0 + 1.0e-12) &&
          source_texture == decoded_texture
      end
    end
    private_class_method :compare_materials

    def self.compare_fallback(instances, decoded, textures)
      source = instances.each_with_index.each_with_object([]) do |(instance, index), records|
        records << instance[:fallback].merge(instance: index) if instance[:fallback]
      end
      return false unless source.length == decoded.length
      source.each_with_index.all? do |fallback, index|
        row = decoded[index]
        source_texture = fallback.dig(:texture, :sha256)
        decoded_texture = row[:texture].nil? ? nil : textures.dig(row[:texture], :sha256)
        position_error = 3.times.map { |axis| (Array(fallback[:position])[axis].to_f - row[:position][axis].to_f).abs }.max
        row && fallback[:instance] == row[:instance] && fallback[:kind].to_s == row[:kind].to_s &&
          position_error <= 1.0e-5 &&
          (fallback[:width_m].to_f - row[:width_m].to_f).abs <= 1.0e-5 &&
          (fallback[:height_m].to_f - row[:height_m].to_f).abs <= 1.0e-5 &&
          fallback[:text].to_s == row[:text].to_s && source_texture == decoded_texture
      end
    end
    private_class_method :compare_fallback

    def self.normalize_surface(value)
      normalized = value.to_s.downcase.tr(' ', '_')
      BOMC::SURFACE_TYPES.key?(normalized) ? normalized : 'unknown'
    end
    private_class_method :normalize_surface

    def self.normalize_role(value)
      normalized = value.to_s.downcase.tr(' ', '_')
      BOMC::SEMANTIC_ROLES.key?(normalized) && !normalized.empty? ? normalized : 'unknown'
    end
    private_class_method :normalize_role

    def self.optional_string(value)
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end
    private_class_method :optional_string

    def self.summarize(errors)
      values = Array(errors).map(&:to_f).sort
      return { max: 0.0, p95: 0.0, rms: 0.0 } if values.empty?
      index = [(values.length * 0.95).ceil - 1, 0].max
      rms = Math.sqrt(values.map { |value| value * value }.inject(0.0, :+) / values.length)
      { max: values[-1], p95: values[index], rms: rms }
    end
    private_class_method :summarize

    def self.point_errors(source, decoded)
      return [Float::INFINITY] unless source.length == decoded.length
      source.each_slice(3).with_index.map do |point, index|
        offset = index * 3
        Math.sqrt(3.times.map { |axis| (point[axis].to_f - decoded[offset + axis].to_f)**2 }.inject(0.0, :+))
      end
    end
    private_class_method :point_errors

    def self.pair_errors(source, decoded)
      return [Float::INFINITY] unless source.length == decoded.length
      source.each_slice(2).with_index.map do |pair, index|
        offset = index * 2
        Math.sqrt(2.times.map { |axis| (pair[axis].to_f - decoded[offset + axis].to_f)**2 }.inject(0.0, :+))
      end
    end
    private_class_method :pair_errors

    def self.angular_error(left, right)
      left_length = Math.sqrt(left.map { |value| value.to_f * value.to_f }.inject(0.0, :+))
      right_length = Math.sqrt(right.map { |value| value.to_f * value.to_f }.inject(0.0, :+))
      return 0.0 if left_length.zero? && right_length.zero?
      return 180.0 if left_length.zero? || right_length.zero?
      dot = 3.times.map { |axis| (left[axis].to_f / left_length) * (right[axis].to_f / right_length) }.inject(0.0, :+)
      Math.acos([[dot, -1.0].max, 1.0].min) * 180.0 / Math::PI
    end
    private_class_method :angular_error

    def self.flatten_uv(uv)
      return [] unless uv.is_a?(Hash)
      [:front_outer, :front_holes, :back_outer, :back_holes].map do |key|
        Array(uv[key]).flatten
      end.flatten.map(&:to_f)
    end
    private_class_method :flatten_uv
  end
end

end # SibamboHistory
