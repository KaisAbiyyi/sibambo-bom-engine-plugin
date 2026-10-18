# Native conversion progress UI — proposed interaction contract v1

Date: 2026-10-18 (Asia/Jakarta). Status: **IMPLEMENTED IN SOURCE / HEADLESS-VERIFIED / SKETCHUP HOST PENDING**. Scope: SketchUp BOMC and Evolution E1–E4. The implementation responds to the native 60-row run. It does not certify host responsiveness.

Implementation location: `bom_engine/conversion_job.rb` owns backend envelopes, pass identities and named phases; `bom_engine/bomc_processing.rb` forwards labels and units; `bom_engine/material_extractor.rb` supplies texture/material names; `bom_engine/ui/conversion_dialog.html` renders the five stages, elapsed heartbeat, pass-local counters and invalid-count warnings. `bom_engine/bomc_export_job.rb` labels synthetic stage transition indices as **pipeline milestones**, which are displayed without a phase percentage or overall ETA. `bom_engine/tests/test_conversion_job.rb` and `bom_engine/tests/test_dialog_html.rb` provide synthetic and actual headless Chrome assertions. Current backend event semantics support **phase-local progress and diagnostic stall detection**; detailed per-codec pass names and backend-authoritative full-job ETA remain proposed future enhancements. Capture may resume after the nested texture phase without resetting the displayed texture completion.

## User-visible layout

```
Sibambo · Converting RUMAH Y.skp
E4 / BOMC 1.2   Exact                 Output: D:\SibamboExports\...

Overall conversion: WORKING — time remaining not established
  ● Capture              completed
  ● Textures             processing · material mtl · pass 2 (PNG → WebP)
  ○ Compile              waiting
  ○ Validate             waiting
  ○ Publish              waiting

Textures  47 / 159 materials (current pass: 12 / 48 texture candidates)
Last checkpoint 8 s ago · Last backend activity: 14:32:09
Elapsed 38m 24s · Host operation active / waiting for SketchUp

Show technical details ▾     [Cancel safely]
```

Do not show an overall percentage/ETA until the backend can prove a monotonic numerator and denominator for the complete job. The progress bar is indeterminate while active. Stage-local percentages (when valid) are explicitly labeled **Current phase**, never used as the overall percentage. Completing one phase is not overall completion. Completed state appears only after artifact validation and atomic publication finish.

## Backend event contract

Keep the current `ConversionJob` generation ID, monotonically increasing sequence and terminal state machine. Enrich queued events with:

| Field | Meaning |
| --- | --- |
| `job_id`, `sequence` | Immutable job identity, strictly increasing event ordering. |
| `state` | `created`, `capturing`, `compiling`, `validating`, `publishing`, `cancelling`, `completed`, `cancelled`, `failed`. |
| `phase_id` | Stable `capture`, `textures`, `compile`, `validate`, `publish`. Textures are a named nested phase of capture but displayed separately. |
| `operation_id`, `operation_label` | Backend-generated name: material, encoder, pass name and checkpoint context. Never infer a codec from raw counts. |
| `pass_id`, `pass_index` | Identity of repeated passes within a named phase, including profile changes in Export All. |
| `processed`, `total`, `unit` | Local quantity; `total` may be `null`. Units are `materials`, `textures`, `faces`, `entities`, `bytes`, or `candidates`. |
| `backend_monotonic_ms`, `checkpoint_at_ms` | Backend event timestamps/age information, independent from host/JS delivery delay. |
| `global_fraction` | Omit until backend has a proven global work denominator. Only monotonic values in `[0,1]`; do not synthesize from local events. |
| `profile`, `engine`, `model_name`, `output_path` | Explicit identity for this run, including output location on D:. |
| `diagnostic_code` | Optional machine-readable exceptional state (invalid counter, host call over budget, unsupported cancellation boundary). |

`phase_id + profile + operation_id + pass_id` is the local counter identity. A smaller count on **the same pass** signals an inconsistent counter, not progress reversal. A new pass begins a fresh stage-local counter and displays `Pass N`. A count with `processed > total`, a zero/negative total or a non-finite number becomes `Quantity unavailable` with a diagnostic entry. It must not render 100% or overwrite any trusted global completion state. Numbers such as `835632/198` from SNAPSHOT_ENTITIES are diagnostics; the user can expand the raw event, but it cannot control progress.

