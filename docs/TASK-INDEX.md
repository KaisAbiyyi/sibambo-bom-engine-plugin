# Sibambo BOM Engine Plugin — claimable task index

[Canonical six-phase Sibambo four-repository roadmap](https://github.com/KaisAbiyyi/sibambo/blob/main/docs/BIG-IMPLEMENTATION-PLAN.md) is the shared project-level task DAG. This repository owns producer tasks and SketchUp device qualification. It does not own Rooms, Benchmark or Editor tasks.

## P0 override: Exact + Visual only (2026-10-21)

The [dual-profile MASTER IMPLEMENTATION PLAN](https://github.com/KaisAbiyyi/sibambo/blob/main/docs/implementation-plan/MASTER_IMPLEMENTATION_PLAN_2026-10-21_EVOLUTION-DUAL-PROFILE-001_v1.0.md) is **PROPOSED; user direction is locked but lower-capability delegation requires an eligible review/freeze**. New exports E1–E4 expose only **Exact** (lossless supported capture) and **Visual** (lossy within measured Rooms-preserving bounds). Research remains legacy-read-only, including historical version/receipt/profile enum. Do not renumber E4 enum 2/3, edit native receipts, remove old Research readers or pretty-print E1 main JSON. Work from the latest feature source, respecting existing agent ownership.

| P0 task | Producer deliverable | Dependencies | Exclusive resource | Gate |
|---|---|---|---|---|
| `SIB-F1I` | Freeze shared new-export/legacy-read contract with all four repos | Stage A integration | `dual-profile-contract` | Cloud PLAN + eligible REVIEW |
| `SIB-F1J` | Implement two-profile menus/writers/validation, full Exact fidelity and bounded Visual compression; package new E4-slot RBZ | F1I frozen | `producer-runtime` | Cloud code + Local SketchUp |
| `SIB-F1O` | New 40-row 5-model × E1–E4 × Exact/Visual native corpus, pinned source SHA and human fidelity proof | F1J, consumer proofs; E1 browser proof separately F1N | `windows-sketchup/dual` | Local + Human |

Old `SIB-F1C` 21-row Visual/Research/Exact corrective receipts remain PASS as historical evidence, not the new 40-row denominator. F1D E4 Exact may continue against pinned previous source/runner if host and resource locks do not collide; it cannot certify a newly built runtime. The generic historical task list below is retained for traceability and superseded **only where its active three-profile scope conflicts** with this P0 override.

| Task | Deliverable | Required predecessor | Protected logical resource | Gate |
|---|---|---|---|---|
| `SIB-F1A` | Remove current-tree tracked SKP models and keep fail-closed corpus/CI honest | — | `producer-evidence` | Cloud; merged PR #2 at `26c4fb8` (current-tree SKP untracked) |
| `SIB-F1B` | Qualify E1–E4 streaming/readback/texture fallback/progress and ship reviewable RBZ candidate | F1A | `producer-runtime` | Cloud; historical feature branch exists |
| `SIB-F1C` | Rerun 21 E1–E3 failures across Exact/Research/Visual on real saved SKP sources | F1B | `windows-sketchup/e1e3-evidence` | Local Windows/SketchUp |
| `SIB-F1D` | Validate E4 Exact texture-heavy runtime/size/progress on genuine RUMAH Y/L models | F1B | `windows-sketchup/e4-evidence` | Local Windows/SketchUp |
| `SIB-F2E` | Validate exporter-to-editable BOMC contract with Editor | F2A | `producer-editor-contract` | Cloud |
| `SIB-F1H` | Four-repo E4 integration receipt with SHA matrix and human acceptance | F1C/F1D/F1E/F1F/F1G | `sibambo-e4-integration` | Cross-repo Local + Human |

A command `ambil F1C` can be interpreted unambiguously here. The agent checks every claim/PR/remaining test, states task ID and exclusive owner session, and **never assumes a cloud CI run proves real SketchUp behavior**. Task F1C is a *local* gate; task F1D may be parallel only if source model and host/qualification runner are not in conflict. Producer tasks never preassign ChatGPT versus Codex; use the environment with actual capability. No source `.skp` may be pushed to GitHub; keep original local SKPs safe, preserve SHA/size pins and do not rewrite commit history casually. Commit and push sanitized checkpoints with exact SHA and handoff. Task takeover requires explicit fenced/released ownership, not a browser timeout.

## F1A acceptance note

The clean CI result on PR #2 proves that tracked `.skp` files were deleted from the current Git tree and that portable corpus regressions stay fail-closed. It does **not** purge historical Git object blobs, nor qualify private SketchUp source-model captures. Real F1C/F1D evidence remains local; GitHub CI must never treat a missing model as completed validation.
