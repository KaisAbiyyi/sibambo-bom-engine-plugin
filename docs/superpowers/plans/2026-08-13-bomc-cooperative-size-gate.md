# BOMC Cooperative Export and Strict Size Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make BOMC export cooperative and cancellable on SketchUp's main thread while guaranteeing that a saved model never publishes a BOMC file whose byte count is greater than or equal to its source SKP.

**Architecture:** A time-and-item-budgeted controller yields a Fiber-driven export state machine through `UI.start_timer`; all SketchUp access stays on the UI thread, and only the detached canonical graph enters the compiler. BOMC 1.1 uses sparse optional sections and a compact 24-byte directory, then a deterministic size-gate compiler tries bounded lossless compression strategies against the captured SKP byte count before atomically publishing. Original efficient texture files are preferred over forced PNG staging, with staged PNG retained as a fidelity-safe fallback.

**Tech Stack:** Ruby 2.5-compatible standard library (`digest`, `fileutils`, `json`, `tmpdir`, `zlib`), SketchUp `UI.start_timer`/`Fiber`, little-endian BOMC binary layouts, pure-Ruby benchmarks/tests, PowerShell deterministic packaging and static installation.

## Global Constraints

- Never launch, automate, or interact with SketchUp during implementation or verification.
- SketchUp API access remains on the SketchUp main/event thread; no live entity enters a worker thread.
- Presets affect scheduling only and must produce byte-identical BOMC output for an identical graph and source-size constraint.
- Use both maximum items and maximum elapsed milliseconds per cooperative tick, with adaptive bounded batch sizing.
- A saved source passes only when `candidate_bomc_bytes < source_skp_bytes`; equality fails.
- An unsaved/missing source reports the size gate as unavailable and never invents an SKP size.
- Compression escalation is bounded, deterministic, and reuses the detached graph; it never removes geometry, textures, semantics, or analytical content.
- `unaccounted = 0` remains mandatory for every published candidate.
- Textures remain embedded in the single BOMC file, content-hash deduplicated, and never base64 encoded.
- Production omits debug/provenance mappings; debug retains them.
- Cancellation completes the current atomic operation, prevents later stages, removes owned `.tmp`/`.part` files, releases detached data, and restores UI state.
- Preserve unrelated dirty-worktree changes and stage only exact task files/hunks.
- Run supported suites under Ruby 2.5.9 and Ruby 3.2.11.
- Build the RC, statically install it to the verified SketchUp 2026 user Plugins directory, and do not open SketchUp.

---

### Task 1: BOMC 1.1 sparse sections and compact directory

**Files:**
- Modify: `bom_engine/bomc_format.rb`
- Modify: `bom_engine/bomc_writer.rb`
- Modify: `bom_engine/bomc_decoder.rb`
- Modify: `bom_engine/tests/test_bomc.rb`
- Modify: `BOM_COMPILED_FORMAT.md`

**Interfaces:**
- Produces: `BOMC::Container.pack(sections, flags:, compression_level:, compact_directory:) -> String`
- Produces: BOMC 1.1 compact directory entries of 24 bytes using uint32 offsets/sizes, with BOMC 1.0 40-byte directory decode compatibility.
- Produces: sparse optional section decoding driven by MODEL counts.

- [ ] **Step 1: Add failing tests for compact and legacy directories**

```ruby
compact = BOMC::Container.pack(sections, compact_directory: true)
legacy = BOMC::Container.pack(sections, compact_directory: false, version_minor: 0)
assert(BOMC::Container.read_directory(compact)[:header][:directory_entry_bytes] == 24, 'BOMC 1.1 uses compact directory entries')
assert(BOMC::Container.read_directory(legacy)[:header][:directory_entry_bytes] == 40, 'BOMC 1.0 fixed directory remains readable')
```

- [ ] **Step 2: Run `ruby bom_engine/tests/test_bomc.rb` and verify RED because compact-directory arguments/flags do not exist**

- [ ] **Step 3: Implement 24-byte descriptors and dual-version parsing**

Use `COMPACT_DIRECTORY_PACK = 'vCCVVVVV'`, set a header flag for compact descriptors, keep 8-byte payload alignment and CRC32, and fall back to the 40-byte descriptor when any offset/size exceeds uint32.

- [ ] **Step 4: Add failing tests that empty optional streams are absent and still decode as empty arrays**

```ruby
result = BOMCWriter.pack(empty_graph)
types = BOMC::Container.read_directory(result[:bytes])[:sections].map { |row| row[:type] }
assert(!types.include?(BOMC::SECTION_UVS), 'empty UV section is omitted')
assert(!types.include?(BOMC::SECTION_TEXTURE_BLOBS), 'empty texture blobs are omitted')
assert(BOMCDecoder.decode(result[:bytes])[:textures] == [], 'missing optional texture sections decode empty')
```

