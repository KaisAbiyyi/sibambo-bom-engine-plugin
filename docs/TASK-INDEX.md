# Sibambo BOM Engine Plugin — claimable task index

[Canonical six-phase Sibambo four-repository roadmap](https://github.com/KaisAbiyyi/sibambo/blob/main/docs/BIG-IMPLEMENTATION-PLAN.md) is the shared project-level task DAG. This repository owns producer tasks and SketchUp device qualification. It does not own Rooms, Benchmark or Editor tasks.

| Task | Deliverable | Required predecessor | Protected logical resource | Gate |
|---|---|---|---|---|
| `SIB-F1A` | Remove current-tree tracked SKP models and keep fail-closed corpus/CI honest | — | `producer-evidence` | Cloud; current repair PR #2 |
| `SIB-F1B` | Qualify E1–E4 streaming/readback/texture fallback/progress and ship reviewable RBZ candidate | F1A | `producer-runtime` | Cloud; historical feature branch exists |
| `SIB-F1C` | Rerun 21 E1–E3 failures across Exact/Research/Visual on real saved SKP sources | F1B | `windows-sketchup/e1e3-evidence` | Local Windows/SketchUp |
| `SIB-F1D` | Validate E4 Exact texture-heavy runtime/size/progress on genuine RUMAH Y/L models | F1B | `windows-sketchup/e4-evidence` | Local Windows/SketchUp |
| `SIB-F2E` | Validate exporter-to-editable BOMC contract with Editor | F2A | `producer-editor-contract` | Cloud |
| `SIB-F1H` | Four-repo E4 integration receipt with SHA matrix and human acceptance | F1C/F1D/F1E/F1F/F1G | `sibambo-e4-integration` | Cross-repo Local + Human |

A command `ambil F1C` can be interpreted unambiguously here. The agent checks every claim/PR/remaining test, states task ID and exclusive owner session, and **never assumes a cloud CI run proves real SketchUp behavior**. Task F1C is a *local* gate; task F1D may be parallel only if source model and host/qualification runner are not in conflict. Producer tasks never preassign ChatGPT versus Codex; use the environment with actual capability. No source `.skp` may be pushed to GitHub; keep original local SKPs safe, preserve SHA/size pins and do not rewrite commit history casually. Commit and push sanitized checkpoints with exact SHA and handoff. Task takeover requires explicit fenced/released ownership, not a browser timeout.
