# frozen_string_literal: true

# SIB-R1-ITCON-001 ModelTruth comparator (plain Ruby, agent-run).
# Reads one run directory (bomc/ and skp/ captures) and writes
# model-truth-diff.json. Verdicts come only from digests and table rules
# (plan D26/D27); the pairing/diagnosis of D30 never changes a verdict.

require 'digest'
require 'json'
require 'set'
require 'time'
require 'zlib'
require_relative 'canonical'
require_relative '../../bom_engine/bomc_jpeg_color_map'

module SibamboModelTruthV1
  module Compare
    GEOMETRY_CATEGORIES = %w[faces edges instances images texts].freeze
    MSET_FIELD = { 'faces' => 'faces', 'edges' => 'edges', 'instances' => 'inst_local', 'images' => 'images', 'texts' => 'texts' }.freeze
    CODE = { 'faces' => 'F', 'edges' => 'E', 'instances' => 'I', 'images' => 'G', 'texts' => 'X' }.freeze
    CATEGORY_ORDER = %w[definitions faces edges instances images texts materials tags textures_pixels textures_colorize].freeze
    MAX_MISMATCHES = 20
    MAX_PAIRS = 50
    SHOW_CHARS = 240

    module_function

    def read_json(path)
      JSON.parse(File.read(path))
    end

    def read_ndjson(path)
      File.readlines(path).map { |l| JSON.parse(l) }
    end

    def show(value)
      s =
        if value.is_a?(String)
          value
        else
          begin
            Canonical.canon_json(value)
          rescue StandardError
            value.inspect
          end
        end
      s.length > SHOW_CHARS ? "#{s[0, SHOW_CHARS]}..." : s
    end

    # -------------------------------------------------------------- entry
    def run(run_dir:)
      out_path = File.join(run_dir, 'model-truth-diff.json')
      diff = build(run_dir)
      File.open(out_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) { |f| f.write(JSON.pretty_generate(diff)) }
      diff
    end

    def error_diff(run_dir, reason)
      { schema: Canonical::SCHEMA, run_id: File.basename(run_dir.to_s.tr('\\', '/')), generated_at: Time.now.utc.iso8601,
        overall: 'ERROR', error: reason, categories: [], not_run: [], excluded: [] }
    end

    def build(run_dir)
      bpath = File.join(run_dir, 'bomc', 'manifest.json')
      spath = File.join(run_dir, 'skp', 'manifest.json')
      return error_diff(run_dir, 'manifest_missing') unless File.file?(bpath) && File.file?(spath)

      bm = read_json(bpath)
      sm = read_json(spath)
      return error_diff(run_dir, 'manifest_incomplete') unless bm['complete'] == true && sm['complete'] == true
      return error_diff(run_dir, 'schema_mismatch') unless bm['schema'] == sm['schema'] && bm['schema'] == Canonical::SCHEMA
      return error_diff(run_dir, 'input_mismatch') unless bm.dig('inputs', 'skp_sha256') == sm.dig('inputs', 'skp_sha256')
      return error_diff(run_dir, 'tool_version_mismatch') unless bm.dig('tools', 'canonical_rb_sha256') == sm.dig('tools', 'canonical_rb_sha256')

      bdir = File.join(run_dir, 'bomc')
      sdir = File.join(run_dir, 'skp')
      brecs = read_ndjson(File.join(bdir, 'definitions.ndjson'))
      srecs = read_ndjson(File.join(sdir, 'definitions.ndjson'))
      btab = read_json(File.join(bdir, 'tables.json'))
      stab = read_json(File.join(sdir, 'tables.json'))
      bdiag = read_json(File.join(bdir, 'diagnostics.json'))
      sexc = read_json(File.join(sdir, 'exclusions.json'))

      geo = geometry(run_dir, bm, sm, brecs, srecs)
      cats = {}
      geo[:categories].each { |c| cats[c[:category]] = c }
      cats['materials'] = materials_category(stab, btab)
      cats['tags'] = tags_category(stab, btab)
      tex = textures_categories(run_dir, stab, btab)
      cats['textures_pixels'] = tex[:pixels]
      cats['textures_colorize'] = tex[:colorize]
      categories = CATEGORY_ORDER.map { |n| cats.fetch(n) }

      images_skp = srecs.sum { |r| r['counts']['images'] }
      not_run = [{ category: 'image_pixels', reason: 'D22', skpCount: images_skp }]
      overall = categories.all? { |c| c[:verdict] == 'PASS' } ? 'PASS' : 'FAIL'
      sc = sexc['counters']

      {
        schema: Canonical::SCHEMA, model: bm['model'], model_key: bm['model_key'], run_id: bm['run_id'],
        generated_at: Time.now.utc.iso8601,
        inputs: { skp_sha256: bm.dig('inputs', 'skp_sha256'), bomc_sha256: bm.dig('inputs', 'bomc_sha256'), producer_pin: bm.dig('inputs', 'producer_pin') },
        overall: overall,
        root: { skp: sm['root_digest'], bomc: bm['root_digest'], equal: sm['root_digest'] == bm['root_digest'] },
        definitions_multiset_equal: geo[:defs_equal],
        categories: categories,
        not_run: not_run,
        excluded: excluded_list(sexc, bdiag),
        disclosures: { uv_q0_vertices: sc['uv_q0_vertices'], non_triangle_polygons: sc['non_triangle_polygons'], deleted_skipped: sc['deleted_skipped'],
                       inherited_paint_exposure: bdiag['inherited_paint_exposure'] },
        diagnostics: geo[:diagnostics].merge(texture_info: tex[:info].first(MAX_PAIRS), texture_info_count: tex[:info].length),
        runtime: { bomc_side_s: bm.dig('timings_s', 'total'), skp_side_s: sm.dig('runtime', 'duration_s'),
                   skp_max_ruby_slice_ms: sm.dig('runtime', 'max_ruby_slice_ms'), skp_max_native_call_ms: sm.dig('runtime', 'max_native_call_ms'),
                   skp_max_native_call_label: sm.dig('runtime', 'max_native_call_label'), skp_max_tick_gap_ms: sm.dig('runtime', 'max_tick_gap_ms') }
      }
    end

    def excluded_list(sexc, bdiag)
      sc = sexc['counters']
      list = [
        { scope: 'edge_materials', reason: 'D22: BOMC stores no edge material', skpCount: sc['edges_with_material'], bomcCount: 0 },
        { scope: 'text_without_point', reason: 'D22: producer skips texts without a point', skpCount: sc['texts_without_point'], bomcCount: 0 },
        { scope: 'unreachable_definitions', reason: 'D22: producer exports only reachable definitions', skpCount: sc['unreachable_definitions'], bomcCount: bdiag['unreachable_definitions_bomc'] },
        { scope: 'instance_visible_flag', reason: 'D22: derived scene visibility (SceneTruth scope)', skpCount: nil, bomcCount: nil },
        { scope: 'instance_and_definition_names', reason: 'D22: producer-defined naming', skpCount: nil, bomcCount: nil },
        { scope: 'producer_semantics', reason: 'D22: fallback flag, surface_type, semantic_role, semantic_label have no SketchUp counterpart',
          skpCount: nil, bomcCount: { fallback_faces: bdiag['fallback_faces'], fallback_instances: bdiag['fallback_instances'] } },
        { scope: 'scenes_cameras_clip_planes', reason: 'D22: SceneTruth scope', skpCount: nil, bomcCount: nil },
        { scope: 'inherited_paint_uv', reason: 'D21/D22: viewer behaviour; BOMC-side exposure count', skpCount: nil, bomcCount: bdiag['inherited_paint_exposure'] },
        { scope: 'face_area', reason: 'D22: derived from compared positions and triangles', skpCount: nil, bomcCount: nil }
      ]
      sexc['excluded'].sort.each { |klass, n| list << { scope: "entity_class:#{klass}", reason: 'D22: producer does not export this class', skpCount: n, bomcCount: 0 } }
      list
    end

    # --------------------------------------------------------------- geometry
    def sum_counts(recs, key)
      recs.sum { |r| r['counts'][key] }
    end

    def matched_counts(srecs, brecs, key)
      by = Hash.new { |h, k| h[k] = [] }
      brecs.each { |r| by[r['digest']] << r }
      sb = Hash.new(0)
      total = 0
      srecs.each do |r|
        d = r['digest']
        next if sb[d] >= by[d].length

        sb[d] += 1
        total += r['counts'][key]
      end
      total
    end

    def geometry(run_dir, bm, sm, brecs, srecs)
      root_equal = bm['root_digest'] == sm['root_digest']
      defs_equal = srecs.map { |r| r['digest'] }.sort == brecs.map { |r| r['digest'] }.sort
      unreachable = bm['unreachable_definitions_bomc'].to_i
      if root_equal && defs_equal && unreachable.zero?
        cats = (['definitions'] + GEOMETRY_CATEGORIES).map do |name|
          if name == 'definitions'
            { category: name, verdict: 'PASS', skpCount: srecs.length, bomcCount: brecs.length, matches: srecs.length, firstMismatches: [] }
          else
            n = sum_counts(srecs, name)
            { category: name, verdict: 'PASS', skpCount: n, bomcCount: sum_counts(brecs, name), matches: n, firstMismatches: [] }
          end
        end
        return { defs_equal: defs_equal, categories: cats,
                 diagnostics: { definition_pairs: [], propagated_count: 0, unpaired: { skp: [], bomc: [] } } }
      end

      diag = diagnose(run_dir, srecs, brecs)
      failing = diag[:failing_categories]
      cats = (['definitions'] + GEOMETRY_CATEGORIES).map do |name|
        if name == 'definitions'
          mism = diag[:definition_mismatches].first(MAX_MISMATCHES)
          mism = [{ field: 'root_digest', skp: sm['root_digest'], bomc: bm['root_digest'] }] + mism.first(MAX_MISMATCHES - 1) unless root_equal
          mism = [{ field: 'unreachable_definitions_bomc', skp: 0, bomc: unreachable }] + mism.first(MAX_MISMATCHES - 1) if unreachable.positive?
          { category: name, verdict: 'FAIL', skpCount: srecs.length, bomcCount: brecs.length,
            matches: srecs.length - diag[:unmatched_skp], firstMismatches: mism }
        else
          { category: name, verdict: failing.include?(name) ? 'FAIL' : 'PASS', skpCount: sum_counts(srecs, name), bomcCount: sum_counts(brecs, name),
            matches: matched_counts(srecs, brecs, name), firstMismatches: diag[:item_mismatches][name].first(MAX_MISMATCHES) }
        end
      end
      { defs_equal: defs_equal, categories: cats,
        diagnostics: { definition_pairs: diag[:pairs].first(MAX_PAIRS), propagated_count: diag[:propagated],
                       unpaired: { skp: diag[:unpaired_skp].first(MAX_PAIRS), bomc: diag[:unpaired_bomc].first(MAX_PAIRS) } } }
    end

    # D30: diagnostic pairing. Never changes a verdict.
    def diagnose(run_dir, srecs, brecs)
      sby = srecs.group_by { |r| r['digest'] }
      bby = brecs.group_by { |r| r['digest'] }
      s_un = []
      b_un = []
      (sby.keys | bby.keys).each do |d|
        a = sby[d] || []
        b = bby[d] || []
        if a.length > b.length
          s_un.concat(a.sort_by { |r| r['dfs'] }.last(a.length - b.length))
        elsif b.length > a.length
          b_un.concat(b.sort_by { |r| r['dfs'] }.last(b.length - a.length))
        end
      end
      s_un.sort_by! { |r| r['dfs'] }
      b_un.sort_by! { |r| r['dfs'] }
      unmatched_skp = s_un.length

      pairs = []
      s_left = s_un.dup
      b_left = b_un.dup
      s_un.each do |s|
        b = b_left.find { |x| x['dfs'] == s['dfs'] && x['kind'] == s['kind'] }
        next unless b

        pairs << [s, b]
        s_left.delete(s)
        b_left.delete(b)
      end
      cand = []
      s_left.each do |s|
        b_left.each do |b|
          next unless b['kind'] == s['kind']

          cost = %w[faces edges instances].sum { |k| (s['counts'][k] - b['counts'][k]).abs }
          cand << [cost, s['dfs'], b['dfs'], s, b]
        end
      end
      cand.sort_by! { |c| [c[0], c[1], c[2]] }
      used_s = {}
      used_b = {}
      cand.each do |_cost, _sd, _bd, s, b|
        next if used_s[s['dfs']] || used_b[b['dfs']]

        used_s[s['dfs']] = true
        used_b[b['dfs']] = true
        pairs << [s, b]
      end
      unpaired_skp = s_left.reject { |s| used_s[s['dfs']] }
      unpaired_bomc = b_left.reject { |b| used_b[b['dfs']] }
      pairs.sort_by! { |s, b| [s['dfs'], b['dfs']] }

      failing = Set.new
      item_mism = Hash.new { |h, k| h[k] = [] }
      GEOMETRY_CATEGORIES.each { |c| item_mism[c] }
      pair_rows = []
      propagated = 0
      local_pairs = []
      pairs.each do |s, b|
        local = GEOMETRY_CATEGORIES.select { |cat| s[MSET_FIELD[cat]] != b[MSET_FIELD[cat]] }
        if local.empty?
          propagated += 1 if s['local_digest'] == b['local_digest']
        else
          local.each { |c| failing << c }
          local_pairs << [s, b, local]
        end
        pair_rows << { skp_dfs: s['dfs'], bomc_dfs: b['dfs'], kind: s['kind'], local_categories: local, propagated: local.empty? && s['local_digest'] == b['local_digest'] }
      end
      (unpaired_skp.map { |r| [r, 'skp'] } + unpaired_bomc.map { |r| [r, 'bomc'] }).each do |r, _side|
        GEOMETRY_CATEGORIES.each { |c| failing << c if r['counts'][c].to_i.positive? }
      end

      def_mism = []
      unpaired_skp.each { |r| def_mism << { field: 'definition_unpaired', side: 'skp', dfs: r['dfs'], kind: r['kind'] } }
      unpaired_bomc.each { |r| def_mism << { field: 'definition_unpaired', side: 'bomc', dfs: r['dfs'], kind: r['kind'] } }
      pairs.each do |s, b|
        def_mism << { field: 'definition_digest', skp_dfs: s['dfs'], bomc_dfs: b['dfs'], kind: s['kind'] }
      end

      item_diff(run_dir, local_pairs, item_mism) unless local_pairs.empty?
      item_mism.each_value { |list| list.sort_by! { |m| [m[:skp_dfs] || m[:bomc_dfs] || 0, m[:sort_key].to_s] } }
      item_mism.each_value { |list| list.each { |m| m.delete(:sort_key) } }

      { failing_categories: failing, item_mismatches: item_mism, definition_mismatches: def_mism, unmatched_skp: unmatched_skp,
        pairs: pair_rows, propagated: propagated, unpaired_skp: unpaired_skp.map { |r| r['dfs'] }, unpaired_bomc: unpaired_bomc.map { |r| r['dfs'] } }
    end

    def load_items(path, wanted)
      by = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
      return by if wanted.empty?

      Zlib::GzipReader.open(path) do |gz|
        gz.each_line do |line|
          rec = JSON.parse(line)
          next unless wanted.include?(rec['d'])

          by[rec['d']][rec['c']] << rec['i']
        end
      end
      by
    end

    def pos_only(tuples)
      tuples.map { |t| t[0, 3] }
    end

    def pairing_key(cat, item)
      case cat
      when 'faces'
        Canonical.canon_json([pos_only(item[6]).sort, item[7].map { |h| pos_only(h).sort }.sort_by { |h| Canonical.canon_json(h) }])
      when 'edges' then Canonical.canon_json(item[5])
      when 'instances' then Canonical.canon_json([item[1], item[2]])
      when 'images' then Canonical.canon_json(item[1])
      when 'texts' then Canonical.canon_json(item[2])
      end
    end

    def uv_lists(item)
      flags = item[9]
      front = []
      back = []
      ([item[6]] + item[7]).each do |lp|
        lp.each do |t|
          off = 3
          if flags[0]
            front << t[off, 2]
            off += 2
          end
          back << t[off, 2] if flags[1]
        end
      end
      [front, back]
    end

    def field_diffs(cat, s, b)
      diffs = []
      add = ->(field, sv, bv) { diffs << [field, sv, bv] unless sv == bv }
      case cat
      when 'faces'
        add.call('outer_positions', pos_only(s[6]), pos_only(b[6]))
        add.call('hole_positions', s[7].map { |h| pos_only(h) }, b[7].map { |h| pos_only(h) })
        add.call('uv_presence', s[9], b[9])
        if s[9] == b[9]
          sf, sb = uv_lists(s)
          bf, bb = uv_lists(b)
          add.call('uv_front', sf, bf)
          add.call('uv_back', sb, bb)
        end
        add.call('front_material', s[1], b[1])
        add.call('back_material', s[2], b[2])
        add.call('tag', s[3], b[3])
        add.call('hidden', s[4], b[4])
        add.call('normal', s[5], b[5])
        add.call('triangles', s[8], b[8])
      when 'edges'
        add.call('tag', s[1], b[1])
        add.call('hidden', s[2], b[2])
        add.call('soft', s[3], b[3])
        add.call('smooth', s[4], b[4])
      when 'instances'
        add.call('material', s[3], b[3])
        add.call('tag', s[4], b[4])
      when 'images'
        add.call('tag', s[2], b[2])
      when 'texts'
        add.call('text', s[1], b[1])
        add.call('tag', s[3], b[3])
      end
      diffs
    end

    def item_diff(run_dir, local_pairs, item_mism)
      swant = Set.new(local_pairs.map { |s, _b, _l| s['dfs'] })
      bwant = Set.new(local_pairs.map { |_s, b, _l| b['dfs'] })
      sitems = load_items(File.join(run_dir, 'skp', 'items.ndjson.gz'), swant)
      bitems = load_items(File.join(run_dir, 'bomc', 'items.ndjson.gz'), bwant)
      local_pairs.each do |s, b, local|
        local.each do |cat|
          code = CODE[cat]
          sl = sitems[s['dfs']][code].map { |i| [Canonical.canon_json(i), i] }
          bl = bitems[b['dfs']][code].map { |i| [Canonical.canon_json(i), i] }
          scount = Hash.new(0)
          bcount = Hash.new(0)
          sl.each { |j, _| scount[j] += 1 }
          bl.each { |j, _| bcount[j] += 1 }
          s_left = []
          b_left = []
          seen = Hash.new(0)
          sl.each do |j, i|
            seen[j] += 1
            s_left << [j, i] if seen[j] > bcount[j]
          end
          seen = Hash.new(0)
          bl.each do |j, i|
            seen[j] += 1
            b_left << [j, i] if seen[j] > scount[j]
          end
          s_left.sort_by!(&:first)
          b_left.sort_by!(&:first)
          bkeys = Hash.new { |h, k| h[k] = [] }
          b_left.each { |j, i| bkeys[pairing_key(cat, i)] << [j, i] }
          s_left.each do |j, i|
            cand = bkeys[pairing_key(cat, i)].shift
            if cand
              field_diffs(cat, i, cand[1]).each do |field, sv, bv|
                item_mism[cat] << { skp_dfs: s['dfs'], bomc_dfs: b['dfs'], field: field, skp: show(sv), bomc: show(bv), sort_key: j }
              end
              b_left.delete_if { |bj, _| bj.equal?(cand[0]) }
            else
              item_mism[cat] << { skp_dfs: s['dfs'], bomc_dfs: b['dfs'], field: 'missing_in_bomc', item: show(j), sort_key: j }
            end
          end
          b_left.each { |j, _i| item_mism[cat] << { skp_dfs: s['dfs'], bomc_dfs: b['dfs'], field: 'extra_in_bomc', item: show(j), sort_key: j } }
        end
      end
    end

    # --------------------------------------------------------- tables, textures
    def hex_float(h)
      [h].pack('H*').unpack1('G')
    end

    def materials_category(stab, btab)
      smats = stab['materials']
      bmats = btab['materials']
      btex = btab['textures']
      bby = bmats.each_with_object({}) { |m, h| h[m['name']] = m }
      sby = smats.each_with_object({}) { |m, h| h[m['name']] = m }
      mism = []
      matches = 0
      smats.each do |s|
        b = bby[s['name']]
        unless b
          mism << { name: s['name'], field: 'presence', skp: true, bomc: false }
          next
        end
        before = mism.length
        mism << { name: s['name'], field: 'color', skp: s['color'], bomc: b['color'] } unless s['color'] == b['color']
        skp_alpha = hex_float(s['alpha_hex']) * 65_535
        mism << { name: s['name'], field: 'opacity', skp: skp_alpha, bomc: b['opacity_u16'] } unless (b['opacity_u16'] - skp_alpha).abs <= 0.6
        mism << { name: s['name'], field: 'material_type', skp: s['material_type'], bomc: b['material_type'] } unless s['material_type'] == b['material_type']
        st = s['texture']
        if st.nil? != b['texture_index'].nil?
          mism << { name: s['name'], field: 'texture_presence', skp: !st.nil?, bomc: !b['texture_index'].nil? }
        elsif st
          { 'width' => ['width_m_hex', 'texture_width_m_hex'], 'height' => ['height_m_hex', 'texture_height_m_hex'] }.each do |label, (sk, bk)|
            sm = hex_float(st[sk])
            bmv = b[bk].nil? ? nil : hex_float(b[bk])
            ok = !bmv.nil? && (bmv - sm).abs <= [1e-9, sm.abs * 2**-23].max
            mism << { name: s['name'], field: "texture_#{label}_m", skp: sm, bomc: bmv } unless ok
          end
          row = btex[b['texture_index']]
          if row.nil?
            mism << { name: s['name'], field: 'texture_row', skp: true, bomc: nil }
          else
            mism << { name: s['name'], field: 'image_width', skp: st['image_width'], bomc: row['width_px'] } unless st['image_width'] == row['width_px']
            mism << { name: s['name'], field: 'image_height', skp: st['image_height'], bomc: row['height_px'] } unless st['image_height'] == row['height_px']
          end
        end
        matches += 1 if mism.length == before
      end
      bmats.each { |b| mism << { name: b['name'], field: 'presence', skp: false, bomc: true } unless sby.key?(b['name']) }
      { category: 'materials', verdict: mism.empty? ? 'PASS' : 'FAIL', skpCount: smats.length, bomcCount: bmats.length, matches: matches,
        firstMismatches: mism.first(MAX_MISMATCHES) }
    end

    def tags_category(stab, btab)
      sby = stab['tags'].each_with_object({}) { |t, h| h[t['name']] = t }
      bby = btab['tags'].each_with_object({}) { |t, h| h[t['name']] = t }
      mism = []
      matches = 0
      stab['tags'].each do |s|
        b = bby[s['name']]
        if b.nil?
          mism << { name: s['name'], field: 'presence', skp: true, bomc: false }
        elsif b['visible'] != s['visible']
          mism << { name: s['name'], field: 'visible', skp: s['visible'], bomc: b['visible'] }
        else
          matches += 1
        end
      end
      btab['tags'].each { |b| mism << { name: b['name'], field: 'presence', skp: false, bomc: true } unless sby.key?(b['name']) }
      { category: 'tags', verdict: mism.empty? ? 'PASS' : 'FAIL', skpCount: stab['tags'].length, bomcCount: btab['tags'].length, matches: matches,
        firstMismatches: mism.first(MAX_MISMATCHES) }
    end

    def bomc_pixel(run_dir, row, skp_pix)
      pixel = row['pixel']
      return { status: 'FAIL', code: 'pixels_missing' } if pixel.nil?
      return pixel if pixel['status'] == 'FAIL'

      case row['media_type']
      when 'webp'
        pixel['status'] == 'OK' ? { status: 'OK', sha256: pixel['sha256'] } : { status: 'FAIL', code: 'pixels_missing' }
      when 'jpeg', 'png'
        rec = skp_pix[row['index']]
        return { status: 'FAIL', code: 'pixels_missing' } if rec.nil?
        return { status: 'FAIL', code: rec['code'] || 'bomc_imagerep_load_error' } unless rec['status'] == 'OK'
        return { status: 'FAIL', code: 'dimension_mismatch' } unless rec['width'] == row['width_px'] && rec['height'] == row['height_px']

        { status: 'OK', sha256: rec['sha256'] }
      when 'jpeg_color_map'
        base = File.join(run_dir, 'skp', 'jcm-base', "#{row['index']}.rgba")
        return { status: 'FAIL', code: 'pixels_missing' } unless File.file?(base) && skp_pix[row['index']] && skp_pix[row['index']]['status'] == 'OK'

        begin
          out = BOMEngine::BOMCJpegColorMap.reconstruct(File.binread(File.join(run_dir, 'bomc', 'textures', "#{row['index']}.jcm")), File.binread(base))
          { status: 'OK', sha256: Digest::SHA256.hexdigest(out) }
        rescue ArgumentError
          { status: 'FAIL', code: 'jcm_reconstruct_error' }
        end
      else
        { status: 'FAIL', code: 'unsupported_media' }
      end
    end

    def textures_categories(run_dir, stab, btab)
      pix_path = File.join(run_dir, 'skp', 'bomc-texture-pixels.ndjson')
      skp_pix = File.file?(pix_path) ? read_ndjson(pix_path).each_with_object({}) { |r, h| h[r['index']] = r } : {}
      bmats = btab['materials'].each_with_object({}) { |m, h| h[m['name']] = m }
      btex = btab['textures']
      pmism = []
      cmism = []
      info = []
      pmatch = 0
      cmatch = 0
      ccount = 0
      skp_textured = stab['materials'].select { |m| m['texture'] }
      skp_textured.each do |s|
        name = s['name']
        b = bmats[name]
        if b.nil? || b['texture_index'].nil?
          pmism << { name: name, field: 'texture_missing' }
          next
        end
        row = btex[b['texture_index']]
        bp = bomc_pixel(run_dir, row, skp_pix)
        if bp[:status] != 'OK'
          pmism << { name: name, field: bp[:code] }
          next
        end
        ref = s['pixels']
        if ref.nil? || ref['status'] == 'FAIL'
          pmism << { name: name, field: (ref && ref['code']) || 'skp_pixels_missing' }
          next
        end
        semantic = b['semantic_colorize_active']
        needed_flag = semantic ? 'false' : 'true'
        side = ref[needed_flag]
        # The side D27 does not use for this material may fail without failing the
        # category (review F1); it is reported as info. The needed side stays strict.
        ref.each do |flag, v|
          next if flag == needed_flag || v.nil? || v['status'] != 'FAIL'

          info << { name: name, field: 'unneeded_side_failed', flag: flag, code: v['code'], bits_per_pixel: v['bits_per_pixel'], severity: 'info' }
        end
        if side.nil? || side['status'] == 'FAIL'
          pmism << { name: name, field: (side && side['code']) || 'skp_pixels_missing', flag: needed_flag, bits_per_pixel: side && side['bits_per_pixel'] }
          if semantic
            ccount += 1
            cmism << { name: name, field: 'colorize_base_unavailable', flag: needed_flag }
          end
          next
        end
        if side['width'] != row['width_px'] || side['height'] != row['height_px']
          pmism << { name: name, field: 'dimension_mismatch', skp: [side['width'], side['height']], bomc: [row['width_px'], row['height_px']] }
        elsif side['sha256'] != bp[:sha256]
          pmism << { name: name, field: 'pixel_sha256', skp: side['sha256'], bomc: bp[:sha256], reference: semantic ? 'image_rep(false)' : 'image_rep(true)' }
        else
          pmatch += 1
        end
        next unless semantic

        ccount += 1
        before = cmism.length
        if ref['true'].nil? || ref['true']['status'] == 'FAIL'
          cmism << { name: name, field: 'colorize_output_unavailable', flag: 'true', code: ref['true'] && ref['true']['code'] }
          next
        end
        cmism << { name: name, field: 'colorize_output_sha256', skp: ref['true']['sha256'], bomc: b['colorize_output_sha256'] } unless b['colorize_output_sha256'] == ref['true']['sha256']
        cmism << { name: name, field: 'colorize_type', skp: s['colorize_type'], bomc: b['colorize_type'] } unless b['colorize_type'] == s['colorize_type']
        cmism << { name: name, field: 'colorize_deltas', skp: s['colorize_deltas_hex'], bomc: b['colorize_deltas_hex'] } unless b['colorize_deltas_hex'] == s['colorize_deltas_hex']
        cmatch += 1 if cmism.length == before
      end
      bomc_textured = btab['materials'].count { |m| m['texture_index'] }
      {
        pixels: { category: 'textures_pixels', verdict: pmism.empty? ? 'PASS' : 'FAIL', skpCount: skp_textured.length, bomcCount: bomc_textured,
                  matches: pmatch, firstMismatches: pmism.first(MAX_MISMATCHES) },
        colorize: { category: 'textures_colorize', verdict: cmism.empty? ? 'PASS' : 'FAIL', skpCount: ccount,
                    bomcCount: btab['materials'].count { |m| m['semantic_colorize_active'] }, matches: cmatch, firstMismatches: cmism.first(MAX_MISMATCHES) },
        info: info
      }
    end
  end
end
