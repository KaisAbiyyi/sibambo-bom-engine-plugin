# frozen_string_literal: true

# Host-free capture boundary shared by all Evolution writers. CaptureIR keeps
# the public canonical Hash shape intact; capture-only identity/evidence lives
# on the object rather than as serialized graph keys.
module BOMEngine
  class CaptureIR < Hash
    attr_reader :source_digest, :source_info, :profile, :texture_representation, :texture_evidence

    def self.wrap(graph, source_info: nil, profile: nil, texture_representation: nil, texture_evidence: nil)
      return graph if graph.is_a?(self) && graph.capture_identity_matches?(source_info, profile, texture_representation)

      new(
        graph,
        source_info: source_info,
        profile: profile,
        texture_representation: texture_representation,
        texture_evidence: texture_evidence
      )
    end

    def initialize(graph = {}, source_info: nil, profile: nil, texture_representation: nil, texture_evidence: nil)
      super()
      replace(graph || {})
      freeze_texture_payloads!
      @source_info = detached_source_info(source_info).freeze
      @source_digest = valid_sha256(@source_info[:sha256])
      @profile = profile && profile.to_s.freeze
      @texture_representation = texture_representation && texture_representation.to_s.freeze
      @texture_evidence = Array(texture_evidence).map { |row| row.is_a?(Hash) ? row.dup.freeze : row }.freeze
    end

    def capture_identity_matches?(source_info, profile, texture_representation)
      incoming = source_info.is_a?(Hash) ? (source_info[:sha256] || source_info['sha256']) : nil
      @source_digest == valid_sha256(incoming) &&
        @profile.to_s == profile.to_s &&
        @texture_representation.to_s == texture_representation.to_s
    end

    # Used by tests and diagnostics. Production construction does not walk the
    # complete graph merely to prove detachment; live handles are removed at
    # their ownership boundary before wrapping.
    def detached?
      !contains_live_handle?(self)
    end

    private

    def detached_source_info(source_info)
      return {} unless source_info.is_a?(Hash)

      {
        path: source_info[:path] || source_info['path'],
        bytes: source_info[:bytes] || source_info['bytes'],
        sha256: source_info[:sha256] || source_info['sha256'],
        available: source_info.key?(:available) ? source_info[:available] : source_info['available']
      }.reject { |_key, value| value.nil? }
    end

    def valid_sha256(value)
      text = value.to_s.downcase
      text.match?(/\A[0-9a-f]{64}\z/) ? text.freeze : nil
    end

    def freeze_texture_payloads!
      materials = self[:materials] || self['materials']
      Array(materials).each do |material|
        next unless material.is_a?(Hash)
        texture = material[:texture] || material['texture']
        next unless texture.is_a?(Hash)
        bytes_key = texture.key?(:bytes) ? :bytes : 'bytes'
        bytes = texture[bytes_key]
        texture[bytes_key] = bytes.b.freeze if bytes.is_a?(String) && !bytes.frozen?
      end
    end

    def contains_live_handle?(value, seen = {})
      return false unless value.is_a?(Hash) || value.is_a?(Array)
      return false if seen[value.object_id]

      seen[value.object_id] = true
      if value.is_a?(Hash)
        value.any? do |key, child|
          key.to_s == '_entity' || live_handle?(child) || contains_live_handle?(child, seen)
        end
      else
        value.any? { |child| live_handle?(child) || contains_live_handle?(child, seen) }
      end
    end

    def live_handle?(value)
      name = value.class.name.to_s
      name.start_with?('Sketchup::') || name.start_with?('Geom::')
    end
  end
end
