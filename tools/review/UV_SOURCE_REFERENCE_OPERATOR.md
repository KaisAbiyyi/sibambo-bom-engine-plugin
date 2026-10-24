# Independent Y/I UV source-reference capture — manual operator gate

This is the **SIB-F1-READINESS-001 CP-UV-NATIVE** handoff. Run only after confirming SketchUp is idle and the relevant saved source file is unchanged. This diagnostic does not certify UV fidelity by itself. Do not upload `.skp`, `.bomc`, native NDJSON, or material/source data into GitHub.

The operator owns the native SketchUp window, source lock and export lock. Close other export sessions. Run Y and I in **separate fresh SketchUp model sessions**. Verify the saved source and the corresponding artifact files exist at the paths below. Do not save or edit the models during capture. All results go under `D:/projects/sibambo/outputs/` (choose unique directories that do not exist yet).

## Y — Ruby Console

Load the saved `D:/projects/sibambo/skps/RUMAH Y.skp` yourself, then paste:

```ruby
load 'D:/projects/sibambo/scratch/worktrees/sib-f1-readiness-producer/tools/review/capture_uv_source_reference.rb'
ENV['SIBAMBO_UV_NATIVE_OWNER'] = 'operator-20261024-Y'
SibamboUvReferenceV1.capture(
  model: Sketchup.active_model,
  artifact_path: 'D:/projects/sibambo/outputs/2026-10-23-sib-perf-size-mixed-layout-candidate-010/native-exact-rumah-y-01/rumah-y-010-exact.bomc',
  output_dir: 'D:/projects/sibambo/outputs/2026-10-24-uv-reference-Y-01',
  expected_source_sha256: '5291179e1f4eac5ebf6b5eedc66135469a913f8df6a6d5a28238f497c75af119'
)
```

## I — Ruby Console

Load the saved `D:/projects/sibambo/skps/RUMAH I.skp` yourself, then paste:

```ruby
load 'D:/projects/sibambo/scratch/worktrees/sib-f1-readiness-producer/tools/review/capture_uv_source_reference.rb'
ENV['SIBAMBO_UV_NATIVE_OWNER'] = 'operator-20261024-I'
SibamboUvReferenceV1.capture(
  model: Sketchup.active_model,
  artifact_path: 'D:/projects/sibambo/skps/model-eval-exports/RUMAH I__SIBAMBO-BOMC-v1.2.0__EXACT.bomc',
  output_dir: 'D:/projects/sibambo/outputs/2026-10-24-uv-reference-I-01',
  expected_source_sha256: '5bca2df092a6c28eca87eaf18584ab7b7519117ebd1dcb5e5c5faee8d77f10d2'
)
```

These are timer/Fiber jobs: `capture(...)` starts the capture; it does **not** mean the capture is complete. Wait for `manifest.json` to show `"complete": true`; inspect the `error` field on failure. The operator can cancel the active diagnostic in Ruby Console using `SibamboUvReferenceV1.active.cancel`. Never reuse an output directory on retry.

## Independent comparison after the native captures

From PowerShell, with process TEMP/TMP already scoped to D:, invoke the Python stdlib comparator separately for each complete capture:

```powershell
python D:/projects/sibambo/scratch/worktrees/sib-f1-readiness-producer/tools/review/compare_uv_source_reference.py --reference D:/projects/sibambo/outputs/2026-10-24-uv-reference-Y-01 --artifact D:/projects/sibambo/outputs/2026-10-23-sib-perf-size-mixed-layout-candidate-010/native-exact-rumah-y-01/rumah-y-010-exact.bomc --output D:/projects/sibambo/outputs/2026-10-24-uv-compare-Y-01
python D:/projects/sibambo/scratch/worktrees/sib-f1-readiness-producer/tools/review/compare_uv_source_reference.py --reference D:/projects/sibambo/outputs/2026-10-24-uv-reference-I-01 --artifact 'D:/projects/sibambo/skps/model-eval-exports/RUMAH I__SIBAMBO-BOMC-v1.2.0__EXACT.bomc' --output D:/projects/sibambo/outputs/2026-10-24-uv-compare-I-01
```

Expected: source and artifact identity guards remain intact; native manifest `complete=true` with stream hashes; independent comparator reports explicit-loop UV `PASS` only when every mapped value agrees at documented round-9 precision. Ambiguity, an inherited material mapping gap, an unsupported codec, invalid Q, source mismatch or incomplete capture must remain `HOLD`/`FAIL`. `whole_source_numeric_fidelity` stays `HOLD` without independent evidence for every field. Preserve receipts and hand them back for REVIEW/PLAN if the diagnostic cannot map real geometry without guessing.
