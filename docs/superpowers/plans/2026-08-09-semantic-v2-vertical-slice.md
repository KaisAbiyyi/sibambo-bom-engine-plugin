# Semantic v2 Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the frozen Semantic v2.0 vertical slice from SketchUp extraction through native `model-eval` consumption while keeping Canonical v3, BOME2, Model-Eval JSON, and the current viewer operational.

**Architecture:** Build a standalone Semantic v2 compiler over a private neutral extraction snapshot. Keep existing exporters on their current traversal until Semantic v2 passes its own end-to-end tests, then migrate Canonical v3/BOME2 through a one-way snapshot compatibility adapter. Semantic entities and relationships are authoritative; render geometry is derived except for fragment-level `GenericMesh` fallback.

**Tech Stack:** SketchUp Ruby API, Ruby standard library (`json`, `digest`, `securerandom`, `zlib`), JSON Schema 2020-12, TypeScript, Svelte, Bun, Vitest/Bun Test, Ajv, Playwright.

## Global Constraints

- The frozen contract is [the Semantic v2 vertical-slice design](../specs/2026-08-09-semantic-v2-vertical-slice-design.md). Implementation must not expand the Semantic v2.0 entity scope beyond Level, Wall, Floor, Opening, Room, GenericMesh, relationships, appearance/construction references, diagnostics, and disposable computed data.
- Opening placement has exactly one authoritative horizontal coordinate: normalized `u_center` on the directed host-wall baseline. Vertical placement and dimensions are metric. Do not serialize a second authoritative metric host offset.
- Wall alignment follows the frozen baseline equations. `room_adjacency` means a shared nonzero spatial boundary, never traversable connectivity.
- Unknown tagged-union variants are accepted only through supported format-version or required-extension negotiation. An unknown variant is not automatically a safe minor-version addition.
- Preserve both dirty worktrees. Before every milestone, capture `git status --short`, `git diff --stat`, and diffs of every file that the milestone will touch. Never use `git reset --hard`, `git checkout --`, or broad staging. Stage new clean files by exact path; stage overlapping dirty files with `git add -p -- <path>` and verify `git diff --cached` before every commit.
- In `bom_engine_plugin`, treat current edits to `bom_engine/canonical_graph_builder.rb`, `bom_engine/core.rb`, `bom_engine_loader.rb`, packaging scripts, schemas, and label-aware files as user-owned. Reuse `bom_engine/semantic_labeler.rb`; do not replace its precedence rules.
- In `D:/projects/sibambo/model-eval`, treat current edits to `src/lib/ModelCanvas.svelte`, `src/routes/+page.svelte`, review components/tests, and exported fixtures as user-owned. Avoid `ModelCanvas.svelte` changes by producing its existing `PreparedRuntimeGeometryScene` contract.
- Every implementation task is test-first: add the focused failing test, run it and record the expected failure, add the minimum implementation, run the focused test, then run the milestone suite.
- The SketchUp model transaction and filesystem publication are separate domains. Use the staged/recoverable protocol from the specification and never describe it as atomic.
- A re-export with no source-identity or lineage-registry change must not open a SketchUp operation or modify the model.
- Standalone Ruby verification requires `ruby` on `PATH`; first run `Get-Command ruby`. SketchUp API integration tests run in SketchUp's embedded Ruby console even when standalone Ruby is unavailable.

## Existing Boundaries to Inspect Before Editing

| Repository | Existing files | What to preserve or learn |
|---|---|---|
| plugin | `bom_engine/core.rb`, `bom_engine/ui_dialog.rb`, `bom_engine/ui/export_dialog.html` | Export dispatch, settings persistence, progress/cancellation, output naming, and current Canonical default |
| plugin | `bom_engine/canonical_graph_builder.rb`, `bom_engine/traversal.rb` | Current SketchUp traversal, instance transforms, attached-text collection, material extraction, and legacy graph expectations |
| plugin | `bom_engine/semantic_labeler.rb`, `bom_engine/classifier.rb`, `bom_engine/spatial_analyzer.rb`, `bom_engine/opening_detector.rb`, `bom_engine/constants.rb` | Reuse label precedence; use the geometry-first detectors only as behavior references; replace detector-local tolerances with the new versioned Semantic v2 policy |
| plugin | `bom_engine/canonical_json_writer.rb`, `bom_engine/bome2_writer.rb`, `bom_engine/model_eval_json_writer.rb`, `bom_engine/quantizer.rb` | Existing consumer contracts and regression surfaces; none may become a Semantic v2 dependency |
| plugin | `bom_engine/tests/test_canonical_graph.rb`, `test_core_canonical_export.rb`, `test_core_bome2_export.rb`, `test_model_eval_json_writer.rb`, `test_semantic_labeler.rb` | Runtime-test conventions and the minimum compatibility suite |
| plugin | `bom_engine_loader.rb`, `package.ps1`, `package.sh` | Loader registration and packaged runtime inclusion |
| model-eval | `src/lib/model.ts`, `src/lib/model-loader.worker.ts`, `src/lib/model-loading.ts` | Format dispatch, worker transfer boundary, and current single-file loading contract |
| model-eval | `src/lib/render/build-runtime-scene.ts`, `src/lib/ModelCanvas.svelte` | Produce the existing prepared-scene contract so the dirty canvas file need not change |
| model-eval | `src/lib/room-inventory.ts`, `src/lib/semantics/building-semantic-model.ts`, `src/lib/analysis-capability-readiness.test.ts` | Bypass face-derived reconstruction for native Semantic v2 while keeping the v1 facade for older formats |
| model-eval | `src/routes/+page.svelte`, `src/lib/formats/export-defaults.test.ts` | Add multi-resource selection surgically and preserve the current UI default plus unrelated review work |

## Dependency Boundaries

| Layer | May depend on | Must not depend on |
|---|---|---|
| `semantic_v2/snapshot` | immutable value records | public JSON schema, legacy graph shapes |
| SketchUp extractor | SketchUp API, identity plan, `SemanticLabeler` | semantic reconstruction, serializers |
| reconstruction | snapshot, policy, geometry helpers, lineage state | SketchUp entities, render triangles, legacy exporters |
| serializer/validator | Semantic v2 model, computed hashes, optional GenericMesh resources | SketchUp API, Canonical v3 graph |
| Semantic v2 core integration | compiler, staged publication | legacy graph builder internals |
| `model-eval` Semantic v2 parser | manifest, optional companion bytes | Canonical v3 conversion, face-based room detection |
| Semantic v2 renderer | native entities/relationships, GenericMesh resources | plugin reconstruction, authoritative face arrays |
| legacy adapter | neutral snapshot | Semantic v2 public JSON or serializer |

