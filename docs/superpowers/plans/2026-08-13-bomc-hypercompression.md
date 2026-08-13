# BOMC Hypercompression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add BOMC 1.0, a deterministic single-file compiled building container that preserves the canonical graph without a production JSON manifest and is directly decodable into browser-friendly arrays.

**Architecture:** Compile the existing Canonical v3 graph into numeric, columnar sections behind a fixed header and section directory. Choose position, UV, normal, transform, integer-width, and per-section compression representations through explicit error gates and measured byte comparisons; embed content-hash-deduplicated texture bytes. Keep a standalone pure-Ruby decoder and JSON adapter as the differential oracle, and retain Canonical JSON, BOME2, and Model-Eval JSON unchanged.

**Tech Stack:** Ruby 2.5-compatible standard library (`digest`, `json`, `zlib`, `tmpdir`, `fileutils`), little-endian `Array#pack` layouts, PowerShell packaging, Markdown format/benchmark documentation.

## Global Constraints

- Do not open, launch, or automate SketchUp during automated development.
- Do not use Computer Use.
- Do not remove or change the contracts of Canonical JSON, BOME2, or Model-Eval JSON.
- The compiled extension is `.bomc`, format version is BOMC 1.0, and one file contains every required runtime resource.
- Production BOMC contains no JSON manifest and omits stable-ID/provenance mappings; debug BOMC carries those mappings in a compact binary section.
- Preserve definitions and instances; never occurrence-expand shared geometry.
- Never delete eligible geometry or visual detail to reduce size.
- Quantization is permitted only after positional, area, topology, winding, and transform error gates pass.
- UV values remain signed and unbounded; never clamp negative values or values greater than one.
- Section ordering, dictionaries, padding, compression, and texture ordering are deterministic.
- Corruption checks use CRC32 per stored section; unknown section types are skipped by the decoder.
- Automated validation uses pure Ruby fixtures, existing exported JSON, and deterministic synthetic fixtures only.
- Required final acceptance line: `REAL SKETCHUP COMPILED-FORMAT ACCEPTANCE: PENDING USER TEST`.

---

### Task 1: Container primitives and strict parser

**Files:**
- Create: `bom_engine/bomc_format.rb`
- Create: `bom_engine/tests/test_bomc.rb`

**Interfaces:**
- Produces: `BOMEngine::BOMC::Container.pack(sections, flags:) -> String`
- Produces: `BOMEngine::BOMC::Container.parse(bytes, verify_checksums: true) -> Hash`
- Produces: `BOMEngine::BOMC::Binary.write_varuint`, `read_varuint`, `write_zigzag`, `read_zigzag`, `pack_indices`, and `unpack_indices`.

- [x] **Step 1: Write failing header, directory, varint, adaptive-width, checksum, and unknown-section tests**

```ruby
bytes = BOMEngine::BOMC::Container.pack([
  { type: 1, count: 3, bytes: "abc".b, compress: false },
  { type: 65_000, count: 1, bytes: "future".b, compress: false }
], flags: BOMEngine::BOMC::PROFILE_PRODUCTION)
parsed = BOMEngine::BOMC::Container.parse(bytes)
assert(bytes.byteslice(0, 8) == "BOMC\r\n\x1a\n".b, 'BOMC magic')
assert(parsed[:header][:header_bytes] == 32, 'fixed header is 32 bytes')
assert(parsed[:header][:directory_entry_bytes] == 40, 'directory entry is 40 bytes')
assert(parsed[:sections].map { |section| section[:type] } == [1, 65_000], 'unknown section survives directory parse')
```

- [x] **Step 2: Run the focused test and confirm it fails because `bomc_format.rb` is absent**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: load failure naming `bomc_format`.

- [x] **Step 3: Implement the 32-byte header, 40-byte directory entries, eight-byte alignment, deterministic section ordering, STORE/DEFLATE selection, CRC32 verification, overlap/bounds rejection, and binary primitives**

```ruby
HEADER_PACK = 'a8vvVVVQ<'.freeze
DIRECTORY_PACK = 'vCCQ<Q<Q<VVV'.freeze
MAGIC = "BOMC\r\n\x1a\n".b.freeze
ENDIAN_MARKER = 0x0102_0304
```

