# Sibambo BOM Engine Plugin — claimable task index

[Canonical six-phase Sibambo four-repository roadmap](https://github.com/KaisAbiyyi/sibambo/blob/main/docs/BIG-IMPLEMENTATION-PLAN.md) is the shared project-level task DAG. This repository owns producer tasks and SketchUp device qualification. It does not own Rooms, Benchmark or Editor tasks.

## P0 override v2.0: E2/E3/E4 × Exact + Visual only (2026-10-21)

The [MASTER IMPLEMENTATION PLAN v2.0](https://github.com/KaisAbiyyi/sibambo/blob/main/docs/implementation-plan/MASTER_IMPLEMENTATION_PLAN_2026-10-21_EVOLUTION-DUAL-PROFILE-001_v2.0.md) is **PROPOSED; product direction approved, runtime not changed yet**. **E1 and Research are both retired from all NEW export paths**. Keep only E2/E3/E4 × **Exact** (lossless captured data) and **Visual** (measured lossy rendering preserving Rooms analysis). Preserve historical E1/Research bytes/readers/receipts; no E1 new export or 10 GiB consumer project. Do not renumber E4 slot order 4, Research enum 2 or Visual enum 3. Keep other agents' work and resource claims untouched.

| P0 task | Producer deliverable | Dependencies | Exclusive resource | Gate |
|---|---|---|---|---|
| `SIB-F1I` | Freeze shared new-export/legacy-read contract with all four repos | Stage A integration | `dual-profile-contract` | Cloud PLAN + eligible REVIEW |
| `SIB-F1J` | Retire active E1/Research; implement E2/E3/E4 Exact/Visual, maintain E4 historical order 4, package new RBZ | F1I frozen | `producer-runtime` | Cloud code + Local SketchUp |
| `SIB-F1O` | New **30-row** 5-model × E2/E3/E4 × Exact/Visual native corpus, pinned source SHA and human fidelity proof | F1J, F1K/F1L/F1M | `windows-sketchup/dual` | Local + Human |

Old `SIB-F1C` 21-row Visual/Research/Exact corrective receipts remain PASS as historical evidence, not the new 30-row denominator. `SIB-F1N` large-E1 browser support is **CANCELLED** (no active E1), not available for claim. F1D E4 Exact may continue on previous pinned runtime separately if host/runner locks do not collide; never certify a new runtime from old results. The historical task list below is archive context; P0 overrides its active engine/profile contract.

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

## F1I contract checkpoint and user execution override

[Dual-profile v2 contract](contracts/evolution-dual-profile-v2.md) and [machine-readable pins](contracts/evolution-dual-profile-v2.json) define the six target choices and historical-read boundary. F1I documentation contract is FROZEN_REVIEWED; no runtime migration is implied. F1J is **HOLD BY USER**. F1K proceeds only with isolated proof tooling until Rooms resource release; its native acceptance also waits F1J. [Coordination record](https://github.com/KaisAbiyyi/sibambo/issues/2).

## Latest execution override — bounded F1J cloud implementation

Latest user correction supersedes the earlier J HOLD for feasible cloud code: resume F1J new-export routing/menu/lineup and portable checks, then F1L/F1M; further F1K is deferred. F1I JSON remains an immutable reviewed snapshot, not current task status.

CLAIM SIB-F1J; session sib-f1jlm-20261021, generation 1; branch codex/sib-f1j-active-exports-20261021; base 0602b2e4fca39792b1f8ca30c3ba27d7be718d0a; lock producer-runtime. [Claim and checkpoints](https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin/issues/4). Active E2/E3/E4 × Exact/Visual, historical codecs unchanged. Package v3 represents three original slots 2/3/4, while installer accepts v1/v2 archives. Native D-drive package/install and 30-row model evidence stay Local/Human gates; no cloud PASS transfers.
