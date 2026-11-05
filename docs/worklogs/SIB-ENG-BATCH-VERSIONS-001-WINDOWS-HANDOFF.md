# Multi-version batch — deferred Windows operator tests

Scope: SIB-ENG-BATCH-VERSIONS-001, owner-requested E2/E3/E4 checkbox selection.
The owner explicitly requested an **RBZ only; no installation**. No SketchUp
control or real export is performed by this implementation task. These tests
belong to the owner **when the owner later chooses to install/test**.

## Source behavior

- Default selection is E4. Any nonempty subset of E2/E3/E4 is supported.
- Jobs are models in catalog order, then E2/E3/E4, then Exact/Visual. One job runs
  at a time. N selected models × V versions × P profiles produces N×V×P jobs;
  verified same-version/profile reuse reduces fresh exports.
- E2 uses the actual Canonical gzip writer (`.json.gz`), E3 actual CleanPKG
  (`.cleanpkg`), E4 actual BOMC (`.bomc`). E1/Research are unavailable.
- Profiles, status, attempt directories, validation, receipts, reuse and restart
  recovery are distinct for each version. No E2/E3 artifact is labeled BOMC.
- E4 Exact retains its strict original-SKP size gate. E2/E3 retain their own
  existing writer/fidelity contracts; a different physical format does not
  inherit the E4 size budget.
- Run schema v3 records selected versions/profiles and each model's exports.
  v2 snapshots/artifacts stay read-only: view them, but create a new run to use
  this runtime. A v3 runtime mismatch also refuses resume.
- Short D: temporary staging is used by BOMC and portable Evolution exporters;
  each export cleans its own scratch. Outputs and private receipts stay on D:.

## Owner manual tests — all NOT RUN by the agent

1. Later, after owner-controlled installation/restart, independently verify the
   actually loaded shared/E4 source hash against the delivered manifest. An RBZ
   hash, successful build or screenshot does not prove loaded host identity.
2. With one small saved, genuinely textured SKP, start a **new** batch with all
   three versions and both profiles. Expect 6 distinct completed combinations,
   correct extensions/engine/profile readback, passing receipts, unchanged SKP
   bytes/SHA and successful temporary-directory cleanup. Open representative
   outputs in their appropriate readers; inspect geometry/materials/UV visually.
3. Start a fresh run with E2+E4 and Visual only. Expect two jobs per model and no
   E3/Exact output. Confirm the selection and total count before Start.
4. Pause during a job, then resume. Expect that job to finish and only remaining
   combinations to run. Cancel/restart/load/reverify on a small fixture; expect
   completed combinations to be retained without duplicate exports. Changing a
   selected version in the UI applies to a new run; Resume uses its saved matrix.
5. Corrupt a copied test artifact or its provenance/performance/batch-validation
   receipt. Expect only that version/profile to require a fresh export; adjacent
   versions stay independently verified. Never mutate genuine prior evidence.
6. View an old v2 run. Expect a read-only notice and disabled Resume, with no
   changes to its snapshots/manifest/artifacts. Do not edit the schema/runtime to
   bypass compatibility checks.

Record source, RBZ, installed and loaded identities separately. No overnight run
or current 30-row certification claim follows from synthetic/CI results. Existing
source safety, host lock, modal/dirty-model and responsiveness/manual gates still
apply; the original batch Windows handoff remains historical supporting context.
