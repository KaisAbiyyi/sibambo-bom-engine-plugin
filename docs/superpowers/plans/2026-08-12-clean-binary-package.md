# Clean Binary Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic `.cleanpkg` export containing a compact manifest, typed binary geometry buffers, and referenced texture assets without changing the existing Clean JSON or Clean Visual formats.

**Architecture:** Compile the unchanged CleanV1 logical document first, then encode its high-volume numeric fields into aligned little-endian sections in `buffers.bin`. `manifest.json` retains stable IDs and semantic metadata while replacing geometry, UV, transform, and high-frequency string references with typed section offsets and integer table indices. A standalone reference decoder reconstructs the logical CleanV1 document for round-trip validation.

**Tech Stack:** Ruby 2.5-compatible standard library (`Array#pack`, `Zlib`, JSON), existing deterministic ZIP writer, Minitest, JavaScript-compatible TypedArray layouts.

## Global Constraints

- Do not change geometry extraction, classification, coverage, precision settings, texture bytes, or existing JSON/Visual ZIP exports.
- Do not launch or automate SketchUp and do not modify Model-Eval.
- Binary data is deterministic, little-endian, 4-byte aligned except Float64 sections which are 8-byte aligned.
- Stable external IDs stay in the manifest; high-volume references use integer indices.
- Position error budget is `1.0e-6 m`; quantized Int32 positions use local origins and must fall back to Float64 when range or error gates fail.
- UVs are Float32, never clamped, and must preserve negative and repeated coordinates.
- Instance transforms are affine Float64 3x4 values reconstructed to the existing column-major 4x4 representation.
- Textures remain content-hash deduplicated and referenced-only.

---

### Task 1: Typed section writer and position codec

**Files:**
- Create: `bom_engine/clean_analysis/binary/section_writer.rb`
- Create: `bom_engine/clean_analysis/binary/position_codec.rb`
- Create: `bom_engine/tests/test_clean_binary_primitives.rb`

**Interfaces:**
- Produces: `SectionWriter#add(name, values, component_type:, components:, count: nil)` and `#bytes/#sections/#padding_bytes`.
- Produces: `PositionCodec.encode(points, tolerance: 1.0e-6)` returning `{ component_type:, values:, origin:, scale:, metrics: }`.
- Component types: `float32`, `float64`, `uint16`, `uint32`, `int32` using little-endian pack directives.

- [ ] Write RED tests for deterministic offsets, 4/8-byte alignment, Uint16/Uint32 bytes, quantized Int32 local positions, relative Float32 metrics, and Float64 fallback when Int32 range is exceeded.
- [ ] Run `ruby -I. bom_engine/tests/test_clean_binary_primitives.rb`; expect missing binary classes.
- [ ] Implement type packing, zero padding, section descriptors, percentile/RMS calculations, codec round-trip benchmarking, and codec selection.
- [ ] Run the focused test under Ruby 2.5 and 3.2; expect zero failures.

### Task 2: Structured CleanV1 binary encoder

**Files:**
- Create: `bom_engine/clean_analysis/binary/document_encoder.rb`
- Create: `bom_engine/tests/test_clean_binary_document.rb`

**Interfaces:**
- Consumes: an unchanged CleanV1 document Hash.
- Produces: `DocumentEncoder.encode(document)` returning `{ manifest:, buffers:, statistics: }`.
- Manifest identifier/version: `bom_engine_clean_package` / `1.0.0`; logical source identifier/version remain explicit.

- [ ] Write RED fixtures containing root surfaces with holes, definition-local geometry, nested/shared instances, visual edges, fallback geometry, materials, negative/repeated/rotated UVs, mirrored and non-uniform transforms, and complete coverage diagnostics.
- [ ] Assert manifest has no root/definition XYZ arrays, UV arrays, 4x4 transforms, or repeated material/definition strings in high-volume tables.
- [ ] Implement deterministic material/definition/instance index tables.
- [ ] Encode root and fallback position pools, loop vertex indices, loop offsets, polygon-loop offsets, normals, areas, material indices, and sparse front/back UV index streams.
- [ ] Encode definition-local positions once per definition, concatenated topology tables with per-definition ranges, local UV pools, material indices, sparse UV streams, and edge indices.
- [ ] Encode instance definition/material/parent indices plus Float64 affine 3x4 transforms; retain stable IDs and semantic instance metadata in the manifest.
- [ ] Encode visual-edge coordinates without dropping edge metadata.
- [ ] Assert index sections choose Uint16 when local maximum is `<=65535` and Uint32 otherwise.
- [ ] Run focused tests under both Ruby versions.

### Task 3: Reference decoder and logical round trip

**Files:**
- Create: `bom_engine/clean_analysis/binary/reference_decoder.rb`
- Extend: `bom_engine/tests/test_clean_binary_document.rb`

**Interfaces:**
- Produces: `ReferenceDecoder.decode(manifest_json_or_hash, buffers)` returning the reconstructed CleanV1 Hash.

- [ ] Write RED round-trip assertions for topology order, holes, stable IDs, semantic types, material references, UVs, normals, areas, transforms, nested/shared definitions, visual edges, diagnostics, and `coverage.unaccounted == 0`.
- [ ] Implement aligned TypedArray section reads and structured reconstruction from integer tables.
- [ ] Compare positions with `1.0e-6 m` tolerance, UVs with measured Float32 error, normals/areas with numeric tolerances, and all nonnumeric logical fields exactly.
- [ ] Run focused tests under both Ruby versions.

