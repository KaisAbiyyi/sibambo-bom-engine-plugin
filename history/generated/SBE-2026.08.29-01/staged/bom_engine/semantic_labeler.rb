# bom_engine/semantic_labeler.rb
# Turns explicit SketchUp object metadata into deterministic semantic labels.

module SibamboHistory
  module V20260829_01
  module SemanticLabeler
    LABEL_FIRST_POLICY = 'label_first'.freeze
    GEOMETRY_FALLBACK_POLICY = 'geometry_fallback'.freeze

    GENERIC_NAMES = [
      /\A\s*\(?group\)?(?:[#\s_-]*\d+)?\s*\z/i,
      /\A\s*(?:component|instance)(?:[#\s_-]*\d+)?\s*\z/i,
      /\A\s*(?:entity|object|shape)(?:[#\s_-]*\d+)?\s*\z/i
    ].freeze

    ROLE_PATTERNS = [
      ['exterior_wall', /\b(?:dinding\s+luar|exterior\s+wall|external\s+wall|facade|fasad)\b/i],
      ['interior_wall', /\b(?:dinding\s+dalam|interior\s+wall|partition|sekat)\b/i],
      ['roof', /\b(?:atap|roof|genteng|spandek|perabung|rafter)\b/i],
      ['ceiling', /\b(?:plafon|ceiling|langit(?:-langit)?)\b/i],
      ['floor', /\b(?:lantai|floor|slab|pelat\s+lantai|ubin|parket)\b/i],
      ['door', /\b(?:pintu|door|entrance|gerbang)\b/i],
      ['window', /\b(?:jendela|window|fenestration|glazing)\b/i],
      ['column', /\b(?:kolom|column|pillar|tiang)\b/i],
      ['beam', /\b(?:balok|beam|sloof|girder)\b/i],
      ['stair', /\b(?:tangga|stair|stairs|anak\s+tangga)\b/i],
      ['railing', /\b(?:railing|handrail|balustrade|pagar)\b/i],
      ['opening', /\b(?:opening|bukaan|void|lubang)\b/i],
      ['foundation', /\b(?:foundation|fondasi|pondasi)\b/i],
      ['furniture', /\b(?:furniture|furnitur|meja|kursi|sofa|lemari|ranjang|bed|table|chair|cabinet)\b/i],
      ['fixture', /\b(?:fixture|wastafel|sink|toilet|wc|lampu|sanitary|urinal|bathtub)\b/i],
      ['wall', /\b(?:dinding|wall)\b/i],
      ['structure', /\b(?:structure|struktur|structural)\b/i],
      ['room_boundary', /\b(?:room\s+boundary|space\s+boundary|batas\s+ruang)\b/i]
    ].freeze

    module_function

    def build(instance_name:, definition_name: nil, tag_name: nil, attached_labels: [])
      candidates = []
      Array(attached_labels).each do |label|
        append_candidate(candidates, label_value(label), 'attached_text')
      end
      append_candidate(candidates, instance_name, 'instance_name')
      append_candidate(candidates, definition_name, 'definition_name')
      append_candidate(candidates, tag_name, 'tag') if meaningful_tag?(tag_name)

      primary = candidates.first
      return empty_semantic if primary.nil?

      {
        label: primary[:value],
        source: primary[:source],
        role: role_for(primary[:value]),
        classification_policy: LABEL_FIRST_POLICY,
        aliases: candidates.map { |candidate| candidate[:value] }.uniq
      }
    end

    def empty_semantic
      {
        label: nil,
        source: 'none',
        role: nil,
        classification_policy: GEOMETRY_FALLBACK_POLICY,
        aliases: []
      }
    end

    def role_for(value)
      text = clean(value)
      return nil if text.empty?

      match = ROLE_PATTERNS.find { |(_, pattern)| pattern.match?(text) }
      match && match.first
    end

    def meaningful_name?(value)
      text = clean(value)
      !text.empty? && GENERIC_NAMES.none? { |pattern| pattern.match?(text) }
    end

    def meaningful_tag?(value)
      text = clean(value)
      return false if text.empty?

      !%w[untagged layer0 default].include?(text.downcase)
    end

    def clean(value)
      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').strip.gsub(/\s+/, ' ')
    rescue StandardError
      value.to_s.strip.gsub(/\s+/, ' ')
    end

    def append_candidate(candidates, value, source)
      text = clean(value)
      return unless meaningful_name?(text)
      return if candidates.any? { |candidate| candidate[:value].casecmp?(text) }

      candidates << { value: text, source: source }
    end
    private_class_method :append_candidate

    def label_value(label)
      label.is_a?(Hash) ? (label[:value] || label['value']) : label
    end
    private_class_method :label_value
  end
end

end # SibamboHistory
