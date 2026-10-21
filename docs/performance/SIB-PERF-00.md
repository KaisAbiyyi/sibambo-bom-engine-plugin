# SIB-PERF-00 — cloud-only export performance audit and PERF-00N handoff

**Task:** SIB-PERF-00 (P0) · **Date:** 2026-10-21 · **Evidence class:** SOURCE AUDIT / HISTORICAL, **not a new native benchmark**.  
**Read-only audited refs:** `main@fa426142ef1616197d8b391e0527538cd2218354` and unmerged F1J draft `codex/sib-f1j-active-exports-20261021@f7bc28fe285750e9ca97e50b9528d314cc90ea39`.  
**Ownership:** PERF-00 only writes this independent documentation, `tools/performance/`, and its separate harness tests. Producer/runtime, codec, RBZ, UI and native host remain claimed by SIB-F1J and successors. Nothing here is a release qualification.

## 1. Immutable identity and naming

| Forward UI name | Persisted/legacy engine ID | Active artifact | Physical exporter audited |
|---|---|---|---|
| **E1** | **e2** (old E2) | Canonical JSON 3.1 + gzip | `evolution_exporter.rb` → `evolution_canonical_writer.rb` |
| **E2** | **e3** (old E3) | CleanPKG 1.1 | `evolution_exporter.rb` → `evolution_cleanpkg_writer.rb` |
| **E3** | **e4** (old E4, lineup order **4**) | BOMC 1.2 | `bomc_extension.rb` → `bomc_export_job.rb` / `bomc_writer.rb` |

The original **e1 JSON v2** is retired from new exports, still historically readable. Research is retired from new exports. **Never renumber persisted IDs, historic provenance, readers, profile enum values, or lineup order.** New exports target **Exact and Visual**; retain legacy readback. F1J draft has runtime symbols `e1`, `e2`, `e3` for older aliases: these symbols **cannot be treated as forward display names** without the mapping above. PERF-04 owns eventual display-level changes.

## 2. Read-only call-path inventory and suspected cost centers

The audit identifies **where to measure**, not what is already faster. The draft F1J branch has `bom_engine/performance_trace.rb` with schema `sibambo-performance-trace-v1`, monotonic stage timers, optional CPU/GC/heap deltas, nested stage IDs and failure/cancellation receipts; this is reusable and must not be replaced in PERF-00.

| Engine/lane | Existing observed hook/path | Instrument or derive next at PERF-00N | Hypothesis to test, not conclusion |
|---|---|---|---|
| Shared capture | `evolution_exporter.rb`: `source_tree_hash`, `evolution_capture`; `evolution_document.rb`: `graph_detach`; `bomc_extension.rb` capture; `canonical_graph_builder.rb`: geometry/scene/material spans | entity/face/triangle counts, unique textures, bytes, capture calls, `image_rep` counts, source hash cost; repeated capture for Export All | repeated material + texture capture may dominate |
| E1 / legacy e2 | `evolution_canonical_writer.rb`: `e2_payload`, `e2_serialize`; `EvolutionStream`, `Zlib::GzipWriter` | separate DAG encoding / JSON, gzip CPU, disk writes and fsync, uncompressed/compressed bytes | serialization vs gzip vs disk bottleneck unresolved |
| E2 / legacy e3 | `evolution_cleanpkg_writer.rb`: `e3_binary_build`, `e3_zip_write`; `SectionWriter` / `DeterministicZip` | section counts/bytes, binary encode, repeated asset staging, ZIP wall/CPU/IO | ZIP and staging cost unresolved |
| E3 / legacy e4 | `bomc_export_job.rb`: source_info, snapshot, compile, validate, publish, 21 stage progression; `bomc_writer.rb` normalize/candidate/compress/hash | per-material semantic verify, JCM candidates, codec/transcode/decode, rejected variants, input/output pixels, hit/miss, SHA/bytes and cumulative budgets | texture/codec hot path likely but needs measured attribution |
| Export All | `bomc_extension.rb#export_all_profiles`: profiles loop and shared `candidate_cache`, per-profile receipts, partial-status manifest; Evolution multi-engine orchestration in claimed F1J | top-level all wall; sub-export receipt cross-links, cache reuse/hit/miss, source revision consistency, cancellation and partial-failure | repeated work possible, but avoid cache changes pre-baseline |
| UI / cancellation | `bomc_processing.rb#checkpoint`; `bomc_export_job.rb` stage transition; `evolution_exporter.rb` progress callbacks | callback emission time, count, monotonic elapsed, longest **UI silent gap**, final states and phase transitions | some slow inner loops may starve UI reporting |
| Resource usage | `PerformanceTrace` provides GC/heap deltas, *not OS peak RSS* | OS peak RSS sampled by native host helper; record unknown as null; distinguish heap from RSS | memory ceiling unknown |

