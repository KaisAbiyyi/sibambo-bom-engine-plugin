# frozen_string_literal: true

# SIB-R1-ITCON-001 ModelTruth: canonical forms shared by the SketchUp side and
# the BOMC side. This file is the only place where a canonical form is defined,
# so a canonicalisation can never differ between the two sides.
#
# Requirements: runs unchanged on Ruby 2.5.9 and Ruby 3.2.2 (plan D33).
# No SketchUp and no bom_engine dependency.

require 'digest'

module SibamboModelTruthV1
  class ModelTruthError < StandardError; end
  class PixelError < ModelTruthError; end

  module Canonical
    SCHEMA = 'sibambo-model-truth-v1'
    MOD = 2**256
    INCH_M = 0.0254
    IDENTITY_T16 = [1_000_000_000, 0, 0, 0, 0, 1_000_000_000, 0, 0, 0, 0, 1_000_000_000, 0, 0, 0, 0, 1_000_000_000].freeze

    module_function

    # ---- numbers -----------------------------------------------------------

    def grid(v)
      raise ModelTruthError, 'nonfinite' unless v.is_a?(Numeric) && v.to_f.finite?

      (v.to_f * 1e9).round
    end

    def skp_pos(point)
      [point.x, point.y, point.z].map { |c| grid((c.to_f * INCH_M).round(9)) }
    end

    def skp_unit(c)
      grid(c.to_f.round(9))
    end

    # uvq responds to x, y, z. Returns [u, v] Integers on the grid, [0, 0] for
    # z == 0 (counted), or ['NaN', 'NaN'] for a non-finite result (never matches).
    def skp_uv(uvq, counters)
      z = uvq.z.to_f
      if z == 0.0
        counters[:uv_q0_vertices] += 1
        return [0, 0]
      end
      u = uvq.x.to_f / z
      w = uvq.y.to_f / z
      return %w[NaN NaN] unless u.finite? && w.finite?

      [grid(u.round(9)), grid(w.round(9))]
    end

    def skp_t16(transformation)
      a = transformation.to_a
      raise ModelTruthError, 'transform_size' unless a.size == 16

      (0...16).map do |i|
        if i >= 12 && i <= 14
          grid((a[i].to_f * INCH_M).round(9))
        else
          skp_unit(a[i])
        end
      end
    end

    def bomc_t16(matrix)
      raise ModelTruthError, 'transform_size' unless matrix.size == 16

      matrix.map { |v| grid(v) }
    end

    def float_hex(v)
      [v.to_f].pack('G').unpack1('H*')
    end

    # ---- strings -----------------------------------------------------------

    def utf8!(s)
      return nil if s.nil?

      out = s.dup.force_encoding(Encoding::UTF_8)
      raise ModelTruthError, 'invalid_utf8' unless out.valid_encoding?

      out
    end

    def model_key(name)
      name.gsub(/[^A-Za-z0-9._-]+/, '_')
    end

    # ---- canonical items ---------------------------------------------------

    # Among the rotations of the loop that start at a vertex whose [x, y, z] is
    # the lexicographic minimum, the smallest whole-tuple sequence. Winding kept.
    def rotate_loop(tuples)
      raise ModelTruthError, 'loop_too_short' if tuples.length < 3

      min_pos = tuples.map { |t| t[0, 3] }.min
      best = nil
      tuples.each_with_index do |t, k|
        next unless t[0, 3] == min_pos

        cand = tuples[k..-1] + tuples[0...k]
        if best.nil?
          best = cand
          next
        end
        # Array#<=> is nil when a non-finite UV marker ('NaN') meets an Integer;
        # fall back to the canonical string so both sides still pick the same one.
        c = (cand <=> best)
        c = (canon_json(cand) <=> canon_json(best)) if c.nil?
        best = cand if c < 0
      end
      best
    end

    def face_item(front:, back:, tag:, hidden:, normal:, outer:, holes:, triangles:, uv_front:, uv_back:)
      [
        'F', front, back, tag, hidden ? true : false, normal,
        rotate_loop(outer),
        holes.map { |h| rotate_loop(h) }.sort_by { |h| canon_json(h) },
        triangles.map { |t| rotate_loop(t) }.sort_by { |t| canon_json(t) },
        [uv_front ? true : false, uv_back ? true : false]
      ]
    end

    def edge_item(tag:, hidden:, soft:, smooth:, a:, b:)
      ['E', tag, hidden ? true : false, soft ? true : false, smooth ? true : false, [a, b].sort]
    end

    def instance_local_item(kind:, t16:, material:, tag:)
      ['I', kind, t16, material, tag]
    end

    def instance_merkle_item(local, child_digest)
      ['J', local[1], local[2], local[3], local[4], child_digest]
    end

    def image_item(t16:, tag:)
      ['G', t16, tag]
    end

    def text_item(text:, point:, tag:)
      ['X', text, point, tag]
    end

    # ---- serialisation and digests ----------------------------------------

    def canon_json(value)
      out = []
      canon_write(value, out)
      out.join.force_encoding(Encoding::UTF_8)
    end

    def item_json(item)
      canon_json(item)
    end

    def canon_write(value, out)
      case value
      when nil then out << 'null'
      when true then out << 'true'
      when false then out << 'false'
      when Integer then out << value.to_s
      when String
        s = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
        raise ModelTruthError, 'non_canonical_item' unless s.valid_encoding?

        out << '"'
        out << s.gsub(/["\\\x00-\x1f]/) do |ch|
          case ch
          when '"' then '\\"'
          when '\\' then '\\\\'
          else format('\\u%04x', ch.ord)
          end
        end
        out << '"'
      when Array
        out << '['
        value.each_with_index do |element, i|
          out << ',' if i > 0
          canon_write(element, out)
        end
        out << ']'
      else
        raise ModelTruthError, 'non_canonical_item'
      end
    end

    def sha_hex(str)
      Digest::SHA256.hexdigest(str)
    end

    # Order-independent multiset digest: count and the sum of item SHA-256
    # values modulo 2**256. Constant memory.
    class MSet
      def initialize
        @n = 0
        @s = 0
      end

      def add(json)
        @n += 1
        @s = (@s + Canonical.sha_hex(json).to_i(16)) % MOD
      end

      def count
        @n
      end

      def to_a
        [@n, format('%064x', @s)]
      end
    end

    def mset_pair(x)
      x.respond_to?(:to_a) && !x.is_a?(Array) ? x.to_a : x
    end

    # Returns [local_digest, digest].
    def definition_digests(kind, faces, edges, images, texts, inst_local, inst_merkle)
      local = sha_hex(canon_json(['L', kind, mset_pair(faces), mset_pair(edges), mset_pair(images), mset_pair(texts), mset_pair(inst_local)]))
      digest = sha_hex(canon_json(['D', local, mset_pair(inst_merkle)]))
      [local, digest]
    end

    # ---- pixels ------------------------------------------------------------

    # Canonical pixel form: RGBA8, row-major, top-down, no padding, R,G,B,A.
    # Streams per row into SHA-256; yields (row index) after each row.
    def canonical_rgba_sha(width:, height:, bits_per_pixel:, row_padding:, data:, keep: false, platform: :auto)
      if platform == :auto
        raise PixelError, 'unsupported_platform' unless RUBY_PLATFORM =~ /mswin|mingw/
      elsif platform != :win
        raise PixelError, 'unsupported_platform'
      end
      raise PixelError, 'unsupported_bpp' unless [24, 32].include?(bits_per_pixel)

      channels = bits_per_pixel / 8
      stride = width * channels + row_padding
      raise PixelError, 'short_data' if data.bytesize < stride * height

      sha = Digest::SHA256.new
      kept = keep ? String.new : nil
      kept&.force_encoding(Encoding::BINARY)
      row_bytes = width * channels
      height.times do |y|
        row = data.byteslice(y * stride, row_bytes)
        out =
          if channels == 4
            row.unpack('V*').map { |v| (v & 0xff00ff00) | ((v & 0xff) << 16) | ((v >> 16) & 0xff) }.pack('V*')
          else
            b = row.unpack('C*')
            rgba = Array.new(width * 4)
            width.times do |x|
              rgba[x * 4] = b[x * 3 + 2]
              rgba[x * 4 + 1] = b[x * 3 + 1]
              rgba[x * 4 + 2] = b[x * 3]
              rgba[x * 4 + 3] = 255
            end
            rgba.pack('C*')
          end
        sha.update(out)
        kept << out if keep
        yield y if block_given?
      end
      { sha256: sha.hexdigest, bytes: kept, width: width, height: height, bpp: bits_per_pixel, row_padding: row_padding }
    end

    def parse_pam(bytes)
      b = bytes.b
      raise PixelError, 'pam_invalid' unless b.start_with?("P7\n")

      idx = b.index("ENDHDR\n")
      raise PixelError, 'pam_invalid' unless idx

      header = b[0, idx].split("\n")
      fields = {}
      header[1..-1].each do |line|
        k, v = line.split(' ', 2)
        fields[k] = v
      end
      w = Integer(fields['WIDTH'], 10) rescue nil # rubocop:disable Style/RescueModifier
      h = Integer(fields['HEIGHT'], 10) rescue nil # rubocop:disable Style/RescueModifier
      unless w && h && w > 0 && h > 0 && fields['DEPTH'] == '4' && fields['MAXVAL'] == '255' && fields['TUPLTYPE'] == 'RGB_ALPHA'
        raise PixelError, 'pam_invalid'
      end

      data = b.byteslice(idx + 7, b.bytesize)
      raise PixelError, 'pam_invalid' unless data.bytesize == w * h * 4

      { width: w, height: h, rgba: data }
    end

    # Accepts only a RIFF/WEBP file holding exactly one lossless VP8L chunk.
    def webp_container!(bytes)
      b = bytes.b
      raise PixelError, 'webp_not_riff' unless b.bytesize >= 20 && b.byteslice(0, 4) == 'RIFF' && b.byteslice(8, 4) == 'WEBP'
      raise PixelError, 'webp_size_mismatch' unless b.byteslice(4, 4).unpack1('V') + 8 == b.bytesize

      fourcc = b.byteslice(12, 4)
      raise PixelError, 'webp_extended_container' if fourcc == 'VP8X'
      raise PixelError, 'webp_lossy' if fourcc == 'VP8 '
      raise PixelError, 'webp_unexpected_chunks' unless fourcc == 'VP8L'

      cs = b.byteslice(16, 4).unpack1('V')
      raise PixelError, 'webp_unexpected_chunks' unless 20 + cs + (cs.odd? ? 1 : 0) == b.bytesize

      :vp8l_simple
    end
  end
end