### Task 4: Deterministic `.cleanpkg` container

**Files:**
- Create: `bom_engine/clean_analysis/clean_package.rb`
- Create: `bom_engine/tests/test_clean_package.rb`
- Modify: `bom_engine/clean_analysis.rb`
- Modify: `bom_engine/clean_analysis/build_info.rb`

**Interfaces:**
- Produces: `CleanPackage.write(path, document, assets, compression_level: 9)` returning byte attribution and codec metrics.
- Package entries are exactly `manifest.json`, `buffers.bin`, and referenced `assets/...`.

- [ ] Write RED tests proving entry names, no absolute paths/base64, referenced-only assets, content-hash dedup, manifest/buffer/whole-package determinism, extractability, and reference-decoder round trip.
- [ ] Extend deterministic ZIP policy so JSON and materially compressible `buffers.bin` use DEFLATE while JPG/JPEG/PNG/WEBP stay STORED.
- [ ] Implement package reference-graph pruning and exact statistics for manifest, every binary section, padding, assets, container overhead, and compression method.
- [ ] Benchmark STORE versus DEFLATE for `buffers.bin` and assert the selected method is recorded.
- [ ] Run focused tests under both Ruby versions.

### Task 5: Shared-geometry and scaling invariants

**Files:**
- Create: `bom_engine/tests/test_clean_package_scaling.rb`

**Interfaces:**
- Consumes: synthetic one-definition fixtures with variable instance count.
- Produces: benchmark assertions/report for 1, 10, 100, 1,000, and 10,000 instances.

- [ ] Write RED assertions that definition position/topology/UV section byte lengths remain constant while only instance tables grow.
- [ ] Add mirrored, non-uniform, and nested-instance cases and decode them back to equivalent 4x4 transforms.
- [ ] Run scaling tests and record package growth.

### Task 6: Exporter and SketchUp menu integration

**Files:**
- Modify: `bom_engine/clean_analysis/exporter.rb`
- Modify: `bom_engine/clean_analysis/sketchup_extension.rb`
- Extend: `bom_engine/tests/test_clean_analysis_exporter.rb`

**Interfaces:**
- Produces: `Exporter.export_package(...)` alongside unchanged `export` and `export_visual`.
- Adds menu item `Export Optimized Clean Package...` with default extension `.cleanpkg`.

- [ ] Write RED tests proving existing JSON/Visual APIs remain unchanged and the package path delegates through the same snapshot/compiler/texture extraction pipeline.
- [ ] Implement package export and progress stages without changing existing menu behavior.
- [ ] Run focused exporter tests under both Ruby versions.

### Task 7: Real-fixture benchmark and accuracy gate

**Files:**
- Create: `bom_engine/tests/benchmark_clean_package.rb`

**Interfaces:**
- Consumes: existing `RUMAH L_clean_visual.zip` without launching SketchUp.
- Produces: a `.cleanpkg` and JSON report with old/new byte attribution, codec metrics, coverage equality, and determinism hashes.

- [ ] Encode/decode the real 43,058,841-byte CleanV1 model JSON and assert coverage counts match exactly with `unaccounted == 0`.
- [ ] Record current top-level JSON attribution and new manifest/position/topology/UV/transform/material/padding/assets/container attribution.
- [ ] Benchmark Float64 absolute, relative Float32, and quantized Int32 positions; record max/p95/RMS errors and chosen codec.
- [ ] Benchmark UV Float32 error and Float32 versus Float64 affine transform error.
- [ ] Encode twice and assert manifest, buffers, assets, and whole `.cleanpkg` SHA equality.

### Task 8: Binary contract and release package

**Files:**
- Create: `CLEAN_PACKAGE_BINARY_CONTRACT.md`
- Create: `release/binary/INSTALL.template.md`
- Create: `release/binary/MANUAL_ACCEPTANCE.template.md`
- Modify: `package.ps1`

**Interfaces:**
- Adds package target `BinaryRc` producing an RBZ and handoff containing the contract, install guide, acceptance guide, version, and checksums.

- [ ] Document container entries, manifest schema, section descriptors, endianness, alignment, codecs, topology, UVs, transforms, numeric references, visual/fallback data, versioning, and TypedArray decoding pseudocode.
- [ ] Add manual acceptance fields for size, timing, counts, coverage, textures, and visual-detail checks.
- [ ] Add deterministic release templates/checksums and verify runtime closure excludes tests and development artifacts.

### Task 9: Final verification, install, commit, and push

**Files:**
- Modify only files already listed if verification reveals a defect.

**Interfaces:**
- Produces final commit, pushed branch, installed direct runtime, RBZ, handoff, checksums, and acceptance-pending report.

- [ ] Run all pure CleanV1 tests under Ruby 2.5 and Ruby 3.2.
- [ ] Run syntax checks for every runtime Ruby file under both versions and `git diff --check`.
- [ ] Build `BinaryRc`, inspect archive entries, and validate every checksum.
- [ ] Commit focused tracked changes and push normally.
- [ ] Close SketchUp if active, back up the installed Clean runtime, and install the verified runtime directly without launching SketchUp.
- [ ] Re-run real-fixture package verification from committed code and report all 28 requested final fields with real SketchUp acceptance pending.