- [x] **Step 4: Run the focused test and confirm all Task 1 assertions pass**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: exit 0 with header, directory, unknown-section, and corruption assertions passing.

### Task 2: Error-gated stream codecs

**Files:**
- Create: `bom_engine/bomc_codecs.rb`
- Modify: `bom_engine/tests/test_bomc.rb`

**Interfaces:**
- Produces: `PositionCodec.encode(values, loops:) -> { bytes:, codec:, origin:, scale:, errors:, candidates: }`
- Produces: `PositionCodec.decode(block) -> Array<Float>`
- Produces: `NormalCodec.encode(normals)`, `NormalCodec.decode(bytes, count)` using octahedral 2xInt16 after an angular error gate.
- Produces: `UVCodec.encode(pairs)`, `UVCodec.decode(block)` with Float32, Float16, Int16 scale/bias, and delta-varint candidates.
- Produces: `TransformCodec.encode(transforms)`, `TransformCodec.decode(bytes, count)` with Float64 3x4, Float32 3x4, and decomposed quaternion/scale candidates.

- [x] **Step 1: Add failing literal tests for negative/greater-than-one UV, mirrored and non-uniform transforms, holes/winding, codec error metrics, and deterministic candidate selection**

```ruby
uv = [[-2.5, 3.25], [4.75, -0.125], [1.0, 1.0]]
encoded = BOMEngine::BOMC::UVCodec.encode(uv.flatten)
decoded = BOMEngine::BOMC::UVCodec.decode(encoded)
assert(decoded.each_with_index.all? { |value, index| (value - uv.flatten[index]).abs <= 1.0e-4 }, 'UV range and error gate')

mirror = [-2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0.5, 0, 7, -4, 2, 1]
decoded_transform = BOMEngine::BOMC::TransformCodec.decode(BOMEngine::BOMC::TransformCodec.encode([mirror]))[0]
assert(max_delta(mirror, decoded_transform) <= 1.0e-5, 'mirror and non-uniform transform gate')
```

- [x] **Step 2: Run the focused test and confirm the missing codec constants cause the expected failure**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: failure naming `PositionCodec`, `NormalCodec`, `UVCodec`, or `TransformCodec`.

- [x] **Step 3: Implement position candidate measurement and choose the smallest compressed candidate that passes the 1 mm position gate and 0.1%/1e-6 m2 area gate**

Candidate encodings are Float64 absolute, Float32 local-origin, Int32 quantized, Int16 quantized, and quantized delta zigzag-varint. Record literal max, p95, and RMS point errors and reject non-finite inputs.

- [x] **Step 4: Implement octahedral normals, UV candidates without clamping, and hybrid per-transform candidate selection**

Normals must remain within 0.1 degree. UV candidates must remain within `1e-4` Euclidean UV units. A transform uses the smallest candidate within `1e-5` matrix-element error; decomposition is rejected for shear/non-orthogonal bases.

- [x] **Step 5: Run the focused test and confirm every codec round-trip and error assertion passes**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: exit 0 with position, normal, UV, mirror, non-uniform scale, and winding tests passing.

### Task 3: Canonical adapter, compiled writer, and standalone decoder

**Files:**
- Create: `bom_engine/bomc_model_adapter.rb`
- Create: `bom_engine/bomc_writer.rb`
- Create: `bom_engine/bomc_decoder.rb`
- Modify: `bom_engine/tests/test_bomc.rb`

**Interfaces:**
- Produces: `BOMC::ModelAdapter.from_canonical(graph, base_path: nil) -> Hash`
- Produces: `BOMC::ModelAdapter.from_model_eval(payload, base_path: nil) -> Hash`
- Produces: `BOMCWriter.pack(graph, profile: :production, base_path: nil) -> { bytes:, metrics: }`
- Produces: `BOMCWriter.write(path, graph, profile: :production, base_path: nil) -> Hash`
- Produces: `BOMCDecoder.decode(bytes) -> logical Hash`
- Produces: `BOMCDecoder.read(path) -> logical Hash`

