# SIB-F1J local Windows delivery

Task: SIB-F1J. Session: sib-f1j-local-20261021. Agent: Codex GPT-6 (exact
model variant unverified). Owner request: "sib-f1j jalanin keperluan lokal".
Scope: Windows qualification, carry the already implemented local Ruby 3 callback
repair onto final cloud source, package and install the reviewed six-choice target.
No SketchUp UI automation, model capture, consumer change, merge or certification.

## Ownership and source

Cloud generation 2 is finished, clean and pushed at
`3bfe223917394d0e42104c92b1da094755ea1a94`, PR #10; its handoff explicitly requires
a new local/integration claim. This local claim owns only the separate
`local/sib-f1j-windows-20261021` branch and local package/install evidence.
Logical resources: local producer correction and package/install, serialized;
no cloud branch or consumer claim is taken over. F1I is frozen/merged at producer
`41f849c6355517c017182339579e72ee308b95a5`. No source SKP is modified or committed.

Governing contract: EVOLUTION-DUAL-PROFILE-001 v2.0 with subsequent frozen F1I
`docs/contracts/evolution-dual-profile-v2.{md,json}` and cloud F1J generation-2
receipt. The contract's original J-HOLD prose is historical; subsequent owner
authorization and completed cloud handoff supersede that hold.

The original producer checkout was dirty. Its status and the two relevant WIP
file SHA-256 values were saved before work and compared afterward: unchanged.
The new branch is isolated under D:/projects/sibambo/scratch/sib-f1j-local-20261021/producer.
The app-managed worktree tool rejected the workspace root as not a Git repo;
Git worktree fallback was used from the actual producer repository.

## Bounded changes and rulings

1. Carry the existing local hotfix: `BOMCExtension.snapshot_model` passes
   `**canonical_work_checkpoint(event)` to the job's keyword-only callback.
   The original unmodified cloud runtime reproduced `ArgumentError (given 1,
   expected 0)` on Windows Ruby 3.2.11. The carried regression and fix then passed
   4 tests / 29 assertions. This is an existing diagnosed repair, not a new
   profile/codec design. If wrong, the first canonical capture checkpoint fails;
   actual SketchUp export is still a manual gate.
2. The Windows-only BOMC HTML test still demanded four choices. Update its
   expectation to the exact ordered values `exact, visual, all`, retaining
   output-path and viewport assertions. RED recorded; GREEN 14 / 119.
3. The Windows-only active lineup HTML test still referenced deleted historical
   E1 controls. Exercise current E2/E3 Exact selection, format-specific filenames,
   manual batch 8192, exact ordered choices and label instead. Historical source
   snapshots/readers are not changed. GREEN 1 / 16; portable current HTML proof
   separately passes 3 / 53 and includes both profiles plus Export All.
4. Test-environment corrections only: append installed Git `usr/bin` for `unzip`;
   use the native worker's expected D:-resident `tools/performance/.../target`
   rather than a different CARGO_TARGET_DIR. No product code change for these.

No architecture, wire enum, active engine, capture algorithm, quality threshold,
source-model identity or historical receipt was changed. Author self-inspection
covered the bounded diff; no new independent review is claimed. Existing cloud
independent review does not cover this local follow-up.

## Measured package and installation

Output: D:/projects/sibambo/outputs/2026-10-21-sib-f1j-local-004/.

- Runtime source SHA-256: `404c8b71ca0a40a3dc85e55977b9e80257dabce8a99f763e60d6e33e57983cb1`.
- RBZ SHA-256: `89a80c6b5407e6795f1309feb01024e2c122a8c99492ad1622c612977afd4260`.
- RBZ: 893552 bytes; packaging size is not model compression/performance proof.
- Independent exporter and builder inventories agree, 78 source files. Manifest,
  all engine row SHAs, shared BUILD_SHA and E4 BUILD_SHA agree; active orders
  2/3/4, profiles Exact/Visual; E4 order 4 and Research enum 2 are preserved.
