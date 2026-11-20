# frozen_string_literal: true

# ruby tools/model_truth/run_bomc_side.rb --corpus <corpus.json> --out-root <root> --ffmpeg <ffmpeg.exe> (--model "<name>" | --all)
#
# Runs the BOMC side for one model or for all models (ascending skpRank), then
# (for --all) writes OWNER-RUNBOOK-<run_id>.md and bomc-side-batch-<run_id>.json
# into the out-root. Exit 0 when every selected model succeeded, 1 otherwise.

require 'json'
require 'optparse'
require 'time'
require_relative 'canonical'
require_relative 'bomc_side'

module SibamboModelTruthV1
  module RunBomcSide
    module_function

    def utc_run_id(now = Time.now.utc)
      now.strftime('%Y%m%dT%H%M%SZ')
    end

    def dir_size(path)
      Dir.glob(File.join(path, '**', '*')).select { |p| File.file?(p) }.sum { |p| File.size(p) }
    end

    def runbook(batch_id, entries, tool_dir)
      skp_side = File.join(tool_dir, 'skp_side.rb').tr('\\', '/')
      lines = []
      lines << "# ModelTruth owner runbook #{batch_id}"
      lines << ''
      lines << 'SketchUp 26.2.243 only. Do not save any model. Close without saving and restart SketchUp before the next model.'
      lines << 'Build freeze (plan D31): no E4 install, no SKP re-save, no research BOMC re-export while this runbook is in progress.'
      lines << ''
      entries.each_with_index do |e, i|
        lines << "## #{i + 1}. #{e[:model]} (rank #{e[:rank]})"
        lines << ''
        lines << "- Open: `#{e[:skp_path].tr('\\', '/')}`"
        lines << "- BOMC side: `#{e[:status]}` (run `#{e[:run_id]}`)"
        if e[:status] == 'ok'
          lines << '- Ruby Console:'
          lines << ''
          lines << '```ruby'
          lines << "load '#{skp_side}'"
          lines << "SibamboModelTruthV1::SkpSide.capture(run_dir: '#{e[:run_dir]}', expected_source_sha256: '#{e[:skp_sha256]}')"
          lines << 'SibamboModelTruthV1::SkpSide.status'
          lines << '```'
          lines << ''
          lines << '- Wait until `status` reports `finished`, then close the model WITHOUT saving and restart SketchUp.'
          lines << "- Then tell the agent: `run_compare.rb #{e[:run_dir]}`"
        else
          lines << "- **Do not capture this model**: BOMC side failed (#{e[:error]})."
        end
        lines << ''
      end
      lines.join("\n")
    end

    def main(argv)
      opts = {}
      OptionParser.new do |o|
        o.on('--corpus PATH') { |v| opts[:corpus] = v }
        o.on('--out-root PATH') { |v| opts[:out_root] = v }
        o.on('--ffmpeg PATH') { |v| opts[:ffmpeg] = v }
        o.on('--model NAME') { |v| opts[:model] = v }
        o.on('--all') { opts[:all] = true }
      end.parse!(argv)
      %i[corpus out_root ffmpeg].each { |k| abort("missing --#{k.to_s.tr('_', '-')}") unless opts[k] }
      abort('give --model "<name>" or --all') unless opts[:model] || opts[:all]

      corpus = JSON.parse(File.read(opts[:corpus]))
      models = corpus.fetch('models').sort_by { |m| m['skpRank'] }
      models = models.select { |m| m['model'] == opts[:model] } if opts[:model]
      abort("no model matches #{opts[:model].inspect}") if models.empty?

      dwebp = File.expand_path('../../bom_engine/bin/win64/dwebp.exe', __dir__)
      batch_id = utc_run_id
      entries = []
      failed = []
      models.each do |row|
        key = Canonical.model_key(row['model'])
        run_id = utc_run_id
        run_dir = File.join(opts[:out_root], key, run_id).tr('\\', '/')
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        entry = { model: row['model'], rank: row['skpRank'], run_id: run_id, run_dir: run_dir,
                  skp_path: row.dig('skp', 'path'), skp_sha256: row['skpSha256'] }
        begin
          manifest = BomcSide.capture(corpus_row: row, run_dir: run_dir, dwebp_path: dwebp, ffmpeg_path: opts[:ffmpeg])
          entry.merge!(status: 'ok', seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1),
                       bytes: dir_size(File.join(run_dir, 'bomc')), counts: manifest[:counts], root_digest: manifest[:root_digest],
                       texture_failures: JSON.parse(File.read(File.join(run_dir, 'bomc', 'tables.json')))['textures'].count { |t| t['pixel']['status'] == 'FAIL' })
          puts run_dir
        rescue StandardError, ScriptError => e
          entry.merge!(status: 'failed', error: "#{e.class}: #{e.message}")
          failed << row['model']
          warn "FAILED #{row['model']}: #{e.class}: #{e.message}"
        end
        entries << entry
        sleep 1.1 # run ids are one-second timestamps
      end

      if opts[:all]
        File.write(File.join(opts[:out_root], "OWNER-RUNBOOK-#{batch_id}.md"), runbook(batch_id, entries, __dir__))
        File.write(File.join(opts[:out_root], "bomc-side-batch-#{batch_id}.json"), JSON.pretty_generate(entries))
      end
      warn "failed models: #{failed.join(', ')}" unless failed.empty?
      failed.empty? ? 0 : 1
    end
  end
end

exit(SibamboModelTruthV1::RunBomcSide.main(ARGV)) if $PROGRAM_NAME == __FILE__