## Preflight: Protect Existing Work

- [ ] In `D:/projects/sibambo/bom_engine_plugin`, record the baseline without changing it:

  ```powershell
  git status --short
  git diff --stat
  git diff -- bom_engine/core.rb bom_engine/canonical_graph_builder.rb bom_engine/semantic_labeler.rb bom_engine_loader.rb package.ps1 package.sh
  ```

- [ ] In `D:/projects/sibambo/model-eval`, record its separate baseline:

  ```powershell
  git status --short
  git diff --stat
  git diff -- src/lib/ModelCanvas.svelte src/routes/+page.svelte
  ```

- [ ] Create a milestone ledger in the implementation task notes containing the two status snapshots and the latest commit IDs. Do not add that ledger to either repository.

---

## Milestone 1 — Identity and Extraction

**Testable exit:** A SketchUp model can be scanned read-only, a deterministic UUID repair plan can be produced, missing/duplicate source IDs can be committed in one undoable operation only when needed, and one immutable UUID-path snapshot can represent loose and instanced geometry without semantic reconstruction.

**Rollback boundary:** Revert only the new `bom_engine/semantic_v2*` files, their tests, and the additive `require` in `bom_engine/core.rb`. No export option or legacy traversal changes exist yet.

### Task 1: Establish canonical hashing and pure lineage-registry state

**Files:**

- Create: `bom_engine/semantic_v2.rb`
- Create: `bom_engine/semantic_v2/canonical_json.rb`
- Create: `bom_engine/semantic_v2/identity_registry.rb`
- Create: `bom_engine/tests/test_semantic_v2_identity_registry.rb`
- Modify: `bom_engine/core.rb` only to require `semantic_v2`

**Interfaces:**

```ruby
BOMEngine::SemanticV2::CanonicalJSON.generate(value) # deterministic UTF-8 JSON
BOMEngine::SemanticV2::CanonicalJSON.sha256(value)   # lowercase hex digest
BOMEngine::SemanticV2::IdentityRegistry.load(raw_json)
registry.plan_source_claim(source_uuid:, owner_pid:, origin_model_id:)
registry.resolve_semantic(type:, exact_key:, candidates:)
registry.changed?
registry.next_revision
registry.to_h
```

- [ ] Write tests for key ordering, normalized finite floats, UUID syntax, monotonic registry revision, registry-owned collision winners, deterministic lowest-persistent-ID fallback when no owner exists, and separate source versus semantic UUID namespaces.

  ```ruby
  assert_equal(
    '{"a":1,"b":2}',
    BOMEngine::SemanticV2::CanonicalJSON.generate({ b: 2, a: 1 })
  )
  winner = registry.resolve_source_collision(
    source_uuid: uuid,
    claims: [{ owner_pid: 44 }, { owner_pid: 12 }]
  )
  assert_equal 12, winner.owner_pid
  assert winner.diagnostics.include?('identity.collision_without_registry_owner')
  ```

- [ ] Run `ruby bom_engine/tests/test_semantic_v2_identity_registry.rb`; confirm failure because the namespace and registry do not exist.
- [ ] Implement a recursive canonical encoder that sorts object keys, preserves array order, rejects NaN/Infinity, emits normalized JSON primitives, and hashes the resulting UTF-8 bytes.
- [ ] Implement registry value objects with no SketchUp dependency. Store source claims separately from semantic lineage entries, include `model_id`, `revision`, and the optional prepared generation, and allocate UUIDs through an injected generator in tests.
- [ ] Run `ruby bom_engine/tests/test_semantic_v2_identity_registry.rb` and `ruby -c bom_engine/semantic_v2/identity_registry.rb`.
- [ ] Commit only these paths with `git commit -m "feat: add semantic v2 identity registry core"`.

### Task 2: Plan and commit SketchUp source identity changes

**Files:**

- Create: `bom_engine/semantic_v2/identity_coordinator.rb`
- Create: `bom_engine/tests/test_semantic_v2_identity_coordinator.rb`
- Create: `bom_engine/tests/test_semantic_v2_identity_sketchup.rb`
- Create: `bom_engine/tests/test_semantic_v2_identity_persistence.rb`

**Interfaces:**

```ruby
plan = BOMEngine::SemanticV2::IdentityCoordinator.plan(model: model, roots: entities)
plan.source_uuid_for(entity)
plan.occurrence_uuid_for(instance)
plan.model_id
plan.registry
plan.write_required?
BOMEngine::SemanticV2::IdentityCoordinator.commit!(model: model, plan: plan)
```

The hidden dictionary is exactly `BOMEngine.SemanticV2`. Entity keys are `source_uuid` and `origin_model_id`; model keys include `model_id`, `registry_json`, and `registry_revision`.

- [ ] Add pure fake-entity tests proving `plan` performs no writes, valid IDs are preserved, missing IDs get virtual UUIDs, malformed IDs are replaced, the registry-owned original wins a copied-attribute collision, and a second plan is byte-for-byte stable.
- [ ] Run `ruby bom_engine/tests/test_semantic_v2_identity_coordinator.rb`; confirm failure before implementation.
- [ ] Implement a read-only recursive scan. Use SketchUp persistent IDs only to recognize registry ownership and choose an unowned collision winner; never expose them as public identity or occurrence-path elements.
- [ ] Implement `commit!` so it returns immediately when `write_required?` is false. Otherwise call exactly one `model.start_operation('BOM Engine Semantic v2 Identity', true)`, write every planned entity/model change, and commit; abort the operation on any exception.
- [ ] Add SketchUp runtime cases for re-export, move, vertex edit, copy, duplicate, delete/recreate, nested group edits, shared component-definition edits, and explode. Assert the expected identity/diagnostic outcome, not traversal order.
- [ ] Add a save/reopen and Save As test harness that saves a temporary `.skp`, reopens it, reloads the registry, and compares `model_id`, source UUIDs, semantic UUIDs, and revision. The test must restore/close its fixture without touching user models.
- [ ] In SketchUp, run:

  ```ruby
  load 'D:/projects/sibambo/bom_engine_plugin/bom_engine/tests/test_semantic_v2_identity_sketchup.rb'
  load 'D:/projects/sibambo/bom_engine_plugin/bom_engine/tests/test_semantic_v2_identity_persistence.rb'
  ```

