# SIB-ENG-BATCH-01 — safely stopped successor handoff

Date: 2026-11-04 00:32 Asia/Jakarta. Status: PARTIAL / STOPPED AT OWNER REQUEST. Author: Codex primary (GPT-6 family supplied by runtime; exact variant not exposed). No independent REVIEW or final acceptance claimed.

## Recovery identity

- Repository: KaisAbiyyi/sibambo-bom-engine-plugin; existing Draft PR #32, issue #31.
- Branch: work/sib-eng-batch-01-overnight-20261103.
- Worktree: D:/projects/sibambo/scratch/sib-eng-batch-01-20261103.
- Base: candidate013 6725a0e7ecbfb37a4be16c9bff7ad3c7321a60f0.
- Prior source checkpoint: cb1a35147635560a42e91112a58311579e4f24b3. This handoff commit additionally preserves the three tested local correction files below. Obtain final checkpoint SHA from PR #32 / git HEAD; a document cannot contain its own commit hash.
- Generation 2 producer-batch-queue is RELEASED by this agent after preservation/push. Successor MUST recheck live Notion/GitHub ownership and explicitly claim generation 3 before edits. SketchUp host was never claimed.
- No subagents were used. Actual execution was local Windows Ruby/Chromium plus hosted GitHub CI; do not label local execution as cloud execution.

## Governing scope and completed source work

The owner's RECLAIM & FINISH mission and the Notion task requirements govern this batch scope. Workspace plan/review/summary directories were searched; no applicable batch-specific master plan/review/summary was found. Original handoff remains docs/worklogs/SIB-ENG-BATCH-01-2026-11-03-handoff.md; do not overwrite its historical state.

| Package | Status and evidence |
|---|---|
| 1 Draft repair | done at source level: removed Fiber.main/rescue suppression; bounded header/directory/encoding-contract reads; streaming hashes; path/link checks |
| 2 UI | done at source level: overnight_batch_dialog.rb + overnight_batch.html; recursive scan, subsets/all/none, independent profile states, profile selection, progress/counts, previous run load |
| 3 Reuse | done at source level: same source/runtime, output/receipt hashes+bytes, wire profile, immutable batch-validation binding; legacy adjacent output hints remain Needs Verification |
| 4 Serial execution | done at source level: queue-owned UI fiber/timer, global lease across namespaced runtimes and direct BOMC/Evolution calls, dirty-host checks, no source save |
| 5 Pause/Cancel/Resume | done at source level: checkpoint unwind, preserve successful noninterruptible publication, reverify/resume, recover validated commit without duplicate export |
| 6 Provenance | done at batch scope: immutable attempts/snapshots, error details, per-profile evidence; performance_trace.rb and receipt writer internals unchanged; separate unified receipt task NOT implemented |
| 7 Faults | done at source level: disk/path/permission/host safety pauses, configurable error continuation, output collision rejection |
| 8 Tests/docs | partial: targeted local tests + synthetic browser pass; hosted Linux CI failed stale menu expectation; exact-final-SHA self-review and terminal CI still required |

Source changes: bom_engine/overnight_batch.rb, overnight_batch_dialog.rb, overnight_batch.html, native_export_lease.rb; narrow wrappers/hooks in bomc_extension.rb, conversion_job.rb, evolution_exporter.rb and tools/history/evolution_lineup/master_menu.rb; tests/test_overnight_batch.rb and tests/overnight_batch_ui.cjs; README and Windows handoff. CI adds batch tests/browser proof and skips package/history-build-dependent steps for this specific PR branch because the owner prohibited RBZ packaging. Those skipped gates are NOT passes.

## Verified tests and known failure