- [ ] **Step 5: Implement sparse production sections and conditional decoder requirements**

Always retain MODEL, STRINGS, DEFINITIONS, INSTANCES, TRANSFORMS, and COVERAGE. Omit zero-count MATERIALS, TAGS, NORMALS, UVS, VISUAL_EDGES, TEXTURE_TABLE/BLOBS, and FALLBACK; omit geometry streams only when MODEL declares zero corresponding rows. Reject absent sections when MODEL declares nonzero content.

- [ ] **Step 6: Run BOMC tests under Ruby 2.5 and 3.2 and record fixed overhead before/after**

### Task 2: Central processing presets and adaptive cooperative controller

**Files:**
- Create: `bom_engine/bomc_processing.rb`
- Create: `bom_engine/tests/test_bomc_processing.rb`

**Interfaces:**
- Produces: `BOMCProcessing.settings(name, custom: nil) -> Hash`
- Produces: `BOMCProcessing::Controller.new(settings:, clock:, on_yield:, cancelled:)`
- Produces: `Controller#checkpoint(stage:, processed:, total:, candidate_bytes: nil, force: false)`.

- [ ] **Step 1: Add failing literal tests for Light, Balanced, Fast, and bounded Custom behavior**

```ruby
assert(settings(:light) == { mode: :light, max_items: 64, max_ms: 10.0, min_items: 1, max_items_limit: 512 }, 'Light contract')
assert(settings(:balanced)[:max_ms] == 24.0, 'Balanced is the default 24 ms budget')
assert(settings(:fast)[:max_ms] == 60.0, 'Fast uses a bounded 60 ms budget')
```

- [ ] **Step 2: Run the processing test and verify RED because `bomc_processing.rb` is absent**

- [ ] **Step 3: Implement item/time gating and adaptive next-batch sizing**

Yield when either the current adaptive item target or `max_ms` is reached. Increase target by at most 50% when elapsed time is below 60% of budget; decrease proportionally when it exceeds budget; clamp to preset min/max bounds.

- [ ] **Step 4: Add cancellation and deterministic-scheduling tests using an injected monotonic clock**

Assert cancellation is checked at every checkpoint, no `sleep` occurs, and event counts differ while the ordered work result remains identical.

- [ ] **Step 5: Run the new test under Ruby 2.5 and 3.2 and verify GREEN**

### Task 3: Strict size gate and bounded lossless escalation

**Files:**
- Create: `bom_engine/bomc_size_gate.rb`
- Create: `bom_engine/tests/test_bomc_size_gate.rb`
- Modify: `bom_engine/bomc_writer.rb`

**Interfaces:**
- Produces: `BOMCSizeGate.source_info(path) -> { path:, bytes:, available: }`
- Produces: `BOMCSizeGate.evaluate(candidate_bytes:, source_info:) -> :pass | :fail | :unavailable`
- Produces: `BOMCSizeGate.compile(graph:, source_info:, base_path:, checkpoint:) -> Result`
- Raises: `BOMCSizeGate::TargetNotMet` containing source bytes, best candidate bytes, delta, strategy attempts, and dominant sections.

- [ ] **Step 1: Add failing boundary tests for smaller/pass, equal/fail, larger/fail, and unsaved/unavailable**

```ruby
assert(evaluate(candidate_bytes: 99, source_info: { available: true, bytes: 100 }) == :pass, 'strictly smaller passes')
assert(evaluate(candidate_bytes: 100, source_info: { available: true, bytes: 100 }) == :fail, 'equal size fails')
assert(evaluate(candidate_bytes: 101, source_info: { available: true, bytes: 100 }) == :fail, 'larger size fails')
assert(evaluate(candidate_bytes: 1, source_info: { available: false }) == :unavailable, 'unknown source is explicit')
```

- [ ] **Step 2: Run the size-gate test and verify RED because the gate is absent**

- [ ] **Step 3: Add writer compression-level and minimal-metadata controls without changing geometry/codecs**

Strategies are deterministic: `standard` (sparse/compact, DEFLATE 6), `compact` (sparse/compact, DEFLATE 9), and `maximum_lossless` (DEFLATE 9 plus omission of optional source filename/model-name references). All use identical geometry, precision, texture bytes, semantics, definitions, and instances.

- [ ] **Step 4: Implement escalation and atomic publication contract**

Compile each strategy from the same detached graph, release each failed candidate byte string before the next pass, stop at first strict pass, and never publish a failed candidate. If all fail, return an actionable dominant-section report.

