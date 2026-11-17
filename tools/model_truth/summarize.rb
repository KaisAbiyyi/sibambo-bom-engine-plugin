# frozen_string_literal: true

# ruby tools/model_truth/summarize.rb --out-root <root> --corpus <corpus.json> --output <MODEL-TRUTH-SUMMARY.md>
#
# One row per corpus model (skpRank order): code Mxx, model, latest run id,
# overall, every category verdict, disclosure counters, excluded counts; then the
# corpus totals the plan requires (D34). A model without a diff shows NOT_RUN.

require 'json'
require 'optparse'
require 'time'
require_relative 'canonical'

module SibamboModelTruthV1
  module Summarize
    CATS = %w[definitions faces edges instances images texts materials tags textures_pixels textures_colorize].freeze

    module_function

    def latest_run(out_root, key)
      dir = File.join(out_root, key)
      return [nil, []] unless File.directory?(dir)

      runs = Dir.children(dir).select { |r| File.file?(File.join(dir, r, 'model-truth-diff.json')) }.sort
      [runs.last, runs]
    end

    def code(rank)
      format('M%02d', rank)
    end

    def excluded_count(diff, scope)
      e = diff['excluded'].find { |x| x['scope'] == scope }
      e ? e['skpCount'].to_i : 0
    end

    def build(out_root:, corpus_path:)
      corpus = JSON.parse(File.read(corpus_path))
      rows = corpus['models'].sort_by { |m| m['skpRank'] }.map do |m|
        key = Canonical.model_key(m['model'])
        run_id, runs = latest_run(out_root, key)
        diff = run_id ? JSON.parse(File.read(File.join(out_root, key, run_id, 'model-truth-diff.json'))) : nil
        { model: m['model'], rank: m['skpRank'], key: key, run_id: run_id, runs: runs, diff: diff }
      end
      render(rows, corpus_path)
    end

    def verdict_of(diff, cat)
      return 'NOT_RUN' unless diff

      c = diff['categories'].find { |x| x['category'] == cat }
      c ? c['verdict'] : 'NOT_RUN'
    end

    def render(rows, corpus_path)
      lines = []
      lines << '# MODEL-TRUTH-SUMMARY (SIB-R1-ITCON-001 WP2)'
      lines << ''
      lines << "Generated #{Time.now.utc.iso8601} from `#{corpus_path.tr('\\', '/')}`. Internal document: model names appear here; the manuscript uses the codes M01-M24 only (plan D17/D18)."
      lines << ''
      have = rows.select { |r| r[:diff] }
      pass = have.count { |r| r[:diff]['overall'] == 'PASS' }
      lines << "Models with a diff: #{have.length} of #{rows.length}. Overall PASS: #{pass}. FAIL: #{have.count { |r| r[:diff]['overall'] == 'FAIL' }}. ERROR: #{have.count { |r| r[:diff]['overall'] == 'ERROR' }}. NOT_RUN: #{rows.length - have.length}."
      lines << ''
      lines << '## Per model'
      lines << ''
      lines << "| Code | Model | Run | Overall | #{CATS.join(' | ')} | uv_q0 | non-tri | BOMC s | SKP s |"
      lines << "|#{'---|' * (CATS.length + 8)}"
      rows.each do |r|
        d = r[:diff]
        cells = CATS.map { |c| verdict_of(d, c) }
        sc = (d && d['disclosures']) || {}
        lines << "| #{code(r[:rank])} | #{r[:model]} | #{r[:run_id] || '-'} | #{d ? d['overall'] : 'NOT_RUN'} | #{cells.join(' | ')} | " \
                 "#{d ? sc['uv_q0_vertices'] : '-'} | #{d ? sc['non_triangle_polygons'] : '-'} | #{d ? d.dig('runtime', 'bomc_side_s') : '-'} | #{d ? d.dig('runtime', 'skp_side_s') : '-'} |"
      end
      lines << ''
      lines << '## Categories that may be cited (PASS for every one of the 24 models)'
      lines << ''
      lines << '| Category | PASS | FAIL | NOT_RUN |'
      lines << '|---|---|---|---|'
      CATS.each do |c|
        v = rows.map { |r| verdict_of(r[:diff], c) }
        lines << "| #{c} | #{v.count('PASS')} | #{v.count('FAIL')} | #{v.count('NOT_RUN')} |"
      end
      lines << ''
      lines << 'A category may appear in a paper statement about Exact preservation only if all 24 models are PASS (plan D12/Invariant 10).'
      lines << ''
      lines << '## Run ids'
      lines << ''
      rows.each do |r|
        next if r[:runs].empty?

        lines << "- #{code(r[:rank])} #{r[:model]}: used `#{r[:run_id]}`; all runs with a diff: #{r[:runs].join(', ')}"
      end
      lines << ''
      lines << '## Corpus totals and disclosures (plan D34)'
      lines << ''
      have = have.reject { |r| r[:diff]['overall'] == 'ERROR' }
      sum = ->(&blk) { have.sum { |r| blk.call(r[:diff]).to_i } }
      lines << "Totals cover the #{have.length} models that have a PASS or FAIL diff."
      lines << ''
      lines << "- NOT_RUN: image pixels (D22) - image entities in scope: #{have.sum { |r| r[:diff]['not_run'].sum { |n| n['skpCount'].to_i } }}."
      lines << "- UV with q = 0 mapped to [0, 0] (`uv_q0_vertices`): #{sum.call { |d| d['disclosures']['uv_q0_vertices'] }}."
      lines << "- Non-triangle mesh polygons dropped on both sides (`non_triangle_polygons`): #{sum.call { |d| d['disclosures']['non_triangle_polygons'] }}."
      lines << "- Deleted entities skipped (SketchUp side): #{sum.call { |d| d['disclosures']['deleted_skipped'] }}."
      lines << "- ImageRep side not needed for the material (D27) that could not be canonicalised, reported as info and not failing (e.g. 8 bpp `image_rep(false)`): #{sum.call { |d| d['diagnostics']['texture_info_count'] }}."
      expo = have.map { |r| r[:diff]['disclosures']['inherited_paint_exposure'] }.compact
      lines << "- Inherited-paint exposure (instance paint over default faces, not compared; D21): faces at definition level #{expo.sum { |e| e['faces_definition_level'].to_i }}, instance/definition pairs #{expo.sum { |e| e['pairs'].to_i }}."
      lines << '- EXCLUDED scopes (D22), SketchUp-side counts:'
      scopes = have.flat_map { |r| r[:diff]['excluded'].map { |e| e['scope'] } }.uniq.sort
      scopes.each do |sname|
        total = have.sum { |r| (r[:diff]['excluded'].find { |e| e['scope'] == sname } || {})['skpCount'].to_i }
        reason = have.flat_map { |r| r[:diff]['excluded'] }.find { |e| e['scope'] == sname }['reason']
        lines << "  - #{sname}: #{total} (#{reason})"
      end
      lines << '- Colorize limitation (D27): the reader\'s colorize function is not re-implemented. The check binds the export-time proof to the SketchUp source: BOMC base pixels equal `image_rep(false)`, BOMC `colorize_output_sha256` equals the canonical SHA of `image_rep(true)`, and type and deltas are bit-identical.'
      lines << '- SketchUp build assumption (F23): the build used for the BOMC exports is not recorded in the sidecars and is assumed to be 26.2.243, the build of every capture.'
      lines << ''
      lines.join("\n") + "\n"
    end

    def main(argv)
      opts = {}
      OptionParser.new do |o|
        o.on('--out-root PATH') { |v| opts[:out_root] = v }
        o.on('--corpus PATH') { |v| opts[:corpus] = v }
        o.on('--output PATH') { |v| opts[:output] = v }
      end.parse!(argv)
      %i[out_root corpus output].each { |k| abort("missing --#{k.to_s.tr('_', '-')}") unless opts[k] }
      File.write(opts[:output], build(out_root: opts[:out_root], corpus_path: opts[:corpus]))
      puts opts[:output]
      0
    end
  end
end

exit(SibamboModelTruthV1::Summarize.main(ARGV)) if $PROGRAM_NAME == __FILE__
