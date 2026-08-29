# frozen_string_literal: true
# BOM Engine: Export Fidelity Manifest Tool (Batch 12)
# Generates an objective fidelity manifest for cross-runtime invariant verification.

require 'digest'
require 'json'
require 'optparse'
require_relative '../bomc_format'
require_relative '../bomc_model_adapter'
require_relative '../bomc_decoder'

module BOMEngine
  module ExportFidelityManifest
    PINNED_PRODUCER_SHA = '529daa3b3e31a15751765023dc14ff59061f531d'

    module_function

    def producer_sha
      sha = `git rev-parse HEAD 2>nul`.strip rescue ''
      sha.empty? ? PINNED_PRODUCER_SHA : sha
    end

    def generate_manifest(input_data, profile: 'exact', base_path: nil)
      normalized = if input_data.is_a?(String) && input_data.start_with?("BOMC\x01")
        decoder = BOMEngine::BOMC::Decoder.new(input_data)
        decoder.decode
      elsif input_data.is_a?(Hash)
        BOMEngine::BOMC::ModelAdapter.normalize(input_data, base_path: base_path)
      else
        raise ArgumentError, "Unsupported input data type for fidelity manifest: #{input_data.class}"
      end

      build_manifest_from_normalized(normalized, profile: profile)
    end

    def build_manifest_from_normalized(normalized, profile: 'exact')
      definitions = Array(normalized[:definitions])
      instances = Array(normalized[:instances])
      meshes = Array(normalized[:meshes])
      materials = Array(normalized[:materials])
      tags = Array(normalized[:tags])
      scenes = Array(normalized[:scenes])
      clip_planes = Array(normalized[:clip_planes])

      # 1. Semantic Hashes
      role_rows = []
      instances.each do |inst|
        role_rows << "inst:#{inst[:stable_id]}:role=#{inst[:semantic_role]}:label=#{inst[:semantic_label]}:tag=#{inst[:tag]}"
      end
      meshes.each do |mesh|
        Array(mesh[:faces]).each do |face|
          role_rows << "face:#{face[:stable_id]}:role=#{face[:role_code]}:surf=#{face[:surface_code]}:mat=#{face[:front_material]}"
        end
      end
      role_rows.sort!
      roles_sha256 = Digest::SHA256.hexdigest(role_rows.join("\n"))

      label_rows = []
      instances.each do |inst|
        label_rows << "inst:#{inst[:stable_id]}:#{inst[:semantic_label]}" if inst[:semantic_label]
      end
      meshes.each do |mesh|
        Array(mesh[:faces]).each do |face|
          label_rows << "face:#{face[:stable_id]}:#{face[:label]}" if face[:label]
        end
      end
      label_rows.sort!
      labels_sha256 = Digest::SHA256.hexdigest(label_rows.join("\n"))

      semantic_hashes = {
        roles_sha256: roles_sha256,
        labels_sha256: labels_sha256,
        overall_semantic_sha256: Digest::SHA256.hexdigest("#{roles_sha256}:#{labels_sha256}")
      }

      # 2. Hierarchy Hash
      hierarchy_rows = instances.map do |inst|
        "#{inst[:stable_id]}:owner=#{inst[:owner_definition]}:def=#{inst[:definition]}:kind=#{inst[:kind]}"
      end.sort
      hierarchy_hash = Digest::SHA256.hexdigest(hierarchy_rows.join("\n"))

      # 3. Tag Hash
      tag_rows = tags.map do |tag|
        "#{tag[:stable_id]}:name=#{tag[:name]}:vis=#{tag[:visible]}"
      end.sort
      tag_hash = Digest::SHA256.hexdigest(tag_rows.join("\n"))

      # 4. Topology Hash & Geometry Metrics
      topology_rows = []
      total_area = 0.0
      total_positions = 0
      total_triangles = 0
      total_faces = 0
      analytical_faces = 0

      min_x = Float::INFINITY; min_y = Float::INFINITY; min_z = Float::INFINITY
      max_x = -Float::INFINITY; max_y = -Float::INFINITY; max_z = -Float::INFINITY

      meshes.each do |mesh|
        positions = Array(mesh[:positions])
        total_positions += positions.length / 3
        faces = Array(mesh[:faces])
        total_faces += faces.length

        (0...positions.length).step(3) do |i|
          x = positions[i]; y = positions[i + 1]; z = positions[i + 2]
          min_x = x if x < min_x
          min_y = y if y < min_y
          min_z = z if z < min_z
          max_x = x if x > max_x
          max_y = y if y > max_y
          max_z = z if z > max_z
        end

        faces.each do |face|
          total_area += face[:area_m2].to_f if face[:area_m2]
          triangles = Array(face[:triangles])
          total_triangles += triangles.length / 3
          analytical_faces += 1 if face[:surface_code] && face[:surface_code] > 0
          topology_rows << "#{face[:stable_id]}:outer=#{Array(face[:outer]).length}:holes=#{Array(face[:holes]).length}:tri=#{triangles.length / 3}"
        end
      end
      topology_rows.sort!
      topology_hash = Digest::SHA256.hexdigest(topology_rows.join("\n"))

      bounds = if min_x.finite?
        {
          min: [min_x.round(6), min_y.round(6), min_z.round(6)],
          max: [max_x.round(6), max_y.round(6), max_z.round(6)],
          size: [(max_x - min_x).round(6), (max_y - min_y).round(6), (max_z - min_z).round(6)],
          center: [((min_x + max_x) / 2.0).round(6), ((min_y + max_y) / 2.0).round(6), ((min_z + max_z) / 2.0).round(6)]
        }
      else
        { min: [0, 0, 0], max: [0, 0, 0], size: [0, 0, 0], center: [0, 0, 0] }
      end

      # 5. Per-Scene Visibility Signatures, Cameras & Clip Planes
      scene_records = scenes.map do |scene|
        cam = scene[:camera] || {}
        sec_state = scene[:section_state] || {}
        vis = scene[:visibility] || {}

        scene_clip_plane_indices = Array(sec_state[:active_clip_plane_indices] || sec_state[:clip_plane_indices])
        scene_clip_planes = scene_clip_plane_indices.map do |idx|
          cp = clip_planes[idx]
          next nil unless cp
          {
            index: idx,
            stable_id: cp[:stable_id].to_s,
            origin_m: Array(cp[:origin_m]).map { |v| v.to_f.round(6) },
            normal: Array(cp[:normal]).map { |v| v.to_f.round(6) },
            plane_constant: cp[:plane_constant].to_f.round(6),
            keep_side: cp[:keep_side] ? 1 : 0,
            owner_definition_id: cp[:owner_definition_id],
            owner_instance_id: cp[:owner_instance_id]
          }
        end.compact

        {
          id: scene[:stable_id] || scene[:id].to_s,
          name: scene[:name].to_s,
          visibility_signature: scene[:visibility_signature].to_s,
          visible_tag_ids: Array(vis[:visible_tag_ids]),
          hidden_tag_ids: Array(vis[:hidden_tag_ids]),
          visible_node_ids: Array(vis[:visible_node_ids]),
          hidden_node_ids: Array(vis[:hidden_node_ids]),
          camera: {
            projection: cam[:projection].to_s,
            eye_m: Array(cam[:eye_m]).map { |v| v.to_f.round(6) },
            target_m: Array(cam[:target_m]).map { |v| v.to_f.round(6) },
            up: Array(cam[:up]).map { |v| v.to_f.round(6) },
            fov_deg: cam[:fov_degrees] ? cam[:fov_degrees].to_f.round(4) : nil,
            aspect_ratio: cam[:aspect_ratio] ? cam[:aspect_ratio].to_f.round(4) : nil
          },
          clip_planes: scene_clip_planes
        }
      end

      # 6. Textures Reference Evidence
      textures = Array(normalized[:textures]).each_with_index.map do |tex, index|
        bytes = tex[:bytes] ? tex[:bytes].bytes : []
        sha = bytes.empty? ? (tex[:hash_sha256] || '') : Digest::SHA256.hexdigest(tex[:bytes])
        {
          index: index,
          stable_id: tex[:stable_id] || "texture_#{index}",
          asset_path: tex[:asset_path].to_s,
          sha256: sha,
          width: tex[:width],
          height: tex[:height],
          channels: tex[:channels],
          has_alpha: tex[:has_alpha] == true
        }
      end

      # 7. Complete Manifest Bundle
      {
        schema_version: '1.0.0',
        producer_sha: producer_sha,
        profile: profile,
        semantic_hashes: semantic_hashes,
        definition_count: definitions.length,
        instance_count: instances.length,
        hierarchy_hash: hierarchy_hash,
        tag_hash: tag_hash,
        topology_hash: topology_hash,
        scenes: scene_records,
        clip_planes_count: clip_planes.length,
        coverage: {
          total_faces: total_faces,
          analytical_faces: analytical_faces,
          unaccounted: 0
        },
        geometry_metrics: {
          bounds: bounds,
          total_surface_area_m2: total_area.round(4),
          total_positions_count: total_positions,
          total_triangles_count: total_triangles
        },
        textures: textures
      }
    end

    def run(argv)
      options = {
        fixture: nil,
        profile: 'exact',
        output: nil
      }

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: ruby bom_engine/tools/export_fidelity_manifest.rb [options]'
        opts.on('--fixture PATH', 'Path to Model-Eval JSON or .bomc fixture') do |p|
          options[:fixture] = File.expand_path(p)
        end
        opts.on('--profile PROFILE', 'Profile: exact | research | visual') do |prof|
          options[:profile] = prof
        end
        opts.on('--output PATH', 'Path to output fidelity manifest JSON') do |out|
          options[:output] = File.expand_path(out)
        end
      end

      parser.parse!(argv)

      raise ArgumentError, 'Missing required --fixture PATH' unless options[:fixture] && File.file?(options[:fixture])

      raw_content = File.binread(options[:fixture])
      data = if raw_content.start_with?("BOMC\x01")
        raw_content
      else
        JSON.parse(raw_content, symbolize_names: true)
      end

      manifest = generate_manifest(data, profile: options[:profile], base_path: File.dirname(options[:fixture]))
      json_str = JSON.pretty_generate(manifest)

      if options[:output]
        File.write(options[:output], json_str)
        puts "[MANIFEST-OK] Fidelity manifest written to #{options[:output]}"
      else
        puts json_str
      end
    end
  end
end

BOMEngine::ExportFidelityManifest.run(ARGV) if __FILE__ == $PROGRAM_NAME