## Five phases and presentation rules

1. **Capture**: `snapshot_model`, geometry, scenes and source-identity reads. Show current operation, entity type when available and an upper bound if real. State remains active until the capture checkpoint reports completion.
2. **Textures**: material extraction and staged lossless/quality-gated candidates. Show current material name, source dimensions, selected attempt (`PNG`, `native JPEG`, `WebP m4`, `WebP m6`, `semantic verification`), pass and selected bytes. A long verification timeout is `fallback to displayed-pixel PNG`, not `conversion failed`, provided that the fallback is proven.
3. **Compile**: detach, writer, section packing and compression. Output byte count only if the writer reports it. Do not guess output size beforehand.
4. **Validate**: reader/readback, fidelity comparison, SHA-256. Large E1 has an explicit byte-exact streamed-readback substage; show bytes checked if proven.
5. **Publish**: result + provenance atomic move/rollback. Mark completed only after both become durable. On failure show preserved existing artifact and partial work state.

Each phase status is `waiting`, `active`, `completed`, `failed`, or `cancelled`. Transition order is backend-owned. The `textures` nested phase cannot independently advance global completion. Export All creates separate per-profile phase runs with explicit `profile` and `pass_id`; the overall run stays indeterminate until all three are valid and published.

## Responsiveness and elapsed time

Use a UI-owned clock to advance elapsed time even between backend events; retain the timestamp of the last accepted checkpoint. At 1.5 s without a checkpoint show `Working in a long SketchUp/native operation`. At 10 s show `No checkpoint for X s — busy or unresponsive`; **do not assert a deadlock**. The status changes only on a valid event or terminal state. Distinguish `backend waiting`, `cancellation requested`, `cancellation acknowledged`, `safe rollback` and `cancelled`. Cancel remains enabled until requested and displays the next expected cooperative boundary. An atomic host call may still delay acknowledgement.

After dialog close or export interruption, preserve an incomplete/not-published receipt under the output directory on D:. A reopened dialog must not infer success from a partially written `*.part` file or a previously visible 100% stage counter.

## Event processing pseudocode

```
onEvent(event):
  if event.job_id != activeJobId || event.sequence <= lastSequence: ignore
  lastSequence = event.sequence
  checkpointAge = now - lastAcceptedEventAt
  if terminal: render exact outcome and publication identity; stop active clocks
  else:
    update named phase state from event.phase_id and event.state
    if local pass key changed: reset ONLY local pass display and increment pass label
    if count finite and 0 <= processed <= total and total > 0:
      display stage-local quantity with its real unit
    else: display quantity unavailable and diagnostic reason
    if valid global_fraction supplied and backend invariant holds:
      global = max(previous_global, global_fraction)
    else: keep overall indeterminate
    update operation, profile, source/output identity, elapsed and checkpoint age
```

## Proof before UI release

- Pure event-state tests: monotonic generation sequencing; repeated stage/pass; reset; impossible/overflow counters; absence of global percentage; no false success during publication; final failure/cancel; reopening a dialog.
- Browser/UI replay with 60-row trace snippets: `SNAPSHOT_TEXTURES 142/159 → 39/159 → 4/159` and `SNAPSHOT_ENTITIES 835632/198`; user sees clearly named passes or diagnostic unavailable states, no fabricated percentage.
- Deterministic fake clock tests: 1.5s and 10s stale checkpoints, elapsed still advances, no false deadlock detection, eventual completion overrides stalled warning.
- Real SketchUp smoke, owned by user: heavy `RUMAH L/Y` remains operable as far as cooperative boundaries permit, cancel is acknowledged at next checkpoint, no partial artifact appears as completed.
- Regression gate: visual/readback fidelity, source model untouched, E1–E4 exact identity, cross-model output parity, rollback and D-drive destination constraints.

Implementation ownership: `bom_engine/conversion_job.rb` defines event identity/phase and queue; `bom_engine/ui/conversion_dialog.html` renders phases/counters/clock; `bom_engine/bomc_extension.rb` and `bom_engine/evolution_exporter.rb` add operation/pass metadata; `tools/history/evolution_lineup/lineup_dialog.rb` provides destination/profile identity. No changes to consumer UI or SketchUp thread model. Implement as a separate tested change and refreeze Evolution E4 package afterward.
