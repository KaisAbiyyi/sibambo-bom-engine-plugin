# frozen_string_literal: true

# SIB-R1-ITCON-001 ModelTruth, BOMC side (plain Ruby, agent-run).
# Turns one Exact BOMC file into canonical, order-independent outputs that the
# comparator can match against the SketchUp side. Never modifies its input.

require 'digest'
require 'fileutils'
require 'json'
require 'zlib'
require_relative 'canonical'
require_relative '../../bom_engine/bomc_decoder'
require_relative '../../bom_engine/decode_budget'
require_relative '../../bom_engine/bomc_jpeg_color_map'

module SibamboModelTruthV1
  module BomcSide
    PRODUCER_PIN = '7448f3e67bd24a37f1619f625991b3304347094cd13cf5c003a347097f9ac3de' # M09 candidate-only (plan SIB-R1-ITCON-001-WP2-M09-NATIVE N-D3); historical D4 pin 3f2d314a... stays on feat/sib-r1-model-truth-001
    DWEBP_SHA256 = '17c1488bf84b7834e9aa908bb40afd0be2e55d57567d210e96336c56bb6ae993'
    FFMPEG_SHA256 = 'b2663834d9162f6ee431e7d864d8afd7ac385ec289de70463af67beab6f2257e'
    DECODER_TIMEOUT_S = 300
    MAX_DEPTH = 64
    KIND_MAP = { 'model_definition' => 'root', 'group_definition' => 'group', 'component_definition' => 'component' }.freeze
    TEXTURE_EXT = { 'jpeg' => 'jpg', 'png' => 'png', 'webp' => 'webp', 'jpeg_color_map' => 'jcm' }.freeze

    module_function

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def jline(hash)
      JSON.generate(hash) + "\n"
    end

    # ------------------------------------------------------------------------
    # Pure core: hand-built or decoded Hash -> canonical items (to `writer`),
    # definition records, counts and diagnostics. `writer` responds to #write.
    # ------------------------------------------------------------------------
    def core(decoded, writer:)
      c = Canonical
      materials = decoded[:materials]
      tags = decoded[:tags]
      transforms = decoded[:transforms]
      instances = decoded[:instances]
      definitions = decoded[:definitions]
      meshes = decoded[:meshes]

      mat_name = lambda { |i| i.nil? ? nil : c.utf8!(materials.fetch(i)[:name]) }
      tag_name = lambda { |i| i.nil? ? nil : c.utf8!(tags.fetch(i)[:name]) }

      root = instances.fetch(decoded[:root_node])
      raise ModelTruthError, 'unknown_kind: root node' unless root[:kind].to_s == 'root' && root[:owner_definition].nil?

      root_def = root[:definition]
      raise ModelTruthError, 'root_transform_not_identity' unless c.bomc_t16(transforms.fetch(root[:transform])) == c::IDENTITY_T16

      instance_kinds = %w[group_instance component_instance image text].freeze
      dfs = {}
      assign = nil
      assign = lambda do |d, depth|
        raise ModelTruthError, 'depth_limit' if depth > MAX_DEPTH
        next if dfs.key?(d)

        defn = definitions.fetch(d)
        raise ModelTruthError, "unknown_kind: definition #{defn[:kind]}" unless KIND_MAP.key?(defn[:kind].to_s)

        dfs[d] = dfs.size
        defn[:nodes].each do |n|
          inst = instances.fetch(n)
          kind = inst[:kind].to_s
          raise ModelTruthError, "unknown_kind: instance #{kind}" unless instance_kinds.include?(kind)

          if %w[group_instance component_instance].include?(kind)
            raise ModelTruthError, 'unknown_kind: instance without definition' if inst[:definition].nil?

            assign.call(inst[:definition], depth + 1)
          end
        end
      end
      assign.call(root_def, 0)

      digest = {}
      records = {}
      nil_front_faces = {}
      totals = { faces: 0, edges: 0, instances: 0, images: 0, texts: 0 }
      fallback_faces = 0
      fallback_instances = 0
      compute = nil
      compute = lambda do |d|
        next if digest.key?(d)

        defn = definitions[d]
        defn[:nodes].each do |n|
          inst = instances[n]
          compute.call(inst[:definition]) if %w[group_instance component_instance].include?(inst[:kind].to_s)
        end

        msets = { faces: c::MSet.new, edges: c::MSet.new, images: c::MSet.new, texts: c::MSet.new, inst_local: c::MSet.new, inst_merkle: c::MSet.new }
        counts = { faces: 0, edges: 0, instances: 0, images: 0, texts: 0 }
        children_dfs = []
        nil_front = 0
        my_dfs = dfs.fetch(d)

        mesh_idx = defn[:mesh]
        unless mesh_idx.nil?
          m = meshes.fetch(mesh_idx)
          pos = m[:positions]
          memo = []
          p3 = lambda do |v|
            memo[v] ||= [c.grid(pos[3 * v]), c.grid(pos[3 * v + 1]), c.grid(pos[3 * v + 2])].freeze
          end
          Array(m[:faces]).each do |f|
            fu = f[:has_front_uv] ? true : false
            bu = f[:has_back_uv] ? true : false
            uv = f[:uv] || {}
            tuple = lambda do |vi, k, front_key, back_key|
              t = p3.call(vi).dup
              t.concat(uv.fetch(front_key)[k].map { |x| c.grid(x) }) if fu
              t.concat(uv.fetch(back_key)[k].map { |x| c.grid(x) }) if bu
              t
            end
            outer = f[:outer].each_with_index.map { |vi, k| tuple.call(vi, k, :front_outer, :back_outer) }
            holes = Array(f[:holes]).each_with_index.map do |loop_vs, h|
              loop_vs.each_with_index.map do |vi, k|
                t = p3.call(vi).dup
                t.concat(uv.fetch(:front_holes)[h][k].map { |x| c.grid(x) }) if fu
                t.concat(uv.fetch(:back_holes)[h][k].map { |x| c.grid(x) }) if bu
                t
              end
            end
            tris = f[:triangles].each_slice(3).map { |a, b, cc| [p3.call(a).dup, p3.call(b).dup, p3.call(cc).dup] }
            item = c.face_item(front: mat_name.call(f[:front_material]), back: mat_name.call(f[:back_material]),
                               tag: tag_name.call(f[:tag]), hidden: f[:hidden], normal: f[:normal].map { |x| c.grid(x) },
                               outer: outer, holes: holes, triangles: tris, uv_front: fu, uv_back: bu)
            json = c.canon_json(item)
            msets[:faces].add(json)
            writer.write(jline('d' => my_dfs, 'c' => 'F', 'i' => item))
            counts[:faces] += 1
            nil_front += 1 if f[:front_material].nil?
            fallback_faces += 1 if f[:fallback]
          end
          Array(m[:edges]).each do |e|
            item = c.edge_item(tag: tag_name.call(e[:tag]), hidden: e[:hidden], soft: e[:soft], smooth: e[:smooth],
                               a: p3.call(e[:vertices][0]).dup, b: p3.call(e[:vertices][1]).dup)
            msets[:edges].add(c.canon_json(item))
            writer.write(jline('d' => my_dfs, 'c' => 'E', 'i' => item))
            counts[:edges] += 1
          end
        end

        defn[:nodes].each do |n|
          inst = instances[n]
          kind = inst[:kind].to_s
          t16 = c.bomc_t16(transforms.fetch(inst[:transform]))
          case kind
          when 'group_instance', 'component_instance'
            child = inst[:definition]
            local = c.instance_local_item(kind: (kind == 'group_instance' ? 'group' : 'component'), t16: t16,
                                          material: mat_name.call(inst[:material]), tag: tag_name.call(inst[:tag]))
            msets[:inst_local].add(c.canon_json(local))
            msets[:inst_merkle].add(c.canon_json(c.instance_merkle_item(local, digest.fetch(child))))
            writer.write(jline('d' => my_dfs, 'c' => 'I', 'i' => local, 'child_dfs' => dfs[child], 'child_digest' => digest[child]))
            counts[:instances] += 1
            children_dfs << dfs[child]
            fallback_instances += 1 if inst[:fallback]
          when 'image'
            item = c.image_item(t16: t16, tag: tag_name.call(inst[:tag]))
            msets[:images].add(c.canon_json(item))
            writer.write(jline('d' => my_dfs, 'c' => 'G', 'i' => item))
            counts[:images] += 1
          when 'text'
            item = c.text_item(text: c.utf8!(inst[:name]), point: t16[12, 3], tag: tag_name.call(inst[:tag]))
            msets[:texts].add(c.canon_json(item))
            writer.write(jline('d' => my_dfs, 'c' => 'X', 'i' => item))
            counts[:texts] += 1
          end
        end

        kind = KIND_MAP.fetch(defn[:kind].to_s)
        local_digest, dig = c.definition_digests(kind, msets[:faces], msets[:edges], msets[:images], msets[:texts],
                                                 msets[:inst_local], msets[:inst_merkle])
        digest[d] = dig
        nil_front_faces[d] = nil_front
        counts.each { |k, v| totals[k] += v }
        records[d] = {
          dfs: my_dfs, kind: kind, digest: dig, local_digest: local_digest,
          faces: msets[:faces].to_a, edges: msets[:edges].to_a, images: msets[:images].to_a, texts: msets[:texts].to_a,
          inst_local: msets[:inst_local].to_a, inst_merkle: msets[:inst_merkle].to_a,
          counts: counts, children_dfs: children_dfs
        }
      end
      compute.call(root_def)

      sorted = records.values.sort_by { |r| r[:dfs] }
      unreachable = definitions.length - dfs.length

      # Diagnostics only (no verdict effect): inherited-paint exposure (D21/D22).
      exposure = { faces_definition_level: 0, pairs: 0 }
      seen = {}
      walk = nil
      walk = lambda do |d, eff|
        key = [d, eff]
        return if seen.key?(key)

        seen[key] = true
        definitions[d][:nodes].each do |n|
          inst = instances[n]
          next unless %w[group_instance component_instance].include?(inst[:kind].to_s)

          eff2 = inst[:material].nil? ? eff : inst[:material]
          child = inst[:definition]
          if !eff2.nil? && !materials.fetch(eff2)[:texture].nil? && !seen.key?([child, eff2])
            exposure[:faces_definition_level] += nil_front_faces.fetch(child)
            exposure[:pairs] += 1
          end
          walk.call(child, eff2)
        end
      end
      walk.call(root_def, nil)

      {
        root_digest: digest.fetch(root_def),
        records: sorted,
        counts: totals.merge(materials: materials.length, tags: tags.length, textures: Array(decoded[:textures]).length),
        unreachable_definitions_bomc: unreachable,
        diagnostics: {
          fallback_faces: fallback_faces,
          fallback_instances: fallback_instances,
          inherited_paint_exposure: exposure,
          unreachable_definitions_bomc: unreachable
        }
      }
    end

    # ------------------------------------------------------------------------
    # Tables and textures
    # ------------------------------------------------------------------------
    def material_rows(decoded)
      c = Canonical
      decoded[:materials].map do |m|
        col = m[:color] || {}
        deltas = m[:colorize_deltas]
        {
          name: c.utf8!(m[:name]),
          color: [col[:r], col[:g], col[:b], col[:a]],
          opacity_u16: (m[:opacity].to_f * 65_535).round,
          material_type: m[:material_type],
          texture_index: m[:texture],
          texture_width_m_hex: m[:texture_width_m].nil? ? nil : c.float_hex(m[:texture_width_m]),
          texture_height_m_hex: m[:texture_height_m].nil? ? nil : c.float_hex(m[:texture_height_m]),
          semantic_colorize_active: m[:semantic_colorize_active] ? true : false,
          colorize_type: m[:colorize_type],
          colorize_deltas_hex: deltas.nil? ? nil : [deltas[:h], deltas[:l], deltas[:s]].map { |v| c.float_hex(v) },
          colorize_output_sha256: m[:colorize_output_sha256]
        }
      end
    end

    def tag_rows(decoded)
      decoded[:tags].map { |t| { name: Canonical.utf8!(t[:name]), visible: t[:visible] ? true : false } }
    end

    def run_tool(args, out_path, timeout_s)
      pid = Process.spawn(*args, in: File::NULL, out: [out_path, 'wb'], err: File::NULL)
      deadline = monotonic + timeout_s
      loop do
        done, status = Process.wait2(pid, Process::WNOHANG)
        return status if done
        if monotonic > deadline
          begin
            Process.kill('KILL', pid)
          rescue StandardError
            nil
          end
          Process.wait(pid)
          return :timeout
        end
        sleep 0.02
      end
    end

    def webp_pixels(path, row, dwebp_path, ffmpeg_path, tmp_dir)
      c = Canonical
      begin
        c.webp_container!(File.binread(path))
      rescue PixelError => e
        return { status: 'FAIL', code: e.message }
      end
      pam_path = File.join(tmp_dir, "#{row[:index]}.pam")
      raw_path = File.join(tmp_dir, "#{row[:index]}.rgba")
      begin
        st = run_tool([dwebp_path, path, '-quiet', '-pam', '-o', pam_path], File::NULL, DECODER_TIMEOUT_S)
        return { status: 'FAIL', code: 'decoder_timeout' } if st == :timeout
        return { status: 'FAIL', code: 'decoder_error' } unless st.success? && File.exist?(pam_path)

        begin
          pam = c.parse_pam(File.binread(pam_path))
        rescue PixelError
          return { status: 'FAIL', code: 'pam_invalid' }
        end
        sha_primary = Digest::SHA256.hexdigest(pam[:rgba])

        st = run_tool([ffmpeg_path, '-v', 'error', '-nostdin', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgba', '-'], raw_path, DECODER_TIMEOUT_S)
        return { status: 'FAIL', code: 'decoder_timeout' } if st == :timeout
        return { status: 'FAIL', code: 'decoder_error' } unless st.success? && File.exist?(raw_path)

        raw_size = File.size(raw_path)
        return { status: 'FAIL', code: 'dimension_mismatch' } unless raw_size == row[:width_px] * row[:height_px] * 4
        return { status: 'FAIL', code: 'dimension_mismatch' } unless pam[:width] == row[:width_px] && pam[:height] == row[:height_px]

        sha_cross = Digest::SHA256.file(raw_path).hexdigest
        return { status: 'FAIL', code: 'decoder_disagreement' } unless sha_cross == sha_primary

        { status: 'OK', sha256: sha_primary, decoders: ['dwebp-1.6.0-pam', 'ffmpeg-N-125365-rgba'] }
      ensure
        [pam_path, raw_path].each { |p| File.delete(p) if File.exist?(p) }
      end
    end

    # Writes texture files and returns table rows. `dir` is run_dir/bomc.
    def textures_step(decoded, dir, dwebp_path:, ffmpeg_path:)
      tex_dir = File.join(dir, 'textures')
      tmp_dir = File.join(dir, 'tmp')
      rows = []
      Array(decoded[:textures]).each_with_index do |t, i|
        media = t[:media_type].to_s
        ext = TEXTURE_EXT.fetch(media, 'bin')
        file = "#{i}.#{ext}"
        path = File.join(tex_dir, file)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) { |f| f.write(t[:bytes]) }
        row = { index: i, media_type: media, width_px: t[:image_width_px], height_px: t[:image_height_px],
                encoded_sha256: Digest::SHA256.hexdigest(t[:bytes]), file: file }
        row[:pixel] =
          case media
          when 'webp'
            webp_pixels(path, row, dwebp_path, ffmpeg_path, tmp_dir)
          when 'jpeg', 'png'
            { status: 'PENDING_SKETCHUP' }
          when 'jpeg_color_map'
            begin
              map = BOMEngine::BOMCJpegColorMap.parse(t[:bytes])
              jpg = "#{i}.jcm.jpg"
              File.open(File.join(tex_dir, jpg), File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) { |f| f.write(map[:jpeg]) }
              { status: 'PENDING_SKETCHUP', jcm_jpeg: jpg }
            rescue ArgumentError
              { status: 'FAIL', code: 'jcm_parse_error' }
            end
          else
            { status: 'FAIL', code: 'unsupported_media' }
          end
        rows << row
      end
      rows
    end

    # ------------------------------------------------------------------------
    # Capture
    # ------------------------------------------------------------------------
    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_atomic(path, text)
      File.open("#{path}.partial", File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) { |f| f.write(text) }
      File.rename("#{path}.partial", path)
    end

    def create_excl(path)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600)
    end

    # Production entry: verifies the pinned tools and the corpus row, decodes the
    # Exact BOMC and runs the capture.
    def capture(corpus_row:, run_dir:, dwebp_path:, ffmpeg_path:)
      decoder = lambda do
        { 'dwebp' => [dwebp_path, DWEBP_SHA256], 'ffmpeg' => [ffmpeg_path, FFMPEG_SHA256] }.each do |name, (path, pin)|
          raise ModelTruthError, "tool_pin_mismatch: #{name}" unless File.file?(path) && sha_file(path) == pin
        end
        ex = corpus_row.fetch('exact')
        bytes = File.binread(ex['path'])
        raise ModelTruthError, 'input sha256 mismatch' unless Digest::SHA256.hexdigest(bytes) == ex['sha256']
        raise ModelTruthError, 'producer pin mismatch' unless ex['producerSourceSha256'] == PRODUCER_PIN
        raise ModelTruthError, 'source sha mismatch' unless ex['sourceSha256'] == corpus_row['skpSha256']

        BOMEngine::BOMCDecoder.decode(bytes, limits: BOMEngine::DecodeBudget::PRODUCER_VERIFY_LIMITS)
      end
      run(corpus_row: corpus_row, run_dir: run_dir, dwebp_path: dwebp_path, ffmpeg_path: ffmpeg_path, decoder: decoder)
    end

    # Shared body. `decoder` returns the decoded Hash (tests pass a fixture).
    def run(corpus_row:, run_dir:, dwebp_path:, ffmpeg_path:, decoder:)
      c = Canonical
      rd = run_dir.to_s.tr('\\', '/')
      raise ModelTruthError, 'run_dir must be absolute on D:' unless rd =~ %r{\Ad:/}i
      raise ModelTruthError, 'run_dir exists' if File.exist?(run_dir)

      FileUtils.mkdir_p(File.dirname(run_dir))
      Dir.mkdir(run_dir)
      bdir = File.join(run_dir, 'bomc')
      Dir.mkdir(bdir)
      Dir.mkdir(File.join(bdir, 'tmp'))
      Dir.mkdir(File.join(bdir, 'textures'))
      model = corpus_row['model']
      run_id = File.basename(rd)
      saved_temp = [ENV['TEMP'], ENV['TMP']]
      tmp_win = File.join(bdir, 'tmp').tr('/', '\\')
      ENV['TEMP'] = tmp_win
      ENV['TMP'] = tmp_win
      items_gz = nil
      defs_io = nil
      t_start = monotonic
      timings = {}
      manifest_base = { schema: c::SCHEMA, side: 'bomc', model: model, model_key: c.model_key(model), run_id: run_id }
      begin
        ex = corpus_row.fetch('exact')
        t0 = monotonic
        decoded = decoder.call
        timings[:decode] = monotonic - t0

        ec = decoded[:encoding_contract]
        ok = ec && ec[:profile].to_s == 'exact' && %i[position_max_error_m uv_max_error transform_max_error normal_max_error_deg].all? { |k| ec[k] == 0.0 } &&
             ec[:texture_policy].to_s == 'pixel_lossless'
        raise ModelTruthError, 'not_exact_contract' unless ok

        items_gz = Zlib::GzipWriter.new(create_excl(File.join(bdir, 'items.ndjson.gz')), 1)
        items_gz.mtime = Time.at(0)
        defs_io = create_excl(File.join(bdir, 'definitions.ndjson'))
        t0 = monotonic
        result = core(decoded, writer: items_gz)
        timings[:core] = monotonic - t0
        items_gz.close
        items_gz = nil
        result[:records].each { |r| defs_io.write(jline(r)) }
        defs_io.close
        defs_io = nil

        t0 = monotonic
        tex_rows = textures_step(decoded, bdir, dwebp_path: dwebp_path, ffmpeg_path: ffmpeg_path)
        timings[:textures] = monotonic - t0

        tables = { schema: c::SCHEMA, materials: material_rows(decoded), tags: tag_rows(decoded), textures: tex_rows }
        write_atomic(File.join(bdir, 'tables.json'), JSON.pretty_generate(tables))
        write_atomic(File.join(bdir, 'diagnostics.json'), JSON.pretty_generate(result[:diagnostics]))
        timings[:total] = monotonic - t_start

        files = {}
        Dir.glob(File.join(bdir, '**', '*')).sort.each do |p|
          next unless File.file?(p)

          rel = p.sub("#{bdir}/", '')
          files[rel] = sha_file(p)
        end
        gz_sha = Digest::SHA256.new
        Zlib::GzipReader.open(File.join(bdir, 'items.ndjson.gz')) { |gz| while (chunk = gz.read(1 << 20)); gz_sha.update(chunk); end }
        engine = File.expand_path('../../bom_engine', __dir__)
        manifest = manifest_base.merge(
          complete: true,
          inputs: { bomc_path: ex['path'], bomc_sha256: ex['sha256'], skp_path: corpus_row.dig('skp', 'path'), skp_sha256: corpus_row['skpSha256'], producer_pin: PRODUCER_PIN },
          root_digest: result[:root_digest],
          definition_count: result[:records].length,
          counts: result[:counts],
          unreachable_definitions_bomc: result[:unreachable_definitions_bomc],
          timings_s: timings,
          tools: {
            ruby_version: RUBY_VERSION,
            canonical_rb_sha256: sha_file(File.expand_path('canonical.rb', __dir__)),
            bomc_side_rb_sha256: sha_file(File.expand_path(__FILE__)),
            bomc_decoder_rb_sha256: sha_file(File.join(engine, 'bomc_decoder.rb')),
            dwebp_sha256: DWEBP_SHA256,
            ffmpeg_sha256: FFMPEG_SHA256
          },
          files: files,
          items_ndjson_decompressed_sha256: gz_sha.hexdigest
        )
        write_atomic(File.join(bdir, 'manifest.json'), JSON.pretty_generate(manifest))
        manifest
      rescue StandardError, ScriptError => e
        begin
          items_gz&.close
        rescue StandardError
          nil
        end
        begin
          defs_io&.close
        rescue StandardError
          nil
        end
        err_manifest = manifest_base.merge(complete: false, error: { class: e.class.name, message: e.message })
        begin
          write_atomic(File.join(bdir, 'manifest.json'), JSON.pretty_generate(err_manifest))
        rescue StandardError
          nil
        end
        raise
      ensure
        ENV['TEMP'], ENV['TMP'] = saved_temp
      end
    end
  end
end