- [x] **Step 1: Add a failing canonical fixture test that covers material/tag tables, face holes, semantics, UV, visual edges, shared definitions, nested owner definitions, textures, and fallback accounting**

```ruby
result = BOMEngine::BOMCWriter.pack(complex_graph, profile: :production)
decoded = BOMEngine::BOMCDecoder.decode(result[:bytes])
assert(decoded[:meshes].length == complex_graph[:meshes].length, 'mesh count')
assert(decoded[:instances].length == complex_graph[:nodes].length, 'instance hierarchy count')
assert(decoded[:coverage][:unaccounted] == 0, 'all geometry is accounted')
assert(decoded[:textures].length == 1, 'duplicate texture bytes are emitted once')
```

- [x] **Step 2: Run the test and confirm it fails on the absent writer/decoder boundary**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: failure naming `BOMCWriter` or `BOMCDecoder`.

- [x] **Step 3: Implement a deterministic shared dictionary and numeric enum tables**

Production interns material/component names and semantic labels once, uses numeric surface/orientation/node/role enums, and never interns stable IDs or classification provenance. Debug additionally interns IDs, persistent IDs, provenance, and coverage ledger strings.

- [x] **Step 4: Implement columnar material, tag, face, definition, and instance sections with adaptive widths and documented sentinels**

Use width 1 with sentinel `255` when the referenced count is at most 255, width 2 with sentinel `65535` up to 65535, and width 4 with sentinel `0xffffffff` otherwise. Pack boolean state into flags and reconstruct face loop/triangle offsets from stored counts.

- [x] **Step 5: Implement analytical, visual, and resource streams**

Positions, topology, normals, UVs, transforms, and visual edges are separate sections. Area, orientation, and azimuth are recomputed by the decoder. Texture blobs are ordered by SHA256, deduplicated by bytes, stored without base64, and referenced numerically from materials.

- [x] **Step 6: Implement production/debug profile separation and the reference decoder**

The decoder must parse directory entries before sections, reject checksum/bounds/overlap/reference failures, skip unknown section types, and return arrays/hashes without relying on SketchUp or Ruby serialization.

- [x] **Step 7: Run the focused test and confirm the compiled logical fixture round-trips**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: exit 0 with all canonical, profile, texture, hierarchy, and coverage assertions passing.

### Task 4: Differential validation, determinism, and scaling corpus

**Files:**
- Create: `bom_engine/bomc_validator.rb`
- Create: `bom_engine/tests/fixtures/bomc_medium.json`
- Modify: `bom_engine/tests/test_bomc.rb`

**Interfaces:**
- Produces: `BOMCValidator.compare(source, decoded, tolerances:) -> Hash`
- Produces: `BOMCValidator.validate!(source, decoded, tolerances:) -> Hash`
- Produces: `BOMC::Fixtures.shared_definition(instance_count) -> Hash` in the test file.

- [x] **Step 1: Add failing differential assertions for positions, topology, holes, winding, normals, UV, transforms, visual edges, fallback, textures, and counts**

```ruby
comparison = BOMEngine::BOMCValidator.validate!(source, decoded)
assert(comparison[:positions][:max_error_m] <= 0.001, 'differential position tolerance')
assert(comparison[:normals][:max_angular_error_deg] <= 0.1, 'differential normal tolerance')
assert(comparison[:uv][:max_error] <= 1.0e-4, 'differential UV tolerance')
assert(comparison[:topology][:exact], 'topology, holes, and winding are exact')
```

- [x] **Step 2: Run the test and confirm the absent validator is the expected failure**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: failure naming `BOMCValidator`.

- [x] **Step 3: Implement the differential validator with independently computed literal tolerances and disposition checks**

Reject any count/reference/topology/texture mismatch and any nonzero `unaccounted`. Report maximum, p95, and RMS errors rather than using the writer's self-reported metrics as the oracle.

- [x] **Step 4: Add deterministic byte equality and 1/10/100/1,000/10,000 instance scaling tests**