- Latest local batch test: 32 tests, 109 assertions, 0 failures/errors, 1 skip (Windows account cannot create symlinks). Ruby 3.2.11. Evidence D:/projects/sibambo/scratch/sib-eng-batch-tests/test_overnight_batch.rb.log.
- Earlier targeted passes: conversion_job, bomc_export_all, bomc_export_job, profile_publication, bomc_canonical_publication, evolution_publication, evolution_profiles, performance_trace, bomc_size_gate, candidate013_cooperation, candidate013_png_worker, candidate012_cooperation, windows_codec_process. Local receipts/logs remain in the same D: evidence directory. The whole suite was not rerun after the final two corrections.
- Chromium synthetic HtmlDialog test passed: selection, both/single profiles, verified counts, cancel/resume/load controls, escaped text, narrower window. Screenshot batch-ui.png is synthetic. Not actual SketchUp CEF acceptance.
- Eight changed Ruby files passed syntax at cb1a351; diff checks passed before that commit. Recheck final checkpoint.
- Hosted run 41684728713 on cb1a351: windows-png-worker PASS; Linux test FAIL in bom_engine/tests/test_bomc_extension.rb around line 137. The test asserts exactly the old two menu labels; the new Overnight Batch menu intentionally adds one. Inspect and update the exact expected list to include Overnight Batch while retaining the no-separate-experimental-JCM assertion. DO NOT remove/weaken the test or claim a green cloud result. Failed CI log: D:/projects/sibambo/scratch/sib-eng-batch-tests/ci-41684728713-failed.log.
- CI stops at its first failed producer script, so later cloud tests/browser proof are NOT RUN in that run. The prior fbb5cef green run does not qualify this implementation.

## Final local corrections preserved by this checkpoint

Exact-SHA self-review at cb1a351 found two defects. Both first failed dedicated regressions and then passed in the 32-test run:
1. Cancel during blocking host.open must stop before host.export: added explicit cancel check after open in overnight_batch.rb.
2. Changing source root must detach the old paused/cancelled run; loading a previous run must refresh its catalog instead of leaving rows from another root: fixed in overnight_batch_dialog.rb.
3. Added both regressions in test_overnight_batch.rb.

No fix to the stale existing menu test has been made. Do not mistake the latest local batch PASS for full CI PASS. Critical self-review is incomplete, not independent acceptance. Review concurrency, source safety, durable commit recovery, cancellation and resource release again at final exact SHA.

## Next bounded actions

1. Read workspace README/AGENTS and repository instructions, this handoff, Windows handoff and live Notion claims. Reconcile remote HEAD with this preserved checkout; do not clean unrelated main/untracked worktrees.
2. Claim generation 3 producer-batch-queue after checking no competing writer. Receipt task was Ready/unclaimed when inspected; check again. Keep shared receipt internals read-only unless separately exclusively authorized.
3. Repair the intentional menu expectation in test_bomc_extension.rb; run that script first, then batch suite and relevant affected suites. Do not redesign or add features.
4. Re-run synthetic Chromium UI and Ruby syntax/diff checks; inspect final exact-SHA diff critically. Follow up on actual CI failures with evidence; do not relabel skipped/failed gates.
5. Fetch/compare branch, commit only task-owned changes, push same branch/PR. Keep Draft, no merge. Update GitHub issue/PR and Notion with final exact SHA, real test status and unrun gates.
6. Produce a new versioned implementation summary for actual completion; preserve this partial ledger.

## Owner manual gates — all NOT RUN

The detailed steps and expected outcomes are in docs/worklogs/SIB-ENG-BATCH-01-WINDOWS-HANDOFF.md. Owner must separately authorize reviewed E4-slot packaging/install, verify package/source/installed/loaded identities, then perform: one small genuine SKP interactive smoke; two-model serial/profile smoke; source SHA/bytes immutability; artifact/profile/validation/performance receipt checks; Cancel/Pause, interrupted-run/restart/repeated-Resume and safety-fault tests. No overnight run before these gates and owner acceptance. Exact remains strict; no certification claim.

Parent objective: safe unattended selected-SKP exports. Current phase F1 producer batch source/test delivery. Source UI/queue/reuse are implemented; CI repair/final review and native gates remain. Next user-visible deliverable: a green exact-SHA Draft PR with complete sanitized evidence and a ready owner handoff. Definition of done for cloud source: appropriate tests/CI and exact-SHA self-review pass; native acceptance remains separate.

No real SketchUp export, native control, RBZ package/install, private SKP modification or merge occurred. All generated evidence/temp/browser downloads are on D:. No private SKP/BOMC/manifest is committed.