- [ ] **Step 5: Add a regression test proving escalation never changes coverage or moves eligible geometry to excluded**

Decode each candidate and assert exact topology/counts plus `coverage[:unaccounted] == 0` and identical coverage disposition.

- [ ] **Step 6: Run size-gate and BOMC suites under both Rubies and verify GREEN**

### Task 4: Cooperative BOMC export state machine and cancellation

**Files:**
- Create: `bom_engine/bomc_export_job.rb`
- Add/modify: `bom_engine/conversion_job.rb`
- Add/modify: `bom_engine/ui/conversion_dialog.html`
- Modify exact batching hunks only: `bom_engine/canonical_graph_builder.rb`
- Modify: `bom_engine/material_extractor.rb`
- Modify: `bom_engine/bomc_writer.rb`
- Modify: `bom_engine/bomc_extension.rb`
- Create: `bom_engine/tests/test_bomc_export_job.rb`
- Modify/add: `bom_engine/tests/test_conversion_job.rb`

**Interfaces:**
- Produces: `BOMCExportJob.run(model:, output_path:, settings:, context:) -> Result`
- Uses stages: INITIALIZE, SCAN_MODEL, SNAPSHOT_MATERIALS, SNAPSHOT_TEXTURES, SNAPSHOT_ENTITIES, CLASSIFY, BUILD_COVERAGE, BUILD_DEFINITIONS, BUILD_INSTANCES, COMPILE_METADATA, ENCODE_POSITIONS, ENCODE_TOPOLOGY, ENCODE_NORMALS, ENCODE_UV, ENCODE_TRANSFORMS, ENCODE_TEXTURES, COMPRESS_SECTIONS, WRITE_CONTAINER, SIZE_GATE, VALIDATE, DONE.

- [ ] **Step 1: Add a failing pure-Ruby state-machine test with injected snapshot/compiler boundaries**

Assert ordered stage events, source path/size captured once, strict gate result propagated, and detached graph cleared in `ensure`.

- [ ] **Step 2: Run the job test and verify RED because `BOMCExportJob` is absent**

- [ ] **Step 3: Implement Fiber/timer cooperative execution using the central controller**

`ConversionJob` passes a callable context to work. The controller decides when to `Fiber.yield`; timer ticks resume exactly one bounded slice. Cancellation raises only at checkpoints, closes owned files, removes `.tmp`/`.part`, clears graph/candidate references, stops the timer, and updates the dialog.

- [ ] **Step 4: Remove the unused BOMC spatial-analysis traversal and batch the required snapshot**

Pass `spatial: {}` because BOMC does not serialize `analysis`. Add progress checkpoints before/after each material/texture atomic write and through entity/face/UV loops in CanonicalGraphBuilder; call the central controller at item granularity (`batch_size: 1`).

- [ ] **Step 5: Add checkpoints inside detached writer/codec loops and between every raw-section compression**

Checkpoint callbacks must never affect candidate bytes or candidate selection. One indivisible texture write or zlib call remains an atomic step and is reported honestly in the max-tick benchmark.

- [ ] **Step 6: Expand progress payload/UI**

Show stage, processed/total, percent, mode, elapsed, source SKP bytes, current candidate bytes, and final savings only after gate PASS. Gate failure shows source, best candidate, delta, and dominant sections.

- [ ] **Step 7: Run job, cancellation, extension, and BOMC suites under both Rubies**

### Task 5: Preserve efficient source textures and report texture dominance

**Files:**
- Modify: `bom_engine/material_extractor.rb`
- Modify: `bom_engine/bomc_extension.rb`
- Modify: `bom_engine/bomc_model_adapter.rb`
- Add tests in: `bom_engine/tests/test_bomc_export_job.rb`

**Interfaces:**
- Produces: material texture metadata containing `source_path` and `staged_path`.
- Produces: deterministic source selection that prefers a readable PNG/JPEG/WebP source file and falls back to the SketchUp-written PNG.

- [ ] **Step 1: Add a failing test with a small JPEG source and larger staged PNG**

Assert the embedded bytes/hash/media type come from JPEG while placement dimensions remain unchanged; when the source is missing, assert staged PNG is embedded.

- [ ] **Step 2: Run the test and verify RED because BOMC currently overwrites `source_path` with staged PNG**

- [ ] **Step 3: Preserve both paths and select the original efficient supported source**

Never recompress JPEG blindly. Retain staged PNG as the fidelity-safe fallback. Continue SHA256 dedup and referenced-only embedding.

- [ ] **Step 4: Add texture-dominance fields to size-gate failure reports and verify GREEN**

### Task 6: Preset determinism and responsiveness benchmark corpus

