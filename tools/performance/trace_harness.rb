#!/usr/bin/env ruby
# frozen_string_literal: true
# SIB-PERF-00: external evidence contract. Does not load/modify SketchUp producer code.
require 'json'

module SibamboPerf
  SCHEMA = 'sibambo-perf-observation-v1'
  TRACE_SCHEMA = 'sibambo-performance-trace-v1'
  ENGINE_NAMES = { 'e2' => 'E1 Canonical', 'e3' => 'E2 CleanPKG', 'e4' => 'E3 BOMC' }.freeze
  PROFILES = %w[exact visual].freeze
  MODES = %w[single export_all].freeze
  CACHES = %w[cold warm].freeze
  STATES = %w[success error cancelled partial_failed].freeze
  SHA = /\A[0-9a-f]{64}\z/
  TOKEN = /\A[a-zA-Z0-9_-]{1,100}\z/

  module_function

  def object(value)
    value.is_a?(Hash) ? value : {}
  end

  def array(value)
    value.is_a?(Array) ? value : []
  end

  def num?(value, positive: false)
    value.is_a?(Numeric) && value.finite? && (positive ? value > 0 : value >= 0)
  end

  def nonempty?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def sha?(value)
    value.is_a?(String) && SHA.match?(value)
  end

  def require_value(errors, value, label, condition)
    errors << "#{label} is missing or invalid" unless condition
  end

  def validate(input)
    errors = []
    unless input.is_a?(Hash)
      return ['observation must be an object']
    end

    require_value(errors, input['schema'], 'schema', input['schema'] == SCHEMA)
    kind = input['measurement_kind']
    require_value(errors, kind, 'measurement_kind', %w[native synthetic].include?(kind))
    run_id = input['run_id']
    require_value(errors, run_id, 'run_id', run_id.is_a?(String) && TOKEN.match?(run_id))

    source = object(input['source'])
    require_value(errors, source['model_id'], 'source.model_id',
                  source['model_id'].is_a?(String) && TOKEN.match?(source['model_id']))
    require_value(errors, source['sha256'], 'source.sha256', sha?(source['sha256']))
    require_value(errors, source['bytes'], 'source.bytes', num?(source['bytes'], positive: true) && source['bytes'].is_a?(Integer))

    env = object(input['environment'])
    %w[os sketchup_version ruby_version host_id].each do |field|
      require_value(errors, env[field], "environment.#{field}", nonempty?(env[field]))
    end
    require_value(errors, env['source_tree_sha256'], 'environment.source_tree_sha256', sha?(env['source_tree_sha256']))
    require_value(errors, env['rbz_sha256'], 'environment.rbz_sha256', sha?(env['rbz_sha256']))
    errors << 'native environment must identify Windows SketchUp' if kind == 'native' && !env.fetch('os', '').to_s.match?(/windows/i)

    export = object(input['export'])
    require_value(errors, export['wire_engine_id'], 'export.wire_engine_id', ENGINE_NAMES.key?(export['wire_engine_id']))
    require_value(errors, export['profile'], 'export.profile', PROFILES.include?(export['profile']))
    require_value(errors, export['mode'], 'export.mode', MODES.include?(export['mode']))
    require_value(errors, export['cache'], 'export.cache', CACHES.include?(export['cache']))
    require_value(errors, export['replicate'], 'export.replicate',
                  export['replicate'].is_a?(Integer) && export['replicate'] > 0)

    outcome = object(input['outcome'])
    require_value(errors, outcome['status'], 'outcome.status', STATES.include?(outcome['status']))
    require_value(errors, outcome['wall_ms'], 'outcome.wall_ms', num?(outcome['wall_ms'], positive: true))
    require_value(errors, outcome['fidelity'], 'outcome.fidelity', %w[pass fail pending].include?(outcome['fidelity']))
    if outcome['status'] == 'success'
      require_value(errors, outcome['artifact_bytes'], 'outcome.artifact_bytes', outcome['artifact_bytes'].is_a?(Integer) && num?(outcome['artifact_bytes'], positive: true))
      require_value(errors, outcome['artifact_sha256'], 'outcome.artifact_sha256', sha?(outcome['artifact_sha256']))
    end
    if kind == 'native'
      require_value(errors, outcome['peak_rss_bytes'], 'outcome.peak_rss_bytes',
                    outcome['peak_rss_bytes'].is_a?(Integer) && num?(outcome['peak_rss_bytes'], positive: true))
    elsif outcome.key?('peak_rss_bytes') && !outcome['peak_rss_bytes'].nil?
      errors << 'outcome.peak_rss_bytes must be positive integer or null' unless outcome['peak_rss_bytes'].is_a?(Integer) && num?(outcome['peak_rss_bytes'], positive: true)
    end

    trace = object(input['trace'])
    require_value(errors, trace['schema'], 'trace.schema', trace['schema'] == TRACE_SCHEMA)
    require_value(errors, trace['enabled'], 'trace.enabled', trace['enabled'] == true)
    require_value(errors, trace['total_wall_ms'], 'trace.total_wall_ms', num?(trace['total_wall_ms']))
    if num?(trace['total_wall_ms']) && num?(outcome['wall_ms']) && trace['total_wall_ms'] > outcome['wall_ms'] + 5.0
      errors << 'trace.total_wall_ms exceeds end-to-end outcome.wall_ms'
    end
    stages = trace['stages']
    errors << 'trace.stages must be a nonempty array' unless stages.is_a?(Array) && !stages.empty?
    stage_by_id = {}
    array(stages).each_with_index do |stage, index|
      unless stage.is_a?(Hash)
        errors << "trace.stages[#{index}] must be an object"
        next
      end
      id = stage['id']
      errors << "trace.stages[#{index}].id invalid or duplicated" if !nonempty?(id) || stage_by_id.key?(id)
      stage_by_id[id] = stage if nonempty?(id)
      errors << "trace.stages[#{index}].name required" unless nonempty?(stage['name'])
      errors << "trace.stages[#{index}].status invalid" unless %w[success error cancelled].include?(stage['status'])
      %w[started_ms finished_ms duration_ms].each do |field|
        errors << "trace.stages[#{index}].#{field} invalid" unless num?(stage[field])
      end
      start_ms, finish_ms, duration_ms = stage.values_at('started_ms', 'finished_ms', 'duration_ms')
      if num?(start_ms) && num?(finish_ms) && num?(duration_ms)
        errors << "trace.stages[#{index}] has inverted timestamps" if finish_ms + 0.01 < start_ms
        errors << "trace.stages[#{index}] has inconsistent duration" if (finish_ms - start_ms - duration_ms).abs > 5.0
        errors << "trace.stages[#{index}] exceeds total trace" if num?(trace['total_wall_ms']) && finish_ms > trace['total_wall_ms'] + 100.0
      end
      if stage['counts'].is_a?(Hash)
        stage['counts'].each do |key, count|
          errors << "trace.stages[#{index}].counts.#{key} negative" if count.is_a?(Numeric) && !num?(count)
        end
      end
    end
    array(stages).each_with_index do |stage, index|
      next unless stage.is_a?(Hash)
      parent = stage['parent_id']
      next if parent.nil?
      found = stage_by_id[parent]
      errors << "trace.stages[#{index}] has absent/self parent" if !found || parent == stage['id']
      if found && num?(found['started_ms']) && num?(found['finished_ms']) && num?(stage['started_ms']) && num?(stage['finished_ms'])
        errors << "trace.stages[#{index}] escapes parent timespan" if stage['started_ms'] < found['started_ms'] - 5 || stage['finished_ms'] > found['finished_ms'] + 5
      end
    end

    materials = input['materials']
    errors << 'materials must be an array' unless materials.is_a?(Array)
    array(materials).each_with_index do |material, index|
      unless material.is_a?(Hash)
        errors << "materials[#{index}] must be an object"
        next
      end
      errors << "materials[#{index}].material_id invalid" unless material['material_id'].is_a?(String) && TOKEN.match?(material['material_id'])
      %w[pixels source_bytes output_bytes candidate_attempts rejected_candidates cache_hits cache_misses].each do |key|
        value = material[key]
        errors << "materials[#{index}].#{key} must be a nonnegative integer" unless value.is_a?(Integer) && num?(value)
      end
      %w[verify_ms encode_ms decode_ms transcode_ms].each do |key|
        errors << "materials[#{index}].#{key} must be nonnegative" unless num?(material[key])
      end
      errors << "materials[#{index}] rejected more candidates than attempted" if material['rejected_candidates'].is_a?(Integer) && material['candidate_attempts'].is_a?(Integer) && material['rejected_candidates'] > material['candidate_attempts']
      %w[source_sha256 output_sha256].each do |key|
        errors << "materials[#{index}].#{key} invalid" unless material[key].nil? || sha?(material[key])
      end
      errors << "materials[#{index}].codec required" unless nonempty?(material['codec'])
      if export['profile'] == 'exact' && kind == 'native' && outcome['fidelity'] == 'pass'
        errors << "materials[#{index}] exact RGBA/alpha unverified" unless material['exact_rgba_alpha_pass'] == true
      end
    end

    checkpoints = input['checkpoints']
    errors << 'checkpoints must be an array' unless checkpoints.is_a?(Array)
    last = -1.0
    array(checkpoints).each_with_index do |event, index|
      unless event.is_a?(Hash)
        errors << "checkpoints[#{index}] must be an object"
        next
      end
      t = event['elapsed_ms']
      errors << "checkpoints[#{index}].elapsed_ms invalid/out of order" unless num?(t) && t >= last
      errors << "checkpoints[#{index}].stage required" unless nonempty?(event['stage'])
      if num?(t)
        last = t
        errors << "checkpoints[#{index}] beyond wall_ms" if num?(outcome['wall_ms']) && t > outcome['wall_ms'] + 100
      end
      processed, total = event.values_at('processed', 'total')
      if !processed.nil? || !total.nil?
        errors << "checkpoints[#{index}].counts invalid" unless num?(processed) && num?(total) && processed <= total
      end
    end
    errors
  end

  def qualified_native?(row)
    row['measurement_kind'] == 'native' && row.dig('outcome', 'status') == 'success' &&
      row.dig('outcome', 'fidelity') == 'pass' && validate(row).empty?
  end

  def percentile(numbers, p)
    return nil if numbers.length < 2
    values = numbers.sort
    rank = (values.length - 1) * p
    a, b = rank.floor, rank.ceil
    (values[a] + (values[b] - values[a]) * (rank - a)).round(3)
  end

  def max_gap(row)
    wall = row.dig('outcome', 'wall_ms')
    return nil unless num?(wall)
    times = [0.0] + array(row['checkpoints']).map { |e| e['elapsed_ms'] } + [wall]
    times.each_cons(2).map { |left, right| right - left }.max.round(3)
  end

  def stage_exclusive(row)
    stages = array(row.dig('trace', 'stages'))
    children = Hash.new { |h, k| h[k] = [] }
    stages.each { |stage| children[stage['parent_id']] << stage if stage['parent_id'] }
    stages.map do |stage|
      direct = children[stage['id']].sum { |child| child['duration_ms'].to_f }
      [stage['name'], [stage['duration_ms'].to_f - direct, 0].max.round(3)]
    end
  end

  def cohort_key(row)
    [row.dig('source', 'sha256'), row.dig('export', 'wire_engine_id'),
     row.dig('export', 'profile'), row.dig('export', 'mode'),
     row.dig('export', 'cache'), row.dig('environment', 'host_id'),
     row.dig('environment', 'sketchup_version'), row.dig('environment', 'ruby_version')]
  end

  def report(rows)
    invalid = []
    valid = []
    rows.each_with_index do |row, index|
      errs = validate(row)
      if errs.empty?
        valid << row
      else
        invalid << { index: index, run_id: row.is_a?(Hash) ? row['run_id'] : nil, errors: errs }
      end
    end
    measured = valid.select { |r| qualified_native?(r) }
    groups = measured.group_by { |r| cohort_key(r) }.sort_by { |key, _| key.map(&:to_s).join(':') }.map do |key, group|
      times = group.map { |r| r.dig('outcome', 'wall_ms').to_f }
      spans = group.flat_map { |r| stage_exclusive(r) }.group_by(&:first)
      {
        model_sha256: key[0], wire_engine_id: key[1], display_engine: ENGINE_NAMES[key[1]],
        profile: key[2], mode: key[3], cache: key[4], host_id: key[5],
        sketchup_version: key[6], ruby_version: key[7],
        runs: group.size, wall_ms: { min: times.min, max: times.max,
          p50: percentile(times, 0.5), p95: percentile(times, 0.95) },
        artifact_bytes: group.map { |r| r.dig('outcome', 'artifact_bytes') },
        peak_rss_bytes: group.map { |r| r.dig('outcome', 'peak_rss_bytes') }.max,
        max_ui_silence_ms: group.map { |r| max_gap(r) }.compact.max,
        stage_exclusive_ms: spans.transform_values { |pairs| pairs.sum(&:last).round(3) }
      }
    end
    {
      schema: 'sibambo-perf-harness-report-v1', input_rows: rows.size,
      valid_rows: valid.size, invalid_rows: invalid, synthetic_rows: valid.count { |r| r['measurement_kind'] == 'synthetic' },
      native_unqualified_rows: valid.count { |r| r['measurement_kind'] == 'native' && !qualified_native?(r) },
      qualified_native_rows: measured.length,
      qualification_note: 'JSON envelope validates shape only; independent host and readback evidence still required',
      cohorts: groups
    }
  end

  def compare(before, after)
    a = report(before)
    b = report(after)
    old = a[:cohorts].to_h { |row| [cohort_fields(row), row] }
    new = b[:cohorts].to_h { |row| [cohort_fields(row), row] }
    paired = (old.keys & new.keys).sort_by(&:to_s).map do |key|
      baseline, candidate = old.fetch(key), new.fetch(key)
      base_ms = baseline.dig(:wall_ms, :p50) || baseline.dig(:wall_ms, :min)
      new_ms = candidate.dig(:wall_ms, :p50) || candidate.dig(:wall_ms, :min)
      { key: key, before_runs: baseline[:runs], after_runs: candidate[:runs],
        before_wall_ms: base_ms, after_wall_ms: new_ms,
        speedup_pct: ((base_ms - new_ms) / base_ms * 100.0).round(3),
        repeated: baseline[:runs] >= 2 && candidate[:runs] >= 2 }
    end
    { schema: 'sibambo-perf-compare-v1', before_invalid: a[:invalid_rows],
      after_invalid: b[:invalid_rows], paired: paired, unmatched_before: old.keys - new.keys,
      unmatched_after: new.keys - old.keys,
      note: 'Pairs require identical source SHA, engine/profile/mode/cache, host and SketchUp/Ruby versions. Runtime SHA/RBZ may change by design. Speedup is descriptive, not host certification.' }
  end

  def cohort_fields(r)
    r.values_at(:model_sha256, :wire_engine_id, :profile, :mode, :cache, :host_id, :sketchup_version, :ruby_version)
  end

  def load_rows(paths)
    raise ArgumentError, 'provide one or more JSON observation files' if paths.empty?
    paths.flat_map do |path|
      parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))
      parsed.is_a?(Array) ? parsed : [parsed]
    end
  end

  def cli(argv)
    command = argv.shift
    if command == 'compare'
      raise ArgumentError, 'compare expects BEFORE.json AFTER.json' unless argv.size == 2
      puts JSON.pretty_generate(compare(load_rows([argv[0]]), load_rows([argv[1]])))
      return
    end
    unless %w[validate report].include?(command)
      raise ArgumentError, 'usage: ruby trace_harness.rb validate|report FILE.json [FILE.json ...] or compare BEFORE.json AFTER.json'
    end
    rows = load_rows(argv)
    summary = report(rows)
    if command == 'validate'
      puts JSON.pretty_generate(input_rows: summary[:input_rows], valid_rows: summary[:valid_rows],
                                invalid_rows: summary[:invalid_rows],
                                qualified_native_rows: summary[:qualified_native_rows],
                                synthetic_rows: summary[:synthetic_rows])
      exit 1 unless summary[:invalid_rows].empty?
    else
      puts JSON.pretty_generate(summary)
      exit 1 unless summary[:invalid_rows].empty?
    end
  rescue ArgumentError, JSON::ParserError, Errno::ENOENT => e
    warn "#{e.class}: #{e.message}"
    exit 2
  end
end

SibamboPerf.cli(ARGV) if $PROGRAM_NAME == __FILE__
