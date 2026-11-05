# Overnight Batch Export — Windows operator handoff

Task SIB-ENG-BATCH-01; existing Draft PR #32, issue #31. This is source/test delivery, not an installed engine or native acceptance receipt. The explicit owner restriction for this recovery forbids RBZ packaging/install and real SketchUp exports by the agent. Candidate013 Exact size/fidelity gates are unchanged. Evolution source integration is in historical E4 slot 4; no E5, Research writer or historical codec change.

## Before any owner smoke

1. Have the release/installation owner independently review PR #32. Package/install only under a separate explicit authorization, using `tools/history/build_evolution_lineup.rb --output <NEW-D:-OUTPUT>`. Check manifest E4 source-tree hash, engines.json E4 row/order 4, engine_e4_bomc/bom_engine/BUILD_SHA.txt and RBZ SHA. Preserve the prior package/install backup. Restart SketchUp and record the actually loaded runtime separately. This recovery has produced none of those package/installed identities.
2. Keep private sources and output evidence on D:. Sources default to `D:/projects/sibambo/skps`; outputs are uniquely reserved under `D:/projects/sibambo/private-evidence/batch-exports`. The dialog currently accepts D: source roots only. Do not put output under the source root. Directory aliases/junctions are refused. Do not move private manifests into the Git checkout or upload them.
3. Save or resolve dirty/unsaved work manually. The batch never saves an SKP or changes read-only attributes. A genuinely empty clean unsaved model may be switched; a dirty or populated unsaved model pauses. Native open prompts remain enabled. Keep Windows awake/on power yourself; sleep/lock/modal/native-operation behavior is not automated or qualified.
4. Record selected original SKP bytes/SHA before starting with `Get-Item` and `Get-FileHash -Algorithm SHA256`. Keep the receipt on D:. Retain access controls appropriate for private model paths; opaque run directories are not authenticated provenance or an ACL certification.

## Owner gates — run in this order

| Gate / owner | Action | Expected result |
|---|---|---|
| N1 / Windows SketchUp owner | Open Extensions → Sibambo BOM Engine Evolution → Overnight Batch Export (or individual BOM Engine menu). Refresh a chosen root with one small saved genuine SKP. Select just that row, Exact + Visual, Start. | Relative path/bytes and independent profile statuses appear. Only that model opens. Two validated profiles plus original performance receipts and batch-validation sidecars exist in a unique run. Manifest is complete, 2 completed/0 failed/0 pending. Exact is strictly smaller than that source or it fails explicitly; never loosen the gate to make a small fixture pass. |
| N2 / Windows SketchUp owner | After N1 passes, select exactly two saved genuine SKPs (including duplicate basenames in distinct subfolders if practical). Start both profiles. Repeat Exact-only and Visual-only on a bounded selection. | Stable relative-path order, one model/profile at a time, distinct model keys, correct profile matrix. Existing verified profiles are reused. A missing profile alone is exported. Attempt directories, previous outputs and receipts never get overwritten. |
| N3 / Windows SketchUp owner | Compare original SKP SHA/bytes after each smoke against the pre-run pins. Attempt Start with a dirty active model, and attempt a normal interactive export while batch runs. | Source identities unchanged. Dirty host pauses without save/close. Conflicting export is rejected; no second native export runs. Resolve dirty work manually before Resume. |
| N4 / Windows SketchUp owner | Inspect each successful manifest profile. Rehash artifact, performance_receipt and validation_receipt paths. Compare source/artifact identity, profile, runtime, validation report and receipt links. Reopen artifacts in the appropriate independent consumer when separately authorized. | Hashes/bytes agree, wire contract is Exact=1 or Visual=3 in BOMC 1.2, performance status success and report passed for matching profile. Runtime is a local disk inventory, not a package signature. Native/consumer fidelity remains its own acceptance gate. |
| N5 / Windows SketchUp owner | Cancel during capture and between profiles; repeat Cancel. Resume after it settles. Pause during a profile, wait, Resume. Close dialog during export. | Cancel Requested prevents new jobs immediately and unwinds at the next cooperative checkpoint. A noninterruptible publication may complete and be verified; its success stays preserved. Pause completes the active profile. Closing cancels/drains before releasing ownership. Resume rechecks all identities and exports unfinished profiles only. |
| N6 / Windows SketchUp owner | Use a throwaway source/output copy on D: for interruption tests. Interrupt SketchUp after one profile succeeds, restart, choose Previous runs → Load and reverify → Resume twice. Also test a changed source, damaged receipt, wrong output profile and a low-space/permission-denied destination using disposable fixtures. | Completed verified profiles are not republished; a fully written validation binding can recover a commit interrupted before its manifest save. Unvalidated orphan attempts stay preserved and retry in fresh paths. Changed source/runtime refuses resume; corrupt/incomplete evidence becomes Needs Verification. Disk/path/host safety failures pause. No overwrite, deletion or false success. |