**Files:**
- Create: `bom_engine/tools/benchmark_bomc_cooperative.rb`
- Create: `BOMC_COOPERATIVE_BENCHMARK.md`
- Modify: `bom_engine/tests/test_bomc_processing.rb`
- Modify: `bom_engine/tests/test_bomc_size_gate.rb`

**Interfaces:**
- Benchmarks: synchronous baseline, batch=1, Light, Balanced, Fast, and Custom/huge batch.
- Reports: total time, maximum uninterrupted interval, yield count, old/new bytes, section attribution, empty-descriptor bytes, metadata bytes, selected size-gate strategy, and SHA256.

- [ ] **Step 1: Build deterministic tiny, small texture-heavy, medium architectural, and complex existing-export fixtures**

The stress fixture includes shared/nested definitions, polygons, UV, materials, embedded textures, and 10,000 instances without SketchUp.

- [ ] **Step 2: Add a failing cross-preset SHA test**

Compile identical input/source constraint with batch=1, Light, Balanced, Fast, and huge Custom. Assert all SHA256 values and decoded logical models match exactly.

- [ ] **Step 3: Implement and run the cooperative benchmark under Ruby 3.2**

Use an injected workload clock for deterministic preset-control tests and real monotonic timing for the report. Record maximum uninterrupted intervals rather than only averages.

- [ ] **Step 4: Run the complex differential validator and assert `unaccounted = 0`**

- [ ] **Step 5: Write exact measured before/after tables to `BOMC_COOPERATIVE_BENCHMARK.md`**

### Task 7: Documentation, RC packaging, static installation, commit, and push

**Files:**
- Modify: `BOM_COMPILED_FORMAT.md`
- Modify: `MANUAL_ACCEPTANCE.md`
- Modify: `bom_engine_hypercompression_loader.rb`
- Modify: `package_hypercompression.ps1`
- Create: `install_hypercompression.ps1`
- Create under `dist/bom_engine-cooperative-rc-<sha>/`: RBZ, specs/reports, version, checksums

**Interfaces:**
- `package_hypercompression.ps1 -CommitSha <sha>` builds a deterministic RBZ/outer ZIP from the commit.
- `install_hypercompression.ps1 -RbzPath <path> -CommitSha <sha>` installs statically to `%APPDATA%\SketchUp\SketchUp 2026\SketchUp\Plugins` without starting a process.

- [ ] **Step 1: Update BOMC 1.1, size-gate, scheduling, failure, and manual acceptance documentation**

Manual tests explicitly cover the ~3 MB SKP, RUMAH L, Light cancellation/responsiveness, Balanced, and repeat SHA.

- [ ] **Step 2: Add a safe installer that validates the exact destination and archive entries**

Install only `bom_engine_loader.rb` and `bom_engine/` into the verified nested SketchUp 2026 user Plugins path, replace the active BOMC development copy via owned staging/backup, never touch unrelated extensions, and verify installed loader/runtime hashes against the RBZ.

- [ ] **Step 3: Run fresh completion verification on an isolated index/commit snapshot**

Run `git diff --check`, Ruby syntax, BOMC/processing/gate/job/extension/legacy standalone suites on Ruby 2.5 and 3.2, deterministic SHA comparisons, corruption tests, stress benchmark, and package archive/checksum inspection.

- [ ] **Step 4: Commit only exact BOMC/cooperative files and isolated CanonicalGraphBuilder batching hunks**

Use message `feat: add cooperative BOMC export size gate`; preserve every unrelated semantic/core/schema/model change unstaged.

- [ ] **Step 5: Build final artifacts from the committed SHA and install without launching SketchUp**

Statically verify the installed loader declares the committed RC version, every required runtime file exists, and no second loader is introduced by this task.

- [ ] **Step 6: Push `main` normally and verify `origin/main` resolves to the final SHA**

## Plan Self-Review

- Spec coverage: all 36 requested areas map to sparse/compact format, central presets, adaptive batching, explicit stages, strict gate/escalation, source-size capture, texture preservation, memory cleanup, cancellation/UI, corpus/metrics, packaging/install, and Git tasks.
- Scope: cooperative scheduling and size gating are coupled at the export state machine and therefore belong in one plan; format changes and benchmarks remain independently testable tasks.
- Safety: no SketchUp launch, automation, process start, worker thread, geometry removal, fake source size, force Git operation, or broad plugin-directory deletion appears in the plan.
- Placeholder scan: implementation steps define exact interfaces, constants, boundaries, commands, and expected assertions; no deferred implementation placeholders remain.
- Type consistency: presets produce settings consumed by Controller; Controller/checkpoint is consumed by ConversionJob, CanonicalGraphBuilder, writer, and compiler; size-gate Result is consumed by the state machine and progress UI.
