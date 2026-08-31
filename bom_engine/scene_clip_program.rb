# frozen_string_literal: true
# BOMC Executable Section Clip Program and Plane Records (Batch 9)

require_relative 'bomc_format'
require_relative 'numeric_shape'

module BOMEngine
  module SceneClipProgram
    VERSION = 1
    MISSING = 0xffff_ffff

    module_function

    def create_plane(stable_id:, source_persistent_id:, origin_m:, normal:, keep_side: 1, owner_definition_id: nil, owner_instance_id: nil, flags: 0)
      orig = NumericShape.vec3(origin_m, path: 'clip_plane.origin_m')
      norm = NumericShape.vec3(normal, path: 'clip_plane.normal')
      len = Math.sqrt(norm[0]**2 + norm[1]**2 + norm[2]**2)
      if len > 1.0e-9
        norm = [norm[0] / len, norm[1] / len, norm[2] / len]
      else
        norm = [0.0, 0.0, 1.0]
      end

      # Plane equation: dot(normal, P) + constant = 0 => constant = -dot(normal, origin)
      constant = -(norm[0] * orig[0] + norm[1] * orig[1] + norm[2] * orig[2])

      {
        stable_id: stable_id.to_s,
        source_persistent_id: source_persistent_id.to_s,
        origin_m: orig,
        normal: norm,
        plane_constant: constant,
        keep_side: keep_side.to_i,
        owner_definition_id: owner_definition_id ? owner_definition_id.to_s : nil,
        owner_instance_id: owner_instance_id ? owner_instance_id.to_s : nil,
        flags: flags.to_i
      }
    end

    def build_section(planes, string_index)
      list = Array(planes)
      header = [VERSION, 0, 0, 0, list.length].pack('CCCCV')
      body = +''.b

      list.each do |p|
        stable_idx = string_index[p[:stable_id].to_s] || 0
        pid_idx = string_index[p[:source_persistent_id].to_s] || 0
        def_idx = p[:owner_definition_id] ? (string_index[p[:owner_definition_id].to_s] || MISSING) : MISSING
        inst_idx = p[:owner_instance_id] ? (string_index[p[:owner_instance_id].to_s] || MISSING) : MISSING

        orig = NumericShape.vec3(p[:origin_m], path: "clip_planes[#{p[:stable_id]}].origin_m")
        norm = NumericShape.vec3(p[:normal], path: "clip_planes[#{p[:stable_id]}].normal")
        const = p[:plane_constant].to_f

        body << [stable_idx, pid_idx].pack('VV')
        body << orig.pack('E3')
        body << norm.pack('E3')
        body << [const].pack('E')
        body << [p[:keep_side].to_i, def_idx, inst_idx, p[:flags].to_i, 0, 0, 0].pack('CVVVCCC')
      end

      header + body
    end

    def decode_section(bytes, strings)
      return [] if bytes.nil? || bytes.bytesize < 8
      version, _, _, _, count = bytes.unpack('CCCCV')
      raise "BOMC invalid: unsupported clip plane version #{version}." unless version == VERSION

      offset = 8
      record_size = 72 # 8 (refs) + 24 (orig) + 24 (norm) + 8 (const) + 1 (keep) + 4 (def) + 4 (inst) + 4 (flags) + 3 (pad) = 80
      # Let's unpack per record:
      planes = []
      count.times do |i|
        raise 'BOMC invalid: truncated clip plane section.' if offset + 80 > bytes.bytesize
        stable_idx, pid_idx = bytes[offset, 8].unpack('VV')
        orig = bytes[offset + 8, 24].unpack('E3')
        norm = bytes[offset + 32, 24].unpack('E3')
        const = bytes[offset + 56, 8].unpack('E').first
        keep_side, def_idx, inst_idx, flags = bytes[offset + 64, 13].unpack('CVVV')

        owner_def = def_idx != MISSING ? strings[def_idx] : nil
        owner_inst = inst_idx != MISSING ? strings[inst_idx] : nil

        planes << {
          index: i,
          stable_id: strings[stable_idx] || "plane:#{i}",
          source_persistent_id: strings[pid_idx] || "plane_pid:#{i}",
          origin_m: orig,
          normal: norm,
          plane_constant: const,
          keep_side: keep_side,
          owner_definition_id: owner_def,
          owner_instance_id: owner_inst,
          flags: flags
        }
        offset += 80
      end

      planes
    end
  end
end