Specific probes: `bomc_sketchup_colorize.rb#verify` performs per-pixel RGB/HLS and hash comparisons with an optional deadline (30s per call noted in P0 issue); `bomc_jpeg_color_map.rb` computes correction candidates and pixel reconstruction; `bomc_texture_encoder.rb` runs bounded external cwebp/dwebp processes; `bomc_extension.rb` stages candidate publication and independent validation. **Aggregate all invocations by material and by stage**; a per-call timeout does not impose a total run cap. Count retries, decode/re-encode, fallback, and codec subprocess time, with exact bytes/hashes.

## 3. Historical evidence — do not mix with new native timing

| Evidence | Producer/context | Supports | Does not support |
|---|---|---|---|
| `bom_engine/benchmarks/results/BASELINE_PROFILE_BENCHMARK.md` | `529daa3...`, 2026-08-29, 6 fixtures | legacy fixture payload size and coverage | current native export wall time |
| `bom_engine/benchmarks/results/BOMC_PROFILE_BENCHMARK.md` | `e51f504...`, 2026-09-07, 9/21 historical rows pass; missing real source texture/scene/clip evidence | incomplete fixture corpus and size comparisons | device/host fidelity or latency |
| `bom_engine/benchmarks/results/EVOLUTION_PROFILE_BENCHMARK.md` | `49ca51d...`, 2026-09-08, 21/21 fixture-profile status READY | old three-profile fixture outcomes | current dual-profile E1/E2/E3 timing or certification |
| `bom_engine/benchmarks/results/BOMC_TEXTURE_ENCODER_RUNTIME.md` | old SketchUp 26.2.243, Ruby 3.2.2, Windows libwebp tiny 2×1 | specific previous WebP encode/decode and alpha proof | meaningful heavy-texture throughput |
| [P0 issue #7](https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin/issues/7) | >180 min E3/BOMC Exact historical report; earlier RUMAH Y extraction/colorization observations | motivating failure-mode priority | qualification or reproducible time on F1J candidate |

Important: `EVOLUTION_PROFILE_BENCHMARK.md` includes tiny synthetic datasets with minimal triangles; never use its extreme compression ratios as evidence of real SKP capture efficiency. Differences in model source, host, producer SHA, source capture, profile, and cache invalidate paired speedup claims.

## 4. Trace-contract extension: observation envelope, not a producer schema rewrite

The F1J producer emits `sibambo-performance-trace-v1`. PERF-00 defines an **external normalization/envelope** `sibambo-perf-observation-v1`; no producer modifications required. `tools/performance/trace_harness.rb` validates and summarizes these external observations. Example is in `tools/performance/fixtures/synthetic-observation.json`. `measurement_kind: synthetic` remains explicitly non-native, never qualifying. Planned native observations are **host-collected measurements**, not JSON metadata used as proof of hardware by itself.

Required observation fields: `source.model_id` (non-private pseudonym), `source.sha256` (source SKP digest), `source.bytes`; `environment.os, sketchup_version, ruby_version, source_tree_sha256, rbz_sha256, host_id`; `export.wire_engine_id` (`e2` / `e3` / `e4`), `profile` (exact/visual), `mode` (single/export_all), `cache` (cold/warm), `replicate` (1+); `outcome.status, wall_ms, artifact_bytes, artifact_sha256, fidelity`; `trace` (existing producer v1 receipt); and arrays `materials, checkpoints`.

Per-material record: salted/non-sensitive `material_id`, `pixels`, source/output bytes and SHA256, `codec`, `transcode_ms`, `verify_ms`, `encode_ms`, `decode_ms`, `candidate_attempts`, `rejected_candidates`, `cache_hits/misses`, `fallback_reason`, and `exact_rgba_alpha_pass`. Distinguish per-material totals from whole-model exclusive timings (nested timing must not double count). Checkpoint records: `elapsed_ms`, `stage`, `phase`, `processed`, `total`, `force`; calculate p95/max UI silence from adjacent timestamps plus run boundaries. For native runs **peak_rss_bytes is mandatory**; no substitution with GC heap estimate. Host helper/sampler frequency, source of process RSS and overhead must be included in notes.

The harness checks type/range, enumerations, SHA format, trace parent-stage references and temporal ordering, negative/inconsistent counters, native provenance completeness, material accounting, and checkpoint order. Failed/missing evidence is reported as **invalid/unqualified**, never silently dropped. It summarizes elapsed p50/p95 only for repeated comparable runs. Keep warning vs rejection separated; never rewrite the raw evidence to make it pass.

## 5. Native PERF-00N measurement protocol (after F1J lock release)

1. **Gate:** integrate/release F1J plus stacked PR #5/#6 as accepted; pin exact plugin commit/tree SHA, RBZ SHA, format/reader SHAs and Windows SketchUp/Ruby versions. Preserve installed artifacts and source data. Do not run until lock is released. Check disk output is on D:.
2. **Corpus:** five named, saved private source SKPs: e.g. house2, presentation20, SBOOST2, RUMAH L, RUMAH Y, with each source SHA + bytes pinned separately; never commit SKP bytes or private file paths. Validate corpus suitability for texture/scene/clip coverage.
3. **Matrix:** 5 models × 3 active engines × 2 profiles = **30 first-pass cells**. Measure single-engine cold and warm separately with at least three repetitions when practical (report n). Export All on same saved model each profile, with shared-capture/cache counters. Same host, processing policy and source model for paired comparisons.
4. **Measurement:** capture source tree hash, engine ID + mapped label, exact/visual, model identity hash, artifact SHA/size, wall/CPU, OS peak RSS and sampling provenance, per-stage elapsed/CPU, material/texture pixels, codec/verify/candidate rejections/bytes/hit-miss, longest checkpoint silence, file-IO bytes, every timeout/cancellation/failure.
5. **Correctness:** independent container readback and digest verification (not merely published manifest). Exact: equality for all supported captured RGBA **including alpha**, topology, UV, metadata; Visual: protected scene/room/analytical topology. Independent Rooms + Benchmark consumer proof. All non-comparable/unreadable/partially failed cells stay FAIL/PENDING, not successful samples.
6. **Acceptance:** paired before/after wall and percent reduction only where same source/host/engine/profile/cache are matched; output MiB, memory, failure rate, p50/p95 for repeated measurements. Report any regressions and overhead of the profiler (trace-on/off). Native validation needs manual owner signoff; no cloud green check may certify it.

Recommended trace hook additions **only after producer lock release**: wrap image readback and texture saving, material candidate search and each rejection/fallback, JCM pixel transform/correction, per-subprocess cwebp/dwebp, gzip writing, ZIP section/IO, validation/readback, per-profile Export All boundaries. Avoid raw texture bytes, filesystem paths, names identifying private customers, or secrets in exported telemetry.

## 6. Performance harness instructions

Standalone Ruby 3.2+ stdlib, no SketchUp or producer dependencies:

```sh
ruby tools/performance/trace_harness.rb validate tools/performance/fixtures/synthetic-observation.json
ruby tools/performance/trace_harness.rb report tools/performance/fixtures/synthetic-observation.json
ruby bom_engine/tests/test_perf_trace_harness.rb
```

`validate` is an **envelope conformance test, not native attestation**. `report` emits JSON containing invalid rows, coverage by engine/profile, per-stage metrics, checkpoint gaps and comparable descriptive statistics. The bundled fixture has `measurement_kind=synthetic`, no real performance numbers and may not appear in any native success table. Native data remains on D:, sanitized summaries may be published only after review.

## 7. Handoff for next worker

**SIB-PERF-00N** is a **Windows/SketchUp** prerequisite-gated job, not a cloud continuation. Required action after producer lock release: implement source-level instrumentation in an isolated runtime branch, capture a fresh baseline before optimizing, fill observation envelopes on native host, independently check correctness/readers, then hand measured bottlenecks to PERF-01 (E1), PERF-02 (E2), PERF-03 (E3). PERF-04 display relabel can proceed only with backward-compatible wire tests. Do not merge dependent draft producer PRs or alter native RBZ from this proof-only branch.

**Status:** Cloud source audit and contract/harness deliverable only; optimization gains **NOT MEASURED**, native certification **NOT RUN**.