```ruby
sha1 = Digest::SHA256.hexdigest(BOMEngine::BOMCWriter.pack(graph)[:bytes])
sha2 = Digest::SHA256.hexdigest(BOMEngine::BOMCWriter.pack(graph)[:bytes])
assert(sha1 == sha2, 'same logical input produces identical BOMC bytes')
sizes = [1, 10, 100, 1_000, 10_000].map { |count| compiled_size(shared_definition(count)) }
assert(geometry_section_sizes.uniq.length == 1, 'shared geometry payload remains constant')
```

- [x] **Step 5: Run the focused suite and confirm differential, deterministic, corruption, and scaling assertions pass**

Run: `ruby bom_engine/tests/test_bomc.rb`

Expected: exit 0 and `BOMC Tests: ALL PASSED`.

### Task 5: Preferred exporter integration and one-file texture staging

**Files:**
- Create: `bom_engine/bomc_extension.rb`
- Create: `bom_engine_hypercompression_loader.rb`
- Create: `bom_engine/tests/test_bomc_extension.rb`

**Interfaces:**
- Produces: `BOMCExtension.output_path(model) -> String`
- Produces: `BOMCExtension.export(model, output_path:, profile: :production) -> Hash`
- Registers a user-facing `Export Compiled BOMC...` command without removing existing menus or exporters.

- [x] **Step 1: Add a failing pure-Ruby integration test using minimal SketchUp/UI stubs**

```ruby
path = BOMEngine::BOMCExtension.output_path(fake_model('RUMAH_L.skp'))
assert(path.end_with?('RUMAH_L.bomc'), 'compiled output is one .bomc file')
assert(BOMEngine::BOMCExtension::DEFAULT_PROFILE == :production, 'production is preferred')
```

- [x] **Step 2: Run the focused test and confirm the missing extension boundary fails**

Run: `ruby bom_engine/tests/test_bomc_extension.rb`

Expected: load failure naming `bomc_extension`.

- [x] **Step 3: Implement the extension boundary and atomic publication**

Build the canonical graph once with edges and UV enabled. When SketchUp must materialize textures, write them to a temporary directory, let the BOMC writer embed and deduplicate the bytes, atomically rename the `.part` file, and remove only the owned temporary directory in `ensure`.

- [x] **Step 4: Run the pure extension test and the compiled suite**

Run: `ruby bom_engine/tests/test_bomc_extension.rb && ruby bom_engine/tests/test_bomc.rb`

Expected: both commands exit 0 without launching SketchUp.

### Task 6: Benchmarks and Model-Eval format contract

**Files:**
- Create: `bom_engine/tools/benchmark_bomc.rb`
- Create: `bom_engine/tools/codec_benchmark.py`
- Create: `BOM_COMPILED_FORMAT.md`
- Create: `BENCHMARK_REPORT.md`
- Create: `MANUAL_ACCEPTANCE.md`

**Interfaces:**
- `ruby bom_engine/tools/benchmark_bomc.rb --tiny ... --medium ... --complex ... --output BENCHMARK_REPORT.md`
- `python bom_engine/tools/codec_benchmark.py sections-dir results.json`

- [x] **Step 1: Implement the corpus runner against the tiny example, deterministic medium fixture, and largest existing Model-Eval JSON fixture**

The runner reports old JSON, old gzip/DEFLATE, BOMC bytes, per-section raw/stored bytes, codec choices/errors, decode stages, allocation estimates, and shared-instance scaling. It never reads `.skp` files.

- [x] **Step 2: Benchmark DEFLATE, Brotli, and Zstandard on extracted section bytes and benchmark conservative WebP only when Pillow reports encoder support**

The Python helper imports `zlib`, `brotli`, and `zstandard`, measures compression/decompression wall time with `time.perf_counter`, verifies decoded bytes, and records unavailable codecs explicitly. Texture transcoding is opt-in and is not selected unless byte savings, decode compatibility, and a conservative quality gate are all demonstrated.

- [x] **Step 3: Run benchmarks and write exact measured results into `BENCHMARK_REPORT.md`**

Run: `ruby bom_engine/tools/benchmark_bomc.rb --output BENCHMARK_REPORT.md`

Expected: exit 0 with tables for tiny, medium, complex, codec candidates, per-section attribution, decode timing, and 1-to-10,000 scaling.