- [ ] Commit with `git commit -m "feat: persist semantic v2 source identity"`, staging only the coordinator and its tests.

### Task 3: Produce the private neutral extraction snapshot

**Files:**

- Create: `bom_engine/semantic_v2/snapshot.rb`
- Create: `bom_engine/semantic_v2/extractor.rb`
- Create: `bom_engine/tests/support/semantic_v2_fixtures.rb`
- Create: `bom_engine/tests/test_semantic_v2_snapshot.rb`
- Create: `bom_engine/tests/test_semantic_v2_extractor.rb`
- Modify: `bom_engine/semantic_v2.rb`

**Interfaces:**

```ruby
Snapshot::Document.new(model_id:, occurrences:, definitions:, primitives:, materials:, evidence:, diagnostics:)
Extractor.extract(
  model:, roots:, parent_transform:, identity_plan:, settings:, progress: nil
) # => Snapshot::Document
```

A primitive key is the containing-instance `source_uuid` chain plus definition-owned `source_uuid`. Names, array indices, traversal position, and serialization order are forbidden from the key.

- [ ] Write unit tests that reject mutable snapshot collections, non-UUID occurrence path components, duplicate primitive keys, and unresolved definition ownership.
- [ ] Write runtime extraction tests for a loose face, nested group, repeated component instance, hidden/policy-excluded face, face with a hole, and attached-text label. Assert definitions are shared while occurrences carry transforms and UUID paths.
- [ ] Run the focused tests and confirm they fail because snapshot/extractor are missing.
- [ ] Implement immutable record classes for definitions, occurrences, polygon fragments, loops, materials, construction hints, label evidence, and exclusion evidence. Keep triangles out of the snapshot authority; polygon loops and fragment ownership are sufficient.
- [ ] Implement one traversal that resolves transformations, calls the existing `BOMEngine::SemanticLabeler.build`, records explicit and inferred evidence separately, and never writes the model.
- [ ] Add a guard test that serializing a snapshot as Semantic v2 is impossible: no public writer accepts `Snapshot::Document` directly.
- [ ] Run focused tests plus existing `test_semantic_labeler.rb` and `test_canonical_graph.rb` in the appropriate Ruby/SketchUp runtimes.
- [ ] Commit with `git commit -m "feat: extract neutral sketchup snapshot"`.

### Milestone 1 Verification

- [ ] Run standalone tests:

  ```powershell
  ruby bom_engine/tests/test_semantic_v2_identity_registry.rb
  ruby bom_engine/tests/test_semantic_v2_identity_coordinator.rb
  ruby bom_engine/tests/test_semantic_v2_snapshot.rb
  ```

- [ ] Run all three SketchUp runtime test files and confirm a no-change re-export creates no undo entry.
- [ ] Re-run `git status --short` and confirm no pre-existing dirty file was reset or broadly reformatted.

---

## Milestone 2 — Core Reconstruction

**Testable exit:** The compiler can reconstruct Level, Wall, and Floor objects with stable semantic UUIDs and normalized relationships from the snapshot. Walls remain authoritative when thickness or height is unknown, and their baseline/alignment math is deterministic.

**Rollback boundary:** Revert Milestone 2 commits; Milestone 1 remains a testable identity/extraction library with no public export route.

### Task 4: Define the reconstruction policy, semantic model, and geometry math

**Files:**

- Create: `bom_engine/semantic_v2/reconstruction_policy.rb`
- Create: `bom_engine/semantic_v2/model.rb`
- Create: `bom_engine/semantic_v2/geometry.rb`
- Create: `bom_engine/tests/test_semantic_v2_policy.rb`
- Create: `bom_engine/tests/test_semantic_v2_model.rb`
- Create: `bom_engine/tests/test_semantic_v2_geometry.rb`

**Interfaces:**

```ruby
Policy::V1.id                    # => "semantic-v2-reconstruction/1"
Policy::V1.tolerance(:coplanar_m)
Model::Wall.new(semantic_uuid:, level_uuid:, baseline:, alignment:, thickness_m:, height:)
Geometry.wall_face_offsets(alignment:, thickness_m:)
Geometry.project_to_baseline(point:, p0:, p1:) # => normalized u
```

- [ ] Add exact math tests for baseline `d = (p1-p0)/L` and left normal `n = (-d.y,d.x)`: center gives `[-t/2,+t/2]`, left gives `[-t,0]`, and right gives `[0,+t]`. Test reversed baseline direction changes left/right consistently.
- [ ] Test nullable `thickness_m` and future-compatible wall/room vertical-extent tagged unions. Unknown union variants must require a supported required extension or version.
- [ ] Test that all detector tolerances come from `Policy::V1` and diagnostics record the effective policy ID and canonical policy hash.
- [ ] Run focused tests; confirm failures.
- [ ] Implement frozen semantic records for site/orientation, Level, Wall, Floor, Opening, Room, GenericMesh, Construction, Appearance, Relationship, ProvenanceSummary, Computed, and Diagnostic. Metadata accepts descriptive scalars/arrays only and is never consulted by reconstruction.
- [ ] Implement 2D/3D vector, projection, orientation, polygon area, interval, and wall-offset helpers without SketchUp classes.
- [ ] Run focused tests and commit with `git commit -m "feat: define semantic v2 model and policy"`.

### Task 5: Reconstruct planar surface regions, levels, walls, and floors

**Files:**

- Create: `bom_engine/semantic_v2/surface_regions.rb`
- Create: `bom_engine/semantic_v2/envelope_reconstructor.rb`
- Create: `bom_engine/tests/test_semantic_v2_surface_regions.rb`
- Create: `bom_engine/tests/test_semantic_v2_envelope_reconstructor.rb`

**Interfaces:**

```ruby
regions = SurfaceRegions.build(snapshot:, policy:)
result = EnvelopeReconstructor.call(snapshot:, regions:, policy:, registry:)
# result.levels, result.walls, result.floors, result.relationships,
# result.fragment_claims, result.lineage_candidates, result.diagnostics
```

