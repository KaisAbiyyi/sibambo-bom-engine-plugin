# SIB-SIZE-01 / SIB-PERF-03 — Exact texture hot-path candidate

Status: **code candidate, not native-accepted**. No RUMAH Y/I `Exact < SKP`, full SketchUp fidelity, or end-to-end speedup claimed.

## Verified baseline on installed Evolution candidate 004

- RUMAH Y saved SKP: 41,785,434 B, SHA-256 `5291179e1f4eac5ebf6b5eedc66135469a913f8df6a6d5a28238f497c75af119`.
- Native BOMC Exact candidate: 68,396,517 B against strict budget 41,785,433 B; refused publication. Largest section `textures`: 63,895,106 B.
- 4,129.552s whole error trace, ~3,871.462s material extraction, ~3,869.502s texture optimizer, 49 staged textures and 12 semantic verifier timeouts.
- The existing failure receipt omitted per-texture decisions due to a bad raw-graph field; the preceding diagnostic patch records bounded selected codec/rejection reasons without private names/paths in the public receipt.

## Lossless code changes

1. `bomc_sketchup_colorize.rb`: on 32-bit ImageRep pixels, native-endian bulk integer unpack/pack and bounded memoization of the **same exact SketchUp color transformation**; compare every predicted displayed RGBA including alpha and fully transparent pixel RGB. Result digests normalize original and transformed pixels into RGBA. Mixed/24-bit layouts keep their conservative implementation. All deadlines and cooperative cancellation checkpoints remain active. This may allow previously timed-out parametric colorized JPEG bases to pass, which can reduce bytes without lossy compromises; it is not guaranteed.
2. `bomc_png_optimizer.rb`: skip inverse filtering for PNG filter 0; fused filters 0..4 adaptive-score search preserves the **same scoring/tie-breaking** and strong compression options. PNG output is lossless and independently decoded in tests; RGB/RGBA source pixels and alpha are unchanged.
3. Preserve backward-compatible `TargetNotMet.texture_diagnostics[:material/:decision]` for existing consumers while saving only bounded, path-free summaries in `.performance.error.json` `metadata.size_gate`.

## Observed **component-only** Windows Ruby 3.2.11 benchmark

| Workflow | Baseline | New | Observed result |
|---|---:|---:|---|
| Colorize verification, 1024×768, 4 colors | 0.783s | 0.488s | +60% throughput, identical output RGBA SHA-256 |
| Colorize verification, 1024×768, 65,536 colors | 0.876s | 0.515s | +70% throughput, identical output RGBA SHA-256 |
| Colorize verification, 1024×768, 262,144 colors | 3.971s | 4.072s | **no acceleration** at high entropy; identical output RGBA SHA-256 |
| PNG repack, 512×512 gradient RGBA | 1.131s | 0.635s | ~44% less wall time; identical final PNG SHA-256 and bytes (11,024) |

Results are single-run snapshots and depend on input entropy and machine load; not p50/p95, not SketchUp native time, not a proof of overall export speedup. Candidate may consume additional bounded memory in verifier for the 65,536-entry color memo.

## Tests and remaining native gate

- Windows standalone Ruby source tests: PNG all 5 inverse filters and alpha; RGBA32 vs independent conservative 24-bit reference, row padding, semantic colorization hashes, rejection paths; size gate and export job error receipts.
- The Exact-size and fidelity publish gate is unchanged. Failed results still must not overwrite older BOMC outputs.
- Candidate packaging must be hash-pinned and installed **only after the operator closes SketchUp 2026**, then verified with a new application instance.
- Owner/native evidence required: fresh RUMAH Y and I Exact runs, source+RBZ+runtime SHA, actual file bytes and hashes, output decode/readback RGBA+alpha/materials/UV/geometry/scenes, codec decisions, hard size budget, wall time and GPU/CPU/IO correlation. `certified=false` until these pass.

Do not change source `.skp` files or ship them to GitHub. All native outputs/temp/receipts remain on D:.