- [x] **Step 4: Write `BOM_COMPILED_FORMAT.md` as the normative browser contract**

Document magic, version, header/directory bytes, enums, widths, endianness, alignment, sentinels, dictionaries, every section layout, position/topology/normal/UV/transform codecs, materials/textures, checksums, profiles, unknown-section skipping, pseudocode, migration from Canonical v3/Model-Eval JSON, and `ArrayBuffer`/`DataView`/`TypedArray` decoding guidance.

- [x] **Step 5: Write `MANUAL_ACCEPTANCE.md` with the user-owned SketchUp and later Model-Eval checks**

Require recording SKP/JSON/CleanPackage/BOMC bytes, export time, analytical/visual/fallback/excluded/unaccounted counts, definitions/instances/textures, `unaccounted = 0`, and visual inspection of windows, doors, railings, roof, facade detail, texture UV, and room analytical geometry.

### Task 7: Packaging, cross-version verification, focused commit, and push

**Files:**
- Create: `package_hypercompression.ps1`
- Create under `dist/bom_engine-hypercompression-rc-<sha>/`: RBZ, three Markdown handoff documents, `VERSION.txt`, and `CHECKSUMS.sha256`
- Create: `dist/bom_engine-hypercompression-rc-<sha>.zip`

**Interfaces:**
- `powershell -ExecutionPolicy Bypass -File package_hypercompression.ps1 -CommitSha <sha>` builds both the RC directory and outer ZIP.

- [x] **Step 1: Implement deterministic packaging with an owned temporary staging directory**

Package `bom_engine_hypercompression_loader.rb` as `bom_engine_loader.rb` plus the runtime `bom_engine/` tree, excluding tests, tools, graph caches, `.skp`, and generated benchmark intermediates. Verify the RBZ contains all BOMC runtime files and no tests or caches.

- [x] **Step 2: Run every standalone Ruby suite under Ruby 2.5 and Ruby 3.2**

Run each `bom_engine/tests/test_*.rb` that does not require real SketchUp under both interpreters. Record interpreter paths, versions, passed assertions, skipped SketchUp-only suites, and failures exactly.

- [x] **Step 3: Run fresh completion verification**

Run: `git diff --check`, BOMC focused suites, all standalone suites, deterministic SHA comparison, complex differential benchmark, and RBZ archive inspection. Expected: zero failures and no whitespace errors.

- [x] **Step 4: Create the focused commit without staging unrelated pre-existing changes**

Stage only BOMC files and any precisely isolated integration hunks. Run `git diff --cached --check` and inspect `git diff --cached --stat` before committing with message `feat: add BOMC compiled building format`.

- [x] **Step 5: Build final handoff using the committed SHA, write SHA256 checksums, and commit only reproducible handoff metadata if tracked by repository policy**

The RBZ and outer ZIP remain ignored artifacts if `.gitignore` excludes them; report absolute paths and checksums.

- [x] **Step 6: Push the current branch normally**

Run: `git push` without force. Record the final commit SHA and exact push result.

## Plan Self-Review

- Spec coverage: tasks cover the binary container, numeric directory, dictionaries/enums, columnar tables, adaptive widths/sentinels, error-gated positions/normals/UV/transforms, delta-varint topology, shared definitions, embedded/deduplicated textures, per-section compression, random access, profiles, checksums, reference decoding, differential validation, scaling, benchmarks, browser contract, packaging, and manual acceptance. Optional level-aware chunking and WASM remain deliberately unimplemented because definition-shared per-section random access already preserves future chunking and the selected DEFLATE path does not require WASM.
- Texture transcoding is benchmarked but remains opt-in; source bytes are the production default unless the measured compatibility and fidelity gate passes.
- Stable IDs are omitted only in production because the current Model-Eval compact runtime already operates on numeric table indices; debug retains migration mappings.
- Placeholder scan: no TBD/TODO/“similar to” placeholders are present.
- Type consistency: writer, container, codec, adapter, decoder, validator, extension, benchmark, and packaging interfaces use the same `BOMEngine::BOMC`/`BOMCWriter`/`BOMCDecoder` names throughout.
