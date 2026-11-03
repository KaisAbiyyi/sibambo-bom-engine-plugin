# SIB-ENG-BATCH-01 — STOPPED / AGENT HANDOFF

Notion: https://app.notion.com/p/40dc4a6aaf738124be52d833e8bb4591
GitHub issue: https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin/issues/31
Related receipt task: https://app.notion.com/p/40dc4a6aaf73818e8164c480e09f414b

## Claim and baseline

- Original agent stopped at owner request and releases its producer-batch-queue writer lock for a fenced successor claim. Successor must verify live ownership before writing.
- WIP branch: work/sib-eng-batch-01-overnight-20261103
- Pinned base: 6725a0e7ecbfb37a4be16c9bff7ad3c7321a60f0
- Base branch: origin/work/sib-perf-size-candidate013-20261024
- Worktree: D:/projects/sibambo/scratch/sib-eng-batch-01-20261103
- The default repo main tree contains unrelated untracked files; never clean or reset it.
- SketchUp host, install/repackage, private SKPs, and merge were not touched.

## Done so far

- Inspected workspace instructions, current candidate013 exporter, performance traces, historical batch runner, Notion spec and related receipt task.
- Created GitHub issue #31 and claimed task in Notion.
- Created isolated branch/worktree and drafted a single NEW file: bom_engine/overnight_batch.rb (~23 KB).
- Draft includes Catalog, Store, SketchupHost and Queue for recursive scan, source fingerprint, immutable attempts, receipt verification/reuse, batch manifest snapshots and profile processing. THIS IS UNTESTED WIP, not a completed product.
- No UI, menu hook, automated tests or native run. Ruby syntax test could not execute: ruby is not in PATH.

## Open blockers and review risks

1. Validate Ruby syntax and verify draft against actual candidate013 methods. Fix first. WIP Queue#step and Fiber.main / Fiber.yield expression need proper cooperative scheduling and cancellation semantics.
2. Build HtmlDialog UI with owner-chosen root (default D:/projects/sibambo/skps), recursive discovered list, selection/all/none, size, profile choice, reuse/needs-verification, Start/Pause/Resume/Cancel, stage and failure/log display. Narrow integration into BOMC menu.
3. Ensure strict serial SketchUp execution and prompt/dirty-state safety, including open errors and no automatic save/close. Prohibit concurrent ConversionJob/second batch.
4. Store#check_bomc_profile currently reads entire BOMC into memory; use a bounded profile verifier for large files. Reverify source bytes+SHA, output bytes+SHA, engine/runtime, format/profile, linked validation and performance receipt before reuse. Reuse may not trust status/filename alone.
5. Fix crash safety, repeated resume, partial receipts and failure paths, output confinement and symlinks. Never overwrite historical exports. Ensure Cancel prevents new jobs and reaches a safe checkpoint without false success.
6. Resolve provenance interoperability with separate SIB-ENG-RECEIPT-01 writer. Do not modify overlapping shared exporter/receipt internals without exclusive lock.
7. Write meaningful host-independent tests for recursive scan, multi-selection, duplicate names, profile matrix, two/one-profile reuse, changed source, corrupt/incomplete metadata, cancel during and between profiles, noninterruptible native operation, crash, repeated resume, failure injection, source immutability, output collisions.
8. Add operator walkthrough; D:-only outputs/temporary/logs. No private SKP, BOMC or raw manifests in repository.

## Completion gates

- Run suitable tests and self-review exact final SHA. Create/maintain DRAFT PR targeting candidate013 branch, and publish isolated checkpoints; do not merge.
- Owner Windows SketchUp: one real small SKP, then two-model smoke, source SHA unchanged, manifests/receipts verified, safe restart/cancel. Native evidence stays NOT_RUN until owner executes it.
- Update Notion/GitHub with real tests, source SHA, missing gates and exact owner handoff. Do not imply certification or research fidelity from successful export alone.

Successor action: refresh live claim/locks and branch first, claim queue lock after transfer, inspect untested draft, then complete implementation and tests safely.
