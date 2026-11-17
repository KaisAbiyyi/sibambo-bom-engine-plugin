# ModelTruth (SIB-R1-ITCON-001, WP2)

Diagnostic tools that decide whether a BOMC **Exact** file preserves the SketchUp model it was exported from. They are not part of the extension: nothing here is packaged into the RBZ, nothing under `bom_engine/` is changed, and they are not delivered in the Evolution E4 slot (plan D31/D32).

Governing plan: `docs/implementation-plan/MASTER_IMPLEMENTATION_PLAN_2026-11-17_SIB-R1-ITCON-001_v1.1.md` (D20-D34, C4.0-C4.5).

## How it works

Both sides describe the model as the DAG SketchUp stores: the root entities, group/component definitions, and instances (transform, own paint, tag). Every face, edge, instance, image and text becomes a canonical item of integers on the 1e-9 m grid; each definition gets a Merkle digest, and equal root digests prove equal world-space geometry. World space is never expanded. No tolerance is applied to geometry.

| File | Runs in | Role |
|---|---|---|
| `canonical.rb` | both | The only place canonical forms are defined (shared SHA is recorded in both manifests). |
| `bomc_side.rb`, `run_bomc_side.rb` | Ruby 2.5.9 (agent) | Decode one Exact BOMC, write canonical items, tables, textures and WebP pixel hashes (pinned `dwebp` plus pinned `ffmpeg`). |
| `skp_side.rb` | SketchUp 26.2.243, Ruby Console (owner) | Same canonical items from the open SKP, plus texture pixels through `ImageRep`. Read-only and cooperative. |
| `compare.rb`, `run_compare.rb` | Ruby 2.5.9 (agent) | Verdicts and diagnosis, writes `model-truth-diff.json`. |
| `summarize.rb` | Ruby 2.5.9 (agent) | Writes `docs/paper/SIB-R1-ITCON/MODEL-TRUTH-SUMMARY.md`. |

## Owner steps (per model)

The agent first runs the BOMC side for all 24 models. That produces `OWNER-RUNBOOK-<run_id>.md` next to the run folders under `D:\projects\sibambo\outputs\sib-r1-itcon\model-truth\`. The runbook lists, per model in order, the SKP to open and the exact Console lines.

1. Restart SketchUp 26.2.243 (build freeze: no E4 install, no SKP save, no re-export while this is in progress).
2. Open the SKP named in the runbook. Do not edit it.
3. In the Ruby Console paste the two lines from the runbook:

   ```ruby
   load 'D:/projects/sibambo/scratch/worktrees/sib-r1-model-truth-001/tools/model_truth/skp_side.rb'
   SibamboModelTruthV1::SkpSide.capture(run_dir: '<run_dir>', expected_source_sha256: '<skp sha256>')
   ```

4. Watch progress with `SibamboModelTruthV1::SkpSide.status`; stop early with `SibamboModelTruthV1::SkpSide.cancel`. SketchUp stays usable (it can show a brief "busy" state during a single native call; watch the title bar for "(Not Responding)").
5. When `status` reports `finished` (the Console prints `complete=true`), close the model **without saving**.
6. Tell the agent the run directory; the agent runs `ruby tools/model_truth/run_compare.rb <run_dir>`.

The pilot is `house2`, then the `RUMAH S` trial gates (WP2.6, WP2.7), then the other 22 models (WP2.8). A failed, cancelled or crashed run stays on disk as evidence; retry with a **new** run directory (re-run the BOMC side for that model to get one).

## Agent commands (Ruby 2.5.9)

```text
ruby tools/model_truth/run_bomc_side.rb --corpus <corpus.json> --out-root <root> --ffmpeg <ffmpeg.exe> (--model "<name>" | --all)
ruby tools/model_truth/run_compare.rb <run_dir>          # exit 0 PASS, 1 FAIL, 2 ERROR
ruby tools/model_truth/summarize.rb --out-root <root> --corpus <corpus.json> --output docs/paper/SIB-R1-ITCON/MODEL-TRUTH-SUMMARY.md
```

Set process-scoped `TEMP`/`TMP` to a folder under `D:\projects\sibambo\scratch\` first (workspace storage rule). All run directories must live on D:.

## Tests

```text
for f in tools/model_truth/tests/test_*.rb; do ruby $f; done
SIB_MT_REAL=1 ruby tools/model_truth/tests/test_local_real_files.rb   # local only; reads private models
```

Without `SIB_MT_REAL=1` the real-file tests report SKIP. The synthetic tests cover each rule but not SketchUp's real triangulation, UV helper or `image_rep` layout; only the owner captures prove those.

## What is not compared (plan D22)

EXCLUDED with counts: edge materials, texts without a point, other entity classes, unreachable definitions, instance `visible`, names, producer semantics (`fallback`, surface type), scenes/cameras, inherited-paint UV on default faces, face area. NOT_RUN: image pixels (image entities are compared for transform and tag only).
