'use strict';
const assert = require('node:assert/strict');
const {summarize} = require('./join_resource_trace');
const trace = {
  started_utc: '2026-10-24T10:00:00.000Z',
  stages: [
    {id:'a',parent_id:null,name:'compile',started_ms:0,finished_ms:4000,duration_ms:4000,cpu_ms:3000},
    {id:'b',parent_id:'a',name:'semantic_verify',started_ms:1000,finished_ms:2000,duration_ms:1000,cpu_ms:500},
    {id:'c',parent_id:null,name:'publish',started_ms:9000,finished_ms:9500,duration_ms:500}
  ]
};
const rows = [
  {type:'start',schema:'sibambo-native-resource-sampler-v1',process_id:123,process_start_utc:'2026-10-24T09:59:00Z',supported_counters:{cpu:true,gpu:false}},
  {type:'sample',utc:'2026-10-24T10:00:01.500Z',cpu_total_percent:40,ram_available_mb:2000,gpu_engine_percent_sum_for_pid:null,sample_overhead_ms:30},
  {type:'sample',utc:'2026-10-24T10:00:03.000Z',cpu_total_percent:60,ram_available_mb:1800,sample_overhead_ms:70}
];
const joined = summarize(trace,rows);
assert.equal(joined.stages[0].sample_count,2);
assert.equal(joined.stages[0].sampled_metrics.cpu_total_percent.avg,50);
assert.equal(joined.stages[1].sample_count,1);
assert.equal(joined.stages[1].sampled_metrics.ram_available_mb.avg,2000);
assert.equal(joined.stages[1].sampled_metrics.gpu_engine_percent_sum_for_pid,null);
assert.equal(joined.stages[2].sample_count,0);
assert.equal(joined.stages[2].sampled_metrics.cpu_total_percent,null);
assert.equal(joined.sample_overhead_max_ms,70);
assert.throws(() => summarize({...trace, started_utc:null},rows));
console.log('Resource join contract PASS');