- [ ] Add fixtures and failing tests for explicit labeled wall/floor precedence, unlabeled geometric inference, coplanar face merging, a T-junction, a split wall face, a floor with a hole, incomplete wall thickness, unknown floor thickness, and a non-reconstructable fragment.
- [ ] Assert a reliably identified wall with `thickness_m: nil` remains a Wall and claims its fragments; it does not become GenericMesh merely due to property incompleteness.
- [ ] Assert relationships are emitted only in the normalized table (`wall_level`, `floor_level`), not duplicated as authoritative arrays on entities.
- [ ] Implement planar region grouping with policy-controlled coplanarity/adjacency and an explicit mapping from every region back to geometry-primitive fragments.
- [ ] Implement Level inference from explicit source semantics first, then clustered elevations. Implement Wall baselines/alignment and Floor horizontal regions without render triangulation.
- [ ] Run focused tests and commit with `git commit -m "feat: reconstruct semantic envelope"`.

### Task 6: Reconcile semantic lineage across topology edits

**Files:**

- Create: `bom_engine/semantic_v2/lineage_reconciler.rb`
- Create: `bom_engine/tests/test_semantic_v2_lineage_reconciler.rb`
- Modify: `bom_engine/semantic_v2/identity_registry.rb`
- Modify: `bom_engine/semantic_v2/envelope_reconstructor.rb`

**Interfaces:**

```ruby
LineageReconciler.resolve(
  semantic_type:, candidate:, registry_entries:, dependency_index:, policy:
) # => Resolution(semantic_uuid:, outcome:, score:, evidence:, diagnostics:)
```

- [ ] Write a score-matrix test that enforces `exact lineage match -> reconciliation -> new identity`. Inputs include source overlap/ancestry, semantic type, geometry continuity, topology, level, and neighboring relationships.
- [ ] Test face split/merge and opening preparation retain a Wall UUID when continuity is unique; copy receives a new UUID; delete/recreate receives a new UUID; ambiguous equal candidates receive new identity plus a diagnostic.
- [ ] Test derived Level identity using elevation/topology dependencies rather than raw source equality alone.
- [ ] Run the failing tests.
- [ ] Implement hard compatibility gates before weighted reconciliation, a unique-winner margin from the central policy, and deterministic diagnostics containing all candidate scores. Never aggressively reuse an ID on a tie.
- [ ] Update registry entries only when semantic ownership/lineage state changes; identical re-export must keep the revision unchanged.
- [ ] Run all Milestone 2 tests and commit with `git commit -m "feat: reconcile semantic lineage"`.

### Milestone 2 Verification

- [ ] Run:

  ```powershell
  ruby bom_engine/tests/test_semantic_v2_policy.rb
  ruby bom_engine/tests/test_semantic_v2_geometry.rb
  ruby bom_engine/tests/test_semantic_v2_surface_regions.rb
  ruby bom_engine/tests/test_semantic_v2_envelope_reconstructor.rb
  ruby bom_engine/tests/test_semantic_v2_lineage_reconciler.rb
  ```

- [ ] Run the SketchUp move, vertex-edit, split/merge, copy, delete/recreate, group/component, and explode identity scenarios against extraction plus envelope reconstruction.
- [ ] Inspect sample reconstructed objects and confirm they contain no face, loop, or triangle arrays.

---

## Milestone 3 — Rooms, Openings, and Coverage

**Testable exit:** The compiler reconstructs canonical Opening placement and classified Room regions, emits wall-range relationships, preserves derived Room identity through survivable topology edits, and assigns exactly one disposition to every eligible geometry fragment.

**Rollback boundary:** Revert Milestone 3 commits; Levels/Walls/Floors and their lineage remain testable. No serializer or public export is present.

### Task 7: Reconstruct hosted openings with one coordinate contract

**Files:**

- Create: `bom_engine/semantic_v2/opening_reconstructor.rb`
- Create: `bom_engine/tests/test_semantic_v2_opening_reconstructor.rb`
- Modify: `bom_engine/semantic_v2/model.rb`

**Interfaces:**

```ruby
OpeningReconstructor.call(snapshot:, walls:, policy:, registry:)
# Opening placement: u_center, base_offset_m, width_m, height_m
# Relationships: opening_host_wall
```

- [ ] Add failing tests for authoritative labeled door/window, authoritative void, uncertain inferred opening with `classification_hint`, wall-direction reversal, wall-range containment, split host faces, and a cut that must not change host Wall identity.
- [ ] Assert serialized/model Opening has no `offset_m`, `host_offset_m`, or other horizontal alternative to `u_center`.
- [ ] Implement projection to the directed wall baseline, clamp only within policy tolerance, and express the occupied host range as normalized `[u0,u1]`. Preserve authoritative `kind`; keep uncertain inference in `classification_hint`.
- [ ] Emit only `opening_host_wall` in the relationship table. Do not add wall-owned opening arrays as authoritative state.
- [ ] Run focused tests and commit with `git commit -m "feat: reconstruct hosted openings"`.

### Task 8: Classify planar regions and reconstruct Rooms

**Files:**

- Create: `bom_engine/semantic_v2/planar_regions.rb`
- Create: `bom_engine/semantic_v2/room_reconstructor.rb`
- Create: `bom_engine/tests/test_semantic_v2_planar_regions.rb`
- Create: `bom_engine/tests/test_semantic_v2_room_reconstructor.rb`

**Interfaces:**

```ruby
classified = PlanarRegions.classify(level:, wall_ranges:, floor_regions:, policy:)
rooms = RoomReconstructor.call(classified:, levels:, walls:, floors:, registry:, policy:)
```

- [ ] Build failing fixtures for a simple bounded room, building exterior, courtyard/hole, wall-thickness loop, accidental micro-cycle, T-junction with partial wall range, two rooms sharing part of one wall, and a prismatic room with unknown height.
- [ ] Assert cycles are candidates only. Only bounded occupiable planar regions become Rooms; exterior, holes/courtyards, wall-solid regions, and micro-cycles receive explicit classifications and diagnostics.
- [ ] Assert `room_boundary_wall` relationships include normalized directed wall ranges and orientation. Assert `room_floor` is normalized. Assert `room_adjacency` exists only when rooms share a nonzero spatial boundary; an opening alone does not create adjacency or connectivity.
- [ ] Add derived-lineage tests showing a Room UUID survives raw face changes when its reconciled level, floor, ordered boundary wall UUID/ranges, and topology survive.
- [ ] Implement a half-edge planar subdivision, containment/nesting classification, minimum-area and wall-band filters from the versioned policy, and deterministic boundary ordering.
- [ ] Extend lineage reconciliation with semantic dependency fingerprints for Room and implicit Level candidates.
- [ ] Run focused tests and commit with `git commit -m "feat: reconstruct semantic rooms"`.

