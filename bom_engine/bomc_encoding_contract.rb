# frozen_string_literal: true
# BOMC 1.2 Encoding Contract Section (Section 20)
# Binary serialization and deserialization of fidelity contracts and budget constraints.

require_relative 'bomc_profile'

module BOMEngine
  module BOMCEncodingContract
    SCHEMA_VERSION = 1
    ENCODER_REVISION = 1

    # Exact profile fidelity scope (Revision 1):
    # - Geometry: positions (Float64), normals (Float64), UVs (Float64), transforms (Float64_3x4), topology, visual edges: Exact (0 error)
    # - Metadata: definitions, instances, tags, scenes, clip planes: Exact
    # - Textures: Pixel lossless (lossless PNG or native JPEG preserved byte-identical)
    # - Materials: Color RGB (integer exact), alpha (Float32 / 16-bit mapped), material dimensions Float32 (v1.2 spec)
    # - Fallback: Text/Image instances Float32 (v1.2 spec)
    EXACT_SCOPE = {
      geometry: :exact_float64,
      textures: :pixel_lossless,
      metadata: :exact,
      materials: :spec_v1_2,
      fallback: :spec_v1_2
    }.freeze

    SECTION_BYTE_SIZE = 76
    PACK_FORMAT = 'vCCQ<EEQ<EEEECCCCV'.freeze

    PROFILE_ENUM = {
      exact: 1,
      research: 2,
      visual: 3
    }.freeze

    PROFILE_NAMES = PROFILE_ENUM.invert.freeze

    TEXTURE_POLICY_ENUM = {
      pixel_lossless: 1,
      perceptual_bounded: 2,
      web_aggressive_bounded: 3
    }.freeze

    TEXTURE_POLICY_NAMES = TEXTURE_POLICY_ENUM.invert.freeze

    module_function

    def encode(profile_contract, source_skp_bytes: 0, target_bytes: 0, encoder_revision: ENCODER_REVISION)
      contract = if profile_contract.is_a?(BOMCProfile::Profile)
                   profile_contract
                 else
                   BOMCProfile.fetch(profile_contract)
                 end

      profile_id = PROFILE_ENUM.fetch(contract.name) do
        raise ArgumentError, "Cannot encode unknown profile '#{contract.name}'."
      end

      texture_id = TEXTURE_POLICY_ENUM.fetch(contract.texture_policy) do
        raise ArgumentError, "Cannot encode unknown texture policy '#{contract.texture_policy}'."
      end

      src_bytes = Integer(source_skp_bytes || 0)
      tgt_bytes = Integer(target_bytes || 0)

      pos_error = contract.position_error_m == :semantic_policy ? -1.0 : Float(contract.position_error_m || 0.0)
      norm_error = contract.normal_error_deg == :semantic_policy ? -1.0 : Float(contract.normal_error_deg || 0.0)
      uv_err = contract.uv_error == :semantic_policy ? -1.0 : Float(contract.uv_error || 0.0)
      transform_err = Float(contract.transform_error || 0.0)

      pref_ratio = contract.preferred_ratio ? Float(contract.preferred_ratio) : 0.0
      h_ratio = contract.hard_ratio ? Float(contract.hard_ratio) : 0.0

      bytes = [
        SCHEMA_VERSION,
        profile_id,
        contract.requires_source_size ? 1 : 0,
        src_bytes,
        pref_ratio,
        h_ratio,
        tgt_bytes,
        pos_error,
        norm_error,
        uv_err,
        transform_err,
        texture_id,
        1, # semantic_exact
        1, # scene_exact
        1, # protected_topology_exact
        Integer(encoder_revision || ENCODER_REVISION)
      ].pack(PACK_FORMAT)

      raise "BOMC internal error: encoding contract packed size #{bytes.bytesize} != #{SECTION_BYTE_SIZE}" unless bytes.bytesize == SECTION_BYTE_SIZE

      bytes
    end

    def decode(bytes)
      raw = bytes.b
      raise "BOMC invalid: encoding contract section size #{raw.bytesize} != #{SECTION_BYTE_SIZE}" unless raw.bytesize == SECTION_BYTE_SIZE

      values = raw.unpack(PACK_FORMAT)
      schema_ver = values[0]
      raise "BOMC invalid: unsupported encoding contract schema version #{schema_ver}" unless schema_ver == SCHEMA_VERSION

      profile_id = values[1]
      profile_name = PROFILE_NAMES[profile_id]
      raise "BOMC invalid: unknown encoding contract profile enum #{profile_id}" unless profile_name

      source_size_req = values[2] == 1
      source_skp_bytes = values[3]
      preferred_ratio = values[4].zero? ? nil : values[4]
      hard_ratio = values[5].zero? ? nil : values[5]
      target_bytes = values[6]

      pos_error = values[7] < 0.0 ? :semantic_policy : values[7]
      norm_error = values[8] < 0.0 ? :semantic_policy : values[8]
      uv_error = values[9] < 0.0 ? :semantic_policy : values[9]
      transform_error = values[10]

      texture_id = values[11]
      texture_policy = TEXTURE_POLICY_NAMES[texture_id]
      raise "BOMC invalid: unknown texture policy enum #{texture_id}" unless texture_policy

      semantic_exact = values[12] == 1
      scene_exact = values[13] == 1
      protected_topology_exact = values[14] == 1
      encoder_rev = values[15]

      {
        schema_version: schema_ver,
        profile: profile_name,
        source_size_required: source_size_req,
        source_skp_bytes: source_skp_bytes,
        preferred_ratio: preferred_ratio,
        hard_ratio: hard_ratio,
        target_bytes: target_bytes,
        position_max_error_m: pos_error,
        normal_max_error_deg: norm_error,
        uv_max_error: uv_error,
        transform_max_error: transform_error,
        texture_policy: texture_policy,
        semantic_exact: semantic_exact,
        scene_exact: scene_exact,
        protected_topology_exact: protected_topology_exact,
        encoder_revision: encoder_rev
      }
    end
  end
end