Stop on any unexpected source change, conflicting native export, missing/mismatched evidence, false success or wrong active model. Preserve the whole private D: run directory for local investigation. Send only sanitized status/hashes/error excerpts to GitHub/Notion. Do not start an unattended overnight run until N1–N6 and required owner acceptance are returned.

## Operator behavior and recovery

- Refresh recursively hashes SKPs. Duplicate filenames remain separate by relative path. Select All/None and arbitrary subsets are supported. Scan/hash time and large native-operation responsiveness are not measured here; no ETA or overnight completion promise is made.
- Both profiles default to Exact then Visual. Continue-on-error skips remaining profiles of the failed model for this pass, leaves them pending and continues to the next model only if host/source safety is established. Stop-on-error pauses. `complete_with_failures` may include pending profiles and never means all exports passed. Counts are profile counts, not model counts.
- Verified reuse searches versioned batch runs in the private output root. It requires identical source bytes/SHA and runtime, artifact bytes/SHA, BOMC wire profile, full original validation binding and original successful performance receipt. Legacy adjacent `model-eval-exports` filenames are hints only: incomplete evidence displays Needs Verification. Arbitrary old output folders are not silently imported or certified. No old receipt is rewritten to invent missing validation.
- Snapshots (`snapshots/state-NNNNNNNNN.json`) are authoritative; `manifest.json` is a convenience view. A torn newest snapshot falls back to a valid earlier snapshot without reusing its sequence number. `writer.lock` is an OS file lock, released by process exit; do not delete it to bypass another live writer.
- Interrupted validated commits are recovered only by rechecking their saved attempt path, artifact, source, runtime, profile, validation sidecar and original performance receipt. An incomplete attempt is never adopted by filename/success flag. All orphan files and historical receipts remain intact.
- Source/runtime mismatch stops resume. Restore the pinned source/runtime or start a new run; there is no automatic migration, source rewrite, rollback or certification. No startup auto-resume occurs.
- Temp data for batch export is scoped to the D: attempt directory via TEMP/TMP and the exporter already uses its output parent for conversion scratch. No OS sleep settings or SketchUp prompt suppression.
- The separate SIB-ENG-RECEIPT-01 task remains responsible for unified ordinary-export research/R1 provenance. This batch adds a private `sibambo-batch-validation-v1` binding and references existing performance receipts without changing performance_trace.rb, its schema or its writer. This does not claim complete Research 01/Rooms/Benchmark acceptance.

## Automated reproduction (synthetic only)

Use Ruby 3.2 (matches CI) and Node 22/Chromium. In PowerShell from this branch:

```powershell
$env:TEMP = 'D:/projects/sibambo/scratch/sib-eng-batch-tests/temp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
& C:/Ruby32-x64/bin/ruby.exe bom_engine/tests/test_overnight_batch.rb
# Set PLAYWRIGHT_MODULE to an existing @playwright/test 1.61.1 installation.
$env:PLAYWRIGHT_BROWSERS_PATH = 'D:/projects/sibambo/scratch/sib-eng-batch-tests/browsers'
node bom_engine/tests/overnight_batch_ui.cjs
```

These tests use synthetic files and injected hosts. They do not exercise SketchUp, real SKPs, installed/loaded package identity, independent fidelity or overnight responsiveness. The Windows symlink test skips when the account cannot create links; hosted Linux CI exercises that path. Native junction behavior remains N6.