### Task 9: Enforce fragment coverage and build GenericMesh fallback

**Files:**

- Create: `bom_engine/semantic_v2/coverage_ledger.rb`
- Create: `bom_engine/semantic_v2/generic_mesh_builder.rb`
- Create: `bom_engine/tests/test_semantic_v2_coverage_ledger.rb`
- Create: `bom_engine/tests/test_semantic_v2_generic_mesh_builder.rb`

**Interfaces:**

```ruby
ledger.claim(fragment_key, semantic_uuid:, reason:)
ledger.fallback(fragment_key, mesh_uuid:, reason:)
ledger.exclude(fragment_key, policy_rule:)
ledger.finalize!(eligible_fragment_keys)
GenericMeshBuilder.call(snapshot:, fallback_fragment_keys:, policy:)
```

- [ ] Add failing tests for duplicate claims, missing disposition, semantic/fallback overlap, policy-excluded overlap, and a partially semantic group whose individual fragments split between Wall and GenericMesh.
- [ ] Assert the invariant exactly:

  ```ruby
  eligible = semantic_claimed | generic_fallback | policy_excluded
  assert_equal eligible_source_geometry, eligible
  assert_empty semantic_claimed & generic_fallback
  assert_empty semantic_claimed & policy_excluded
  assert_empty generic_fallback & policy_excluded
  ```

- [ ] Implement one finalization pass that blocks publication on any uncovered or multiply disposed fragment and reports the precise primitive key.
- [ ] Triangulate only fallback polygon fragments for GenericMesh cache output. Keep fragment lineage in the internal ledger/diagnostics; public provenance remains compact.
- [ ] Test that removing GenericMesh bytes does not invalidate parametric entities, while a GenericMesh-dependent capability returns `geometry_unavailable`.
- [ ] Run all Milestone 3 tests and commit with `git commit -m "feat: enforce semantic source coverage"`.

### Milestone 3 Verification

- [ ] Run every `test_semantic_v2_opening*`, `test_semantic_v2_planar*`, `test_semantic_v2_room*`, `test_semantic_v2_coverage*`, and `test_semantic_v2_generic*` test.
- [ ] Run SketchUp topology scenarios for opening creation, face splitting/merging, T-junctions, and explode; verify identity outcomes and exact fragment disposition counts.
- [ ] Confirm no Room is created from the exterior face, a courtyard hole, a wall-thickness band, or a micro-cycle.

---

## Milestone 4 — Serialization and Recoverable Publication

**Testable exit:** A validated Semantic v2 manifest and optional immutable GenericMesh companion can be generated deterministically and published through the recoverable revision/generation protocol. The new export route is opt-in; existing defaults and exporters are unchanged.

**Rollback boundary:** Revert Milestone 4 commits and remove the opt-in UI route. The private compiler through coverage remains intact and Canonical v3/BOME2 behavior is untouched.

### Task 10: Add normative schema, validation, and transitive computed hashes

**Files:**

- Create: `schema/bom-engine-semantic-2.0.schema.json`
- Create: `examples/semantic-v2-small.json`
- Create: `SEMANTIC_V2_FORMAT.md`
- Create: `bom_engine/semantic_v2/computed_hash.rb`
- Create: `bom_engine/semantic_v2/validator.rb`
- Create: `bom_engine/tests/test_semantic_v2_computed_hash.rb`
- Create: `bom_engine/tests/test_semantic_v2_validator.rb`

**Interfaces:**

```ruby
ComputedHash.authoritative_hash(object:, index:, relationships:)
ComputedHash.dependency_hash(root_ids:, entity_index:, library_index:, relationships:)
Validator.validate!(document:, resources:)
```

- [ ] Write failing validation tests for duplicate semantic UUIDs, broken relationship endpoints, invalid wall ranges, alternate opening horizontal offsets, authoritative triangle arrays on parametric entities, coverage failures, unknown required extensions, unknown unnegotiated tagged-union variants, invalid metadata semantics, and construction/appearance conflation.
- [ ] Write computed-cache tests where a referenced construction or material changes authoritative content without changing UUID. Assert the transitive hash changes and stale computed values are rejected. Include relevant relationship-state hashes.
- [ ] Implement the schema with explicit `additionalProperties` rules, nullable incomplete properties, reserved `extensions`, descriptive/non-authoritative `metadata`, and required-extension negotiation.
- [ ] Implement validation in layers: structural, identity/reference, semantic, coverage, resource, and computed dependency validation. Return stable error codes.
- [ ] Implement deterministic content-hash traversal with cycle detection and sorted relationship projections.
- [ ] Validate `examples/semantic-v2-small.json` against the schema using an available JSON Schema 2020-12 validator and run the Ruby tests.
- [ ] Commit with `git commit -m "feat: validate semantic v2 documents"`.

### Task 11: Write deterministic manifests, binary fallback resources, and recovery states

**Files:**

- Create: `bom_engine/semantic_v2/geometry_cache_writer.rb`
- Create: `bom_engine/semantic_v2/serializer.rb`
- Create: `bom_engine/semantic_v2/publication.rb`
- Create: `bom_engine/tests/test_semantic_v2_geometry_cache_writer.rb`
- Create: `bom_engine/tests/test_semantic_v2_serializer.rb`
- Create: `bom_engine/tests/test_semantic_v2_publication.rb`

**Interfaces:**

```ruby
GeometryCacheWriter.write(path:, meshes:) # little-endian float32/uint32, checksum/views
Serializer.build_document(model:, diagnostics:, registry_revision:, generation_uuid:, resource: nil)
Publication.publish(model:, output_path:, identity_plan:, compilation:, fault_injector: nil)
```

- [ ] Add golden-byte tests for little-endian positions/indices, buffer-view offsets/lengths, checksum mismatch, and missing companion behavior.
- [ ] Add deterministic serialization tests proving stable entity/relationship ordering and byte-identical JSON for identical authoritative input.
- [ ] Add a publication state-machine test with injected crashes at recover, after staging, after the single model-domain commit, and before manifest replacement.
- [ ] Assert: orphan stages are quarantined/removed; committed registry revision plus valid stage completes publication; missing post-commit stage recompiles with preserved IDs; model/manifest mismatch is reported; unchanged registry causes no model operation.
- [ ] Implement immutable generation-specific companions, write/flush/checksum before manifest validation, and publish the small JSON manifest last by same-directory atomic replace.
- [ ] When identity or lineage state changed, commit all source ID and registry writes in one SketchUp operation. When unchanged, publish against the existing revision without writing the model.
- [ ] Run focused tests and commit with `git commit -m "feat: publish semantic v2 generations safely"`.

