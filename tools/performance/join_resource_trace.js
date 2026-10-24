// Align a native Windows resource JSONL stream with BOMC relative stage spans.
// Produces an independent D:-side report; never modifies the BOMC or sidecar.
'use strict';
const fs = require('node:fs');

const metrics = [
  'cpu_total_percent', 'ram_available_mb', 'ram_committed_percent',
  'process_working_set_bytes', 'process_private_bytes',
  'gpu_engine_percent_sum_for_pid', 'disk_total_bytes_per_second',
  'disk_avg_queue_length', 'sample_overhead_ms'
];

function summarize(trace, rows) {
  if (!trace.started_utc || !Array.isArray(trace.stages)) throw Error('Trace lacks UTC anchor/stages');
  const anchor = Date.parse(trace.started_utc);
  if (!Number.isFinite(anchor)) throw Error('Invalid performance trace UTC anchor');
  const start = rows.find(r => r.type === 'start');
  if (!start || start.schema !== 'sibambo-native-resource-sampler-v1') throw Error('Wrong resource schema');
  const samples = rows.filter(r => r.type === 'sample' && Number.isFinite(Date.parse(r.utc)))
    .map(r => ({...r, timestamp_ms: Date.parse(r.utc)}));
  const stages = trace.stages.map(stage => {
    const from = anchor + stage.started_ms, to = anchor + stage.finished_ms;
    const within = samples.filter(r => r.timestamp_ms >= from && r.timestamp_ms <= to);
    const aggregate = {};
    for (const key of metrics) {
      const values = within.map(r => r[key]).filter(v => typeof v === 'number' && Number.isFinite(v));
      aggregate[key] = values.length ? {
        avg: values.reduce((a,b) => a+b,0)/values.length,
        min: Math.min(...values), max: Math.max(...values)
      } : null;
    }
    return {
      id: stage.id, parent_id: stage.parent_id, name: stage.name,
      started_utc: new Date(from).toISOString(), finished_utc: new Date(to).toISOString(),
      wall_ms: stage.duration_ms, process_cpu_ms: stage.cpu_ms ?? null,
      sample_count: within.length, sampled_metrics: aggregate
    };
  });
  return {
    schema: 'sibambo-stage-resource-join-v1',
    process_id: start.process_id,
    process_start_utc: start.process_start_utc,
    resource_counter_availability: start.supported_counters,
    warning: 'Samples are approximate, GPU sum is not card utilization; disk _Total spans all drives. Empty stage samples mean unknown, never zero.',
    sample_count: samples.length,
    sample_overhead_max_ms: samples.length ? Math.max(...samples.map(r => r.sample_overhead_ms || 0)) : null,
    stages
  };
}

if (require.main === module) {
  const [tracePath, resourcePath, resultPath] = process.argv.slice(2);
  if (!tracePath || !resourcePath || !resultPath || !/^D:[\\/]/i.test(resultPath)) {
    throw Error('Usage: node join_resource_trace.js <performance.json> <resource.jsonl> D:\\...\\joined.json');
  }
  const trace = JSON.parse(fs.readFileSync(tracePath, 'utf8'));
  const rows = fs.readFileSync(resourcePath, 'utf8').trim().split(/\r?\n/).map(line => JSON.parse(line));
  fs.writeFileSync(resultPath, JSON.stringify(summarize(trace, rows), null, 2) + '\n');
  process.stdout.write(resultPath + '\n');
}
module.exports = {summarize};