- ZIP CRC and managed installer in a sandbox Plugins directory PASS.
- Installed SketchUp 2026 files: 90/90 hashes match the verified candidate.
  No SketchUp processes were running during replacement. Previous 90-file
  installation matched known hotfix-003 stage before replacement; complete
  verified backup is on D: in the output's `backups/` directory. Installation
  copied the identical path set, with no deletion or unrelated plugin changes.
- Live install: C:/Users/kaisa/AppData/Roaming/SketchUp/SketchUp 2026/SketchUp/Plugins/evolution_lineup.
  This is the required application installation, not a C: scratch/export path.
- `install-report.json`, `package-verification.json`, `runtime-source-inventory.json`
  and `install-local.ps1` retain local identities and fail-closed backup checks.

Identity distinction: cloud source inventory was `60391d93...`; unchanged cloud
Git commit checked out with Windows autocrlf measures `a55dbeae561d04fe918bbcba3dcbe36297d3307fdf6ae5433238d41b795fb38d`.
The local correction plus actual Windows source bytes measure `404c8b71...`.
These are explicitly different source-byte identities. The package is not labeled
as the cloud artifact. Consumers previously admitting `72a9a4a8...` or other
source hashes require a separately owned explicit current-source admission.

## Verification and limits

Windows Ruby 3.2.11 ran all 105 Ruby scripts separately. Initial result:
97 PASS / 8 FAIL. Preserve that first result; affected/environment reruns are
separate evidence. Final consolidated disposition is in the local canonical
implementation summary and `windows-verification.json`.

After the seven affected/environment reruns: **104/105 script dispositions PASS,
1 FAIL**. This is not a single all-green full campaign. Archive-integrity,
active packaging and candidate identity reruns PASS with the installed unzip.
There are still **21 explicit omitted/skipped host-capture tests** (matrix 1,
prepared Exact 1, T8 19); no SketchUp host proof follows from script exit status.

Important real Windows results: texture staging 39 / 177; texture encoder 14 / 63;
Windows codec processes 8 / 22; native worker 4 / 23 after correcting harness
target location; E2/E3 Export All 8 / 62; portable Chromium actual HTML 3 / 53;
lineup packaging/legacy install 5 / 55. These do not prove SketchUp API capture.

`test_milestone_provenance.rb` FAILS on historical
`SBE-2026.07.16-01/staged/schema/bom-engine-3.0.schema.json` content mismatch.
It also fails identically on an untouched detached cloud checkpoint
`3bfe223917394d0e42104c92b1da094755ea1a94`. Historical bytes/test thresholds were
not rewritten to manufacture a pass. Full-suite green is not claimed.

All generated logs, packages, browser profiles, OS temp and tool caches are on D:.
No source SKP is run through SketchUp. Source-model sizes/timings and native
fidelity are not invented. E4 remains candidate_pending_cross_model_validation,
certified=false.

## Manual owner handoff

SketchUp operator/user: start a fresh SketchUp 2026 session, use an unchanged saved
PROJECT SBOOST 2 model, then Export All for Canonical, CleanPKG and BOMC to D:.
Expected: exactly Exact + Visual per format, a fresh output folder,
export-status.json complete, matching current-source sidecars, no canonical
progress callback error. Keep all output/sidecars and elapsed timings.

Operator: cancel/fail a later profile and change/save/replace the source during
a separate run. Expected: completed prior artifacts survive; incomplete/changed
source is rejected with honest partial/cancel status, not a mismatched second file.

User: compare Exact and Visual against the same source scene/camera, including
holes, alpha, front/back materials and source geometry. Expected: lossless supported
Exact and acceptable Visual with unchanged analytical topology. No human PASS yet.

Parent objective remains P0 Phase 1. Next visible deliverable is a successful
real two-profile Export All on the installed runtime. F1O's fresh 30 native rows,
consumer source admission/real-file proofs, Rooms quality and human acceptance
remain separate. No deployment/merge/certification follows from this local delivery.