### Task 12: Wire the independent Semantic v2 compiler and opt-in export

**Files:**

- Create: `bom_engine/semantic_v2/compiler.rb`
- Create: `bom_engine/tests/test_semantic_v2_compiler.rb`
- Create: `bom_engine/tests/test_core_semantic_v2_export.rb`
- Modify: `bom_engine/semantic_v2.rb`
- Modify carefully: `bom_engine/core.rb`
- Modify carefully: `bom_engine/ui/export_dialog.html`
- Modify carefully if required by current loader conventions: `bom_engine_loader.rb`
- Modify: `README.md`
- Modify: `MODEL_EVAL_JSON_GUIDE.md` only to link to `SEMANTIC_V2_FORMAT.md`, without rewriting current user edits

**Interfaces:**

```ruby
Compiler.compile(model:, roots:, settings:, registry:, identity_plan:, progress: nil)
Core.export_semantic_v2(model, settings, output_path)
```

- [ ] Write an end-to-end failing compiler test using a small SketchUp fixture: extract, reconstruct, reconcile, finalize coverage, validate, stage, commit if required, and publish. Assert true north, policy ID/hash, compact provenance, relationships, and absence of parametric triangles.
- [ ] Add a core dispatch test for `output_format: 'semantic_v2'`. Assert existing `canonical_v3`, `bome2`, and legacy branches still call their current code paths.
- [ ] Implement `Compiler` as orchestration only; each phase receives/returns immutable typed results. Cancellation before model commit removes uncommitted stage files and leaves the model unchanged.
- [ ] Add `semantic_v2` to the export dialog, but keep `canonical_v3` selected by default for this migration slice. Do not alter `CanonicalGraphBuilder` traversal yet.
- [ ] Merge the additive `core.rb` route around existing uncommitted progress/quick-export edits. Inspect the live diff immediately before patching.
- [ ] Run Semantic v2 core tests plus existing Canonical, BOME2, Model-Eval JSON, quick-export, conversion-job, and label-aware tests.
- [ ] Build a package and inspect its archive contents for all `semantic_v2` Ruby files:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\package.ps1
  ```

- [ ] Commit with `git commit -m "feat: add opt-in semantic v2 export"`, staging only the intended new files and surgical integration hunks.

### Milestone 4 Verification

- [ ] Export the same unchanged SketchUp model twice. Verify identical semantic content hashes, stable IDs/revision, no second undo entry, and only generation/resource fields that are intentionally generation-specific.
- [ ] Remove an optional `.geometry.bin` companion and verify parametric entities remain loadable while GenericMesh-dependent validation reports `geometry_unavailable`.
- [ ] Re-run all current plugin exporter tests and compare their produced format identifiers/default selection to the preflight baseline.

---

## Milestone 5 — Native `model-eval` Consumption

**Testable exit:** `model-eval` parses, indexes, renders, queries, and assesses Semantic v2 directly. It never reconstructs Semantic v2 rooms or walls from faces, and a missing GenericMesh companion degrades only affected capabilities.

**Rollback boundary:** Revert only the Semantic v2 files and additive dispatch/resource-set changes in `model-eval`; existing Canonical/BOME2/Model-Eval JSON loaders remain default-compatible. Plugin export remains independently usable.

### Task 13: Parse manifests/resources and build relationship indices

**Repository:** `D:/projects/sibambo/model-eval`

**Files:**

- Create: `src/lib/formats/semantic-v2.ts`
- Create: `src/lib/formats/semantic-v2.test.ts`
- Create: `src/lib/formats/semantic-v2-schema.test.ts`
- Create: `src/lib/model-resources.ts`
- Create: `src/lib/model-resources.test.ts`
- Create: `src/lib/semantics/semantic-v2-index.ts`
- Create: `src/lib/semantics/semantic-v2-index.test.ts`
- Modify carefully: `src/lib/model.ts`

**Interfaces:**

```ts
export type ModelResourceSet = {
  manifest: File;
  companions: ReadonlyMap<string, File>;
};

export function parseSemanticV2(
  json: unknown,
  resources: ReadonlyMap<string, ArrayBuffer>,
): LoadedSemanticV2;

export function buildSemanticV2Index(document: SemanticV2Document): SemanticV2Index;
```

- [ ] Copy no schema types by hand where drift would be hidden: define focused discriminated TypeScript types beside runtime validation, and add a schema/example test reading `D:/projects/sibambo/bom_engine_plugin/schema/bom-engine-semantic-2.0.schema.json` and `examples/semantic-v2-small.json`.
- [ ] Add failing parser tests for major-version rejection, unknown required extension, unnegotiated union variant, checksum/byte-range errors, missing optional companion, and a manifest whose `model_id`/revision references are internally inconsistent.
- [ ] Add resource matching tests: companion filename comes only from the manifest resource entry; same-named unrelated uploads are ignored; missing companion creates explicit availability state.
- [ ] Add index tests for wall-to-level, wall-to-room-range, room-to-boundary-range, room-to-floor, opening-to-host, and shared-boundary adjacency. Directional indices are derived at load and never serialized back as authority.
- [ ] Run focused tests and confirm failures.
- [ ] Implement parser/validator/resource matching and add a direct `semantic_v2` branch before compact/canonical/legacy conversion in `readBomModelData`/`parseBomModelJson`. Store the native object as `ParsedBuildingModel.semanticV2`; do not fabricate faces.
- [ ] Run focused tests and commit in the `model-eval` repository with `git commit -m "feat: parse semantic v2 models natively"`.

### Task 14: Render and expose native semantic inventory

**Repository:** `D:/projects/sibambo/model-eval`

**Files:**

- Create: `src/lib/render/build-semantic-v2-scene.ts`
- Create: `src/lib/render/build-semantic-v2-scene.test.ts`
- Create: `src/lib/semantics/semantic-v2-adapter.ts`
- Create: `src/lib/semantics/semantic-v2-adapter.test.ts`
- Create: `src/lib/semantics/semantic-v2-inventory.ts`
- Create: `src/lib/semantics/semantic-v2-inventory.test.ts`
- Modify carefully: `src/lib/semantics/building-semantic-model.ts`
- Modify carefully: `src/lib/model.ts`

**Interfaces:**

```ts
export function buildSemanticV2Scene(model: LoadedSemanticV2): PreparedRuntimeGeometryScene;
export function adaptSemanticV2ToParsedModel(model: LoadedSemanticV2): ParsedBuildingModel;
export function buildSemanticV2Inventory(model: LoadedSemanticV2): SemanticV2Inventory;
```

- [ ] Add renderer tests for left/right/center wall alignment, reversed baseline, nullable thickness, parametric floor triangulation as derived data, opening subtraction at normalized `u_center`, wall-range subdivision, and GenericMesh decode.
- [ ] Assert unknown thickness renders a deterministic analysis/display plane with an explicit degraded capability; unknown height follows the documented display policy and never invents an authoritative property.
- [ ] Add adapter/inventory tests that count/query Rooms, Walls, Floors, and Openings directly from native entities and relationships. Install a spy/failing stub on old face-based room/wall reconstruction and assert it is never called.
- [ ] Implement direct mesh generation into the existing `PreparedRuntimeGeometryScene` shape consumed by `ModelCanvas.svelte`. Do not modify `ModelCanvas.svelte` unless its contract is proven insufficient by a failing test.
- [ ] Keep the existing `sibambo-semantic-model-v1` facade for older formats. When `ParsedBuildingModel.semanticV2` exists, construct facade summaries from Semantic v2 entities/relationships, not `buildRoomInventory` face analysis.
- [ ] Run focused tests and commit with `git commit -m "feat: render and query semantic v2 natively"`.

### Task 15: Load companion files in the worker and verify the browser flow

**Repository:** `D:/projects/sibambo/model-eval`

**Files:**

- Modify: `src/lib/model-loader.worker.ts`
- Modify: `src/lib/model-loading.ts`
- Modify carefully: `src/routes/+page.svelte`
- Create: `src/lib/model-loading-semantic-v2.test.ts`
- Create: `src/lib/analysis-capability-semantic-v2.test.ts`
- Create: `tests/semantic-v2-upload.spec.ts`

**Interfaces:**

```ts
loadModelInWorker(resources: ModelResourceSet, options, onProgress)
```

- [ ] Write a worker test that transfers manifest plus companion bytes, parses Semantic v2, builds its native index, and produces prepared runtime buffers. Verify only transferable buffers cross the worker boundary.
- [ ] Write analysis-capability tests for complete parametric data, nullable thickness, missing GenericMesh bytes, stale transitive computed hashes, and direct Room readiness.
- [ ] Add a Playwright fixture upload containing the manifest and companion. Assert room inventory, wall/opening selection, render presence, and a missing-companion warning without losing semantic entities.
- [ ] Run focused tests and confirm failures.
- [ ] Change the loader API from a single `File` to `ModelResourceSet`, retaining a convenience wrapper for existing single-file formats. In `+page.svelte`, make the input `multiple`, select exactly one manifest, map referenced companions, and preserve the current uncommitted review/memory behavior.
- [ ] Build Semantic v2 prepared geometry in the worker. Ensure analysis/readiness branches use `semanticV2` directly and reject stale computed values through transitive authoritative hashes.
- [ ] Run:

  ```powershell
  bun test src/lib/formats/semantic-v2.test.ts
  bun test src/lib/render/build-semantic-v2-scene.test.ts
  bun test src/lib/analysis-capability-semantic-v2.test.ts
  bunx playwright test tests/semantic-v2-upload.spec.ts
  bun run check
  bun run build
  ```

- [ ] Commit with `git commit -m "feat: load semantic v2 resources end to end"`.

### Milestone 5 Verification

- [ ] Load `examples/semantic-v2-small.json` through the same browser route used for user uploads.
- [ ] Instrument old face-based Room/Wall detectors to throw during the Semantic v2 test; confirm the upload, inventory, renderer, and readiness tests still pass.
- [ ] Load representative existing Canonical v3, BOME2, and Model-Eval JSON files and confirm their current behavior remains unchanged.
- [ ] Re-run `git status --short` and verify the user's existing `model-eval` edits remain present.

---

## Milestone 6 — Legacy Adapter Migration

**Testable exit:** Canonical v3/BOME2 can consume the same neutral snapshot through a dedicated adapter with parity tests, while Semantic v2 remains independent of legacy formats. The migration is feature-flagged and reversible until final verification.

**Rollback boundary:** Flip `use_snapshot_extraction_for_legacy` to false or revert the adapter/default-switch commit. The original model-and-entities `CanonicalGraphBuilder.build` path remains available during this milestone; Semantic v2 and `model-eval` do not depend on the adapter.

### Task 16: Introduce and migrate the Canonical snapshot adapter

**Files:**

- Create: `bom_engine/canonical_snapshot_adapter.rb`
- Create: `bom_engine/tests/test_canonical_snapshot_adapter.rb`
- Create: `bom_engine/tests/test_legacy_snapshot_parity.rb`
- Modify carefully: `bom_engine/canonical_graph_builder.rb`
- Modify carefully: `bom_engine/core.rb`
- Modify: `bom_engine/tests/test_canonical_graph.rb`
- Modify: `bom_engine/tests/test_core_canonical_export.rb`
- Modify: `bom_engine/tests/test_core_bome2_export.rb`
- Modify: `bom_engine/tests/test_model_eval_json_writer.rb`

**Interfaces:**

```ruby
CanonicalSnapshotAdapter.build(
  snapshot:, settings:, spatial:, texture_writer: nil, progress: nil
) # => existing Canonical v3 graph shape
```

- [ ] Add parity fixtures covering labels, materials, nested/repeated components, transforms, holes, attached text, hidden/excluded geometry, scenes, and optional edges. Normalize volatile diagnostics/order before comparison.
- [ ] Run parity tests against the current builder and confirm the adapter is missing.
- [ ] Implement the adapter directly from the neutral snapshot. It may derive the exact geometry payload expected by Canonical v3/BOME2, but it must not read Semantic v2 public JSON or depend on Semantic v2 reconstruction/serialization.
- [ ] Add a temporary `use_snapshot_extraction_for_legacy` setting defaulting to false. Run all legacy tests through both paths and record any intentional, reviewed difference.
- [ ] After parity is green, switch the internal default to true while retaining the old traversal behind the explicit rollback flag for this milestone. Keep the export-format UI default unchanged.
- [ ] Add a dependency test that scans Ruby requires/constants and fails if Semantic v2 compiler/serializer references `CanonicalSnapshotAdapter`, `CanonicalGraphBuilder`, or BOME2 writers.
- [ ] Run Canonical v3, BOME2, Model-Eval JSON, legacy, label-aware, quick-export, and conversion-job tests through the snapshot path.
- [ ] Commit with `git commit -m "refactor: adapt legacy exports from neutral snapshot"`, carefully preserving current label-aware hunks.

### Milestone 6 Verification

- [ ] Export identical fixtures through old and snapshot-backed Canonical v3 paths; schema-validate and compare normalized graphs.
- [ ] Decode BOME2 outputs from both paths and compare normalized nodes, meshes, instances, materials, semantic labels, and bounds.
- [ ] Confirm Semantic v2 compiler tests pass with the legacy adapter file temporarily unavailable, proving the dependency direction.
- [ ] Confirm the current viewer and `model-eval` still load existing formats.

---

## Milestone 7 — Regression and Final Verification

**Testable exit:** Both repositories pass their complete relevant suites, packaged plugin smoke tests pass in SketchUp, recovery/identity scenarios are recorded, current consumers remain operational, and no unrelated dirty work was lost.

**Rollback boundary:** Documentation/fixture/test-only finalization commits can be reverted independently. Any failing legacy migration can still roll back via the Milestone 6 flag without removing the completed Semantic v2 path.

### Task 17: Run the release matrix and close migration boundaries

**Files:**

- Modify: `README.md`
- Modify: `SEMANTIC_V2_FORMAT.md`
- Modify: `MODEL_EVAL_JSON_GUIDE.md`
- Modify: `package.ps1` and `package.sh` only if archive inspection proves required runtime/schema assets are absent
- Add only minimal, reviewed fixtures under `examples/` and `bom_engine/tests/fixtures/`
- Modify `D:/projects/sibambo/model-eval/src/lib/formats/export-defaults.test.ts` only to assert the intentionally unchanged Canonical default plus presence of the opt-in Semantic v2 option

- [ ] Run Ruby syntax checks:

  ```powershell
  Get-Command ruby
  ruby -c bom_engine_loader.rb
  Get-ChildItem bom_engine -Recurse -Filter *.rb | ForEach-Object {
    ruby -c $_.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  ```

- [ ] Run every standalone Semantic v2 Ruby test and every existing standalone plugin test. Run all SketchUp-dependent suites in SketchUp's embedded Ruby runtime.
- [ ] Execute the identity matrix: save/reopen, Save As, re-export, move, vertex edit, copy, duplicate, delete/recreate, group edit, component-definition edit, face split/merge, opening creation, and explode. Save the observed UUID/revision/diagnostic matrix as a test artifact, not public schema state.
- [ ] Execute publication fault-injection tests and manually verify one staged-after-model-commit recovery in a disposable SketchUp model.
- [ ] Package with both scripts and inspect archive contents. Install the package in a clean SketchUp profile and smoke-test Semantic v2, Canonical v3, BOME2, and Model-Eval JSON exports.
- [ ] In `D:/projects/sibambo/model-eval`, run:

  ```powershell
  bun run test
  bun run check
  bun run build
  bun run release:check
  bunx playwright test
  ```

- [ ] Validate every checked-in Semantic v2 example and generated manifest against `schema/bom-engine-semantic-2.0.schema.json`; verify all referenced companions and checksums.
- [ ] Search for forbidden architecture leakage:

  ```powershell
  rg -n "CanonicalGraphBuilder|CanonicalSnapshotAdapter|BOME2" bom_engine/semantic_v2
  rg -n "faces|triangles|loops" examples/semantic-v2-small.json
  rg -n "offset_m|host_offset_m" schema/bom-engine-semantic-2.0.schema.json examples/semantic-v2-small.json
  rg -n "buildRoomInventory|SpatialAnalyzer|OpeningDetector" D:\projects\sibambo\model-eval\src\lib\formats\semantic-v2.ts D:\projects\sibambo\model-eval\src\lib\render\build-semantic-v2-scene.ts D:\projects\sibambo\model-eval\src\lib\semantics\semantic-v2-*.ts
  ```

- [ ] Inspect both final diffs against the preflight ledgers. Confirm every unrelated dirty path still has its original changes and no generated model/export file was accidentally staged.
- [ ] Update documentation with the opt-in workflow, companion-file selection, capability degradation, registry recovery behavior, and the explicit future extension boundaries for Windows, Doors as richer entities, Ceilings, Roofs, Columns, and connectivity—without adding those types to v2.0.
- [ ] Commit plugin finalization with `git commit -m "test: verify semantic v2 vertical slice"` and `model-eval` finalization with the same message, staging each repository independently.

## Final Acceptance Checklist

- [ ] Semantic v2 is standalone and future-canonical; no Semantic v2 module imports or reconstructs from Canonical v3/BOME2.
- [ ] The neutral extraction snapshot is internal only and feeds sibling Semantic/legacy consumers.
- [ ] Parametric Level/Wall/Floor/Opening/Room state contains no authoritative render triangles.
- [ ] Missing thickness/height/construction data degrades named capabilities without destroying reliable semantic identity.
- [ ] Opening horizontal placement is only normalized `u_center`; wall alignment math matches the frozen baseline for both baseline directions.
- [ ] Room boundaries use normalized wall ranges; `room_adjacency` means shared spatial boundary only.
- [ ] Every eligible fragment is in exactly one of semantic claim, GenericMesh fallback, or policy exclusion.
- [ ] Source and semantic IDs survive every continuity case that can be uniquely established; ambiguity yields a new UUID plus diagnostics.
- [ ] Save/reopen and Save As preserve `model_id`; foreign imports/copies are rebased into the destination namespace without coalescing registry-owned identities.
- [ ] Computed hashes include transitive authoritative entity/library content and relationship state.
- [ ] Required extension/version negotiation governs unknown tagged-union variants.
- [ ] Interrupted model/filesystem publication is detected and recovered deterministically.
- [ ] `model-eval` consumes Semantic v2 Rooms/Walls natively and uses derived render geometry only for display.
- [ ] Canonical v3, BOME2, Model-Eval JSON, existing viewers, and label-aware work pass regression tests.

## Execution Handoff

When implementation is authorized, choose one execution mode:

1. **Subagent-driven development (recommended):** execute one task at a time with a fresh implementation agent and review each task before proceeding.
2. **Inline execution:** run this plan sequentially in the current task, stopping at every milestone verification and rollback boundary.

Do not start either mode until the user explicitly authorizes implementation.
