# BOM Engine Semantic v2 Vertical Slice Design

**Status:** Approved for implementation planning
**Date:** 2026-08-09
**Primary repositories:** `bom_engine_plugin`, `model-eval`
**Compatibility consumer:** `model-viewer`

## 1. Decision

BOM Engine Semantic v2 is the future canonical building representation. It is a standalone, semantic-first format whose authoritative state consists of architectural entities, their parametric properties, physical constructions, and typed relationships. Render geometry is derived cache data. Arbitrary geometry that cannot be represented reliably as an architectural primitive is preserved through an explicit `GenericMesh` fallback.

The first vertical slice introduces first-class `Level`, `Wall`, `Floor`, `Opening`, `Room`, and `GenericMesh` entities and proves this path end to end:

```text
SketchUp
  -> identity maintenance
  -> neutral extraction snapshot
  -> semantic reconstruction
  -> Semantic v2 model
  -> Semantic v2 serialization
  -> native model-eval loading and rendering
```

Canonical JSON v3, BOME2, and Model-Eval JSON v1 remain operational during migration. They are compatibility outputs and are sibling consumers of extraction; Semantic v2 never depends on them.

## 2. Goals

The vertical slice must:

- Make semantic and parametric properties authoritative wherever the primitive can be reconstructed reliably.
- Preserve architectural identity independently of SketchUp face identity.
- Preserve incomplete but certain primitives, such as a wall whose thickness is unknown.
- Encode level membership, room boundaries, floor ownership, wall hosting, and room adjacency through one authoritative relationship table.
- Keep render triangles out of parametric entities.
- Preserve every eligible source-geometry fragment exactly once as semantic coverage, GenericMesh fallback, or explicit policy exclusion.
- Preserve existing Canonical v3/BOME2 behavior and existing consumers.
- Let `model-eval` consume Semantic v2 directly without reconstructing walls or rooms from faces.
- Establish extension and migration boundaries that allow doors, windows, ceilings, roofs, columns, beams, and other entities to be added without replacing the core model.

## 3. Non-goals

This slice does not:

- Reconstruct curved or materially varying walls as parametric walls.
- Introduce first-class `Door`, `Window`, `Ceiling`, `Roof`, `Column`, `Beam`, or `Stair` entities.
- Implement non-prismatic room ceilings.
- Remove or rename existing formats.
- Persist the neutral extraction snapshot.
- Use GenericMesh metadata as substitute semantic entities.
- Implement semantic delta editing or round-trip SketchUp editing.
- Make `model-viewer` a native Semantic v2 consumer.

## 4. Architectural boundaries

### 4.1 Shared extraction, sibling compilers

One normalized SketchUp traversal produces an immutable, in-memory extraction snapshot. Two independent compiler branches consume it:

```text
Neutral Extraction Snapshot
  |-- Semantic v2 Compiler -> Semantic JSON + optional geometry cache
  `-- Canonical v3 Adapter -> current canonical graph -> JSON/BOME2
```

The extraction snapshot is an internal compiler representation. It must not acquire a public schema, output command, or serializer. It contains source evidence, not building truth.

Semantic v2 code may depend on extraction, identity, reconstruction policy, and shared mathematical utilities. It may not require, parse, adapt from, or construct Canonical v3, BOME2, or Model-Eval JSON. Compatibility code may adapt the extraction snapshot to the current canonical graph.

### 4.2 Authority hierarchy

For a reconstructed semantic entity:

1. Authoritative semantic identity, properties, physical construction references, and relationships define the building object.
2. Disposable computed data derives from authoritative state.
3. Render meshes derive from authoritative state and may be regenerated or discarded.
4. Source provenance explains reconstruction but does not define current geometry.

For unrecognized geometry, `GenericMesh.geometry_resource_id` references a cache resource. GenericMesh is an explicit fallback category and not an escape hatch for missing semantic properties.

## 5. Semantic v2 public contract

### 5.1 Format identity and files

The JSON document uses:

```json
{
  "format": {
    "identifier": "bom_engine_semantic_v2",
    "version": "2.0.0"
  }
}
```

The normal output is `*_semantic.json`. If at least one GenericMesh has geometry, the manifest references an immutable generation-specific `*_semantic.<generation_uuid>.geometry.bin` companion. A semantic-only model does not require a binary companion.

Readers reject unknown major versions and unknown required extensions. They may ignore unknown optional extensions.

### 5.2 Model identity and namespace

`model_id` is a UUID stored in the hidden model-level `BOMEngine.SemanticV2` SketchUp attribute dictionary. A public entity is globally addressed by the qualified pair `(model_id, semantic_uuid)`. Bare semantic UUIDs need only be unique inside their model namespace.

Lifecycle rules are:

- Save and reopen preserve `model_id`, source UUIDs, semantic UUIDs, and registry revision.
- Save As preserves them by default because it creates a continuation or branch of the same semantic model.
- An explicit future **Fork/Rebase Semantic Model** operation creates a new `model_id`, remaps source and semantic UUIDs in one undoable transaction, records the prior qualified identities, and preserves a reversible reconciliation map.
- Every source entity also records its originating `model_id`. Content inserted or pasted from a different model is recognized as foreign and receives destination source UUIDs. Origin identities remain diagnostic provenance, not active destination identity.
- Importing content from a different `model_id` creates destination semantic identities unless an explicit import reconciliation maps them.
- Importing divergent branches with the same `model_id` requires explicit branch reconciliation or rebasing. The engine must not silently coalesce equal UUIDs from independent branches.
- UUID collisions in a destination model re-ID the incoming or copied content, never the registry-owned original.

This policy reserves deterministic branch, merge, and import behavior without treating file paths as identity.

### 5.3 Site and orientation

The top-level `site` object contains authoritative orientation:

```json
{
  "site": {
    "orientation": {
      "true_north_xy": [0.0, 1.0]
    }
  }
}
```

`true_north_xy` is a normalized vector in the SketchUp model XY plane. The derived clockwise angle from model `+Y` is `atan2(x, y)` in degrees. A reserved `site.georeference` extension point will later carry latitude, longitude, elevation datum, and coordinate-reference-system data.

### 5.4 Coordinate and unit contract

- Geometry and physical lengths use metres.
- Areas use square metres and volumes use cubic metres.
- The model is right-handed with `+Z` up.
- Semantic plan geometry uses model XY coordinates.
- Model-eval maps `{x, y, z}` to Three.js `{x, z, -y}` only at its rendering boundary.

### 5.5 Top-level structure

The document contains:

```json
{
  "format": {},
  "model_id": "uuid",
  "registry_revision": 7,
  "generation_uuid": "uuid",
  "units": "m",
  "coordinate_system": {},
  "site": {},
  "levels": [],
  "walls": [],
  "floors": [],
  "openings": [],
  "rooms": [],
  "generic_meshes": [],
  "relationships": [],
  "constructions": [],
  "appearances": [],
  "geometry_resources": [],
  "extensions_used": [],
  "extensions_required": [],
  "extensions": {},
  "diagnostics": {}
}
```

### 5.6 Common entity fields

Every semantic entity contains:

- `id`: semantic UUID.
- `name`: optional descriptive name.
- `properties`: authoritative entity-specific properties.
- `construction_id`: optional physical construction reference.
- `appearance_id`: optional visual appearance reference.
- `completeness`: explicit known, unknown, and inapplicable property states.
- `computed`: optional disposable derived values.
- `provenance`: compact reconstruction provenance.
- `metadata`: descriptive, non-authoritative data.
- `extensions`: namespaced extension data declared at document level.

`metadata` must not affect geometry, identity, relationships, validation, reconstruction, rendering requirements, or analysis results. A property needed for correct behavior belongs in the core schema or a declared extension.

### 5.7 Level

A Level has authoritative `elevation_m` and optional `storey_height_m`. An explicit SketchUp source may own the level identity. Otherwise the semantic registry maintains derived level identity from reconciled floor and room membership, neighboring level order, and elevation continuity.

### 5.8 Wall

A first-slice Wall has:

- A straight plan baseline with stable direction.
- A level-relative `base_offset_m`.
- `height_m`, which may be `null` if semantic certainty survives incomplete extent reconstruction.
- `thickness_m`, which may be `null`.
- An alignment value such as `center`, `left`, or `right` when known.

Semantic certainty and property completeness are independent. A reliably identified wall does not become GenericMesh merely because height, thickness, construction, or appearance is unknown. The minimum parametric core is a reliable wall identity, level, and baseline. Missing properties degrade rendering or analysis capabilities explicitly.

New wall baselines use lexicographically ordered XY endpoints. A reconciled wall retains its prior baseline direction so host-relative opening and room-range coordinates do not flip.

### 5.9 Floor

A Floor has an ordered non-self-intersecting outer XY boundary, zero or more ordered hole boundaries, level-relative elevation, and nullable `thickness_m`. A reliable floor remains semantic when thickness or construction is unknown.

### 5.10 Opening

An Opening has a host-relative normalized or metric offset, sill/base offset, width, height, and authoritative `kind`:

```text
door | window | void | unknown
```

Explicit source semantics may authoritatively set `kind`. Geometry-only inference leaves `kind` as `unknown` and may emit a disposable `classification_hint`. A classification hint never overrides authoritative kind.

### 5.11 Room

A Room references ordered boundary relationships and a floor relationship. Its initial vertical contract is a tagged union:

```json
{
  "vertical_extent": {
    "kind": "constant_height",
    "base_offset_m": 0.0,
    "height_m": 2.8
  }
}
```

Future minor versions may add ceiling-surface, boundary-profile, or height-field variants without changing room identity or boundary relationships.

### 5.12 GenericMesh

A GenericMesh has a transform, classification state, analysis relevance declaration, and one `geometry_resource_id`. It contains no inline face, loop, or triangle arrays. Removing its binary resource does not invalidate parametric entities. Analyses that explicitly depend on that geometry must report `geometry_unavailable`; they may not silently treat it as irrelevant.

### 5.13 Relationships

The normalized relationship table is authoritative. Entities do not duplicate directional relationship arrays. Required first-slice relationship types are:

- `element_on_level`
- `room_boundary`
- `room_floor`
- `wall_opening`
- `room_adjacency`

A room-boundary relationship includes an ordered normalized wall interval:

```json
{
  "type": "room_boundary",
  "from": "room_uuid",
  "to": "wall_uuid",
  "order": 0,
  "wall_range": {
    "u_start": 0.0,
    "u_end": 0.5,
    "side": "left"
  }
}
```

`u` follows the authoritative baseline direction and remains in `[0, 1]`. This supports T-junctions, shared walls, and subdivided boundary usage without splitting the physical wall entity. Consumers build forward and reverse indices at load time.

### 5.14 Constructions and appearances

Physical `constructions` are separate from visual `appearances`.

Constructions reserve layered assemblies and authoritative thermal, solar, acoustic, and optical properties, including conductivity, resistance, heat capacity, density, solar absorptance, visible transmittance, and emissivity. Appearances contain renderer-facing color, opacity, texture, and UV references. A visual material name or color cannot silently become a physical property.

### 5.15 Compact provenance

Normal public provenance contains:

- `source_count`
- `lineage_hash`
- `reconstruction_method`
- `confidence`
- optional reconciliation status

Full source UUID mappings, source fragments, and matching evidence remain in the hidden registry or optional diagnostic export. They are not required in the lightweight standalone model.

### 5.16 Computed data and transitive dependency hashes

All computed data is disposable. A cache is valid only when its declared transitive authoritative dependency hash matches.

Hashing uses `sha256-jcs-v1`: SHA-256 over RFC 8785 JSON canonicalization. The dependency system is Merkle-like and cycle-safe:

1. Each entity and library object receives a local authoritative-content hash excluding `computed`, metadata, diagnostics, appearance-only data, and volatile source fields.
2. Each relationship receives a hash over its authoritative fields and the local hashes of its endpoints.
3. A computation declares the authoritative entities, physical library objects, relationships, site state, and policy state it depends on.
4. The engine resolves referenced objects transitively, deduplicates dependency nodes by qualified identity, sorts their `(kind, qualified_id, authoritative_hash)` tuples, includes sorted relevant relationship hashes, and hashes that canonical dependency manifest.
5. Unknown hash algorithms, missing dependencies, cycles that cannot be represented by the defined dependency graph, or any mismatch invalidate the cached value.

Changing a construction while retaining its UUID therefore invalidates dependent wall, room, and building calculations.

### 5.17 Extensions

Extensions use reverse-domain or similarly collision-resistant namespaces. `extensions_required` lists extensions without which the document cannot be interpreted correctly. `extensions_used` lists optional and required extensions. Core consumers reject missing required handlers and preserve optional extension data when round-tripping is supported.

## 6. Neutral extraction snapshot

### 6.1 Identity maintenance preflight

Before geometry traversal, the exporter scans relevant model, definition, instance, group, face, edge, and annotation entities for identity state.

It validates:

- Model UUID and registry version.
- Source UUID syntax.
- Source UUID uniqueness inside the model.
- Recorded source-origin `model_id`.
- Registry ownership of duplicated UUIDs.
- Model-level semantic lineage consistency.

Existing valid IDs are preserved. Missing IDs are assigned. For duplicated source UUIDs, the entity matching the registry-recorded SketchUp persistent owner remains unchanged and copies receive new UUIDs. If no registry owner exists, the deterministic lowest valid SketchUp persistent ID wins and all other occurrences are re-IDed.

Source UUID repair and necessary registry updates are committed in one undoable SketchUp operation. The operation is not opened when no identity or lineage state needs writing. Export cancellation or compiler failure aborts it.

### 6.2 Snapshot records

The immutable snapshot contains:

- Model identity, units, true north, export scope, and context transform.
- Definition-local polygon loops and topological edges.
- Component definitions, groups, and instance occurrences without expanded repeated buffers.
- UUID-based occurrence paths and normalized transforms.
- Source UUID, SketchUp persistent ID, source kind, parent ancestry, and source-origin model.
- Resolved attached text, instance name, definition name, and tag evidence.
- Materials, physical construction attributes, appearances, visibility, and selected dictionaries.
- Face holes, adjacency, normals, bounds, and ownership.
- Geometry eligibility and policy-exclusion reasons.

The current label-aware precedence is retained: attached leader text, explicit instance name, meaningful definition name, and meaningful tag. Generated names and default tags remain non-semantic.

### 6.3 Occurrence identity

Occurrence identity is composed exclusively from persistent source UUIDs of the containing instance chain plus definition-owned source identity. Array indexes, traversal order, serialized order, names, mutable transforms, and file paths are forbidden identity inputs.

Definition geometry remains shared. An occurrence token distinguishes two instances without copying definition geometry. Copying an instance creates a new source UUID at the copied chain position, while definition edits preserve occurrence identity for all existing instances.

## 7. Semantic identity and lineage registry

### 7.1 Two identity layers

- `source_uuid` identifies a persistent SketchUp source entity inside the model namespace.
- `semantic_uuid` identifies a reconstructed architectural object independently of any one source entity.

Loose faces are never selected arbitrarily as wall or floor identity anchors. Multi-source semantic identity is owned by the model-level registry.

### 7.2 Registry record

Each registry entry contains:

- Semantic UUID and entity type.
- Current source-lineage tokens and ancestry.
- Prior compact geometric signature.
- Level and neighboring semantic relationships.
- Ordered dependency lineage for derived entities.
- Registry revision introduced and last reconciled.
- Lifecycle state: `active`, `retired`, or `superseded`.
- Reconciliation method and confidence.

Retired semantic UUIDs are never automatically reused.

### 7.3 Resolution order

Semantic identity resolution is:

```text
exact lineage match -> lineage reconciliation -> new semantic identity
```

Reconciliation is semantic-type constrained and one-to-one. It considers:

- Source overlap and preserved ancestry.
- Baseline, floor footprint, or opening-range continuity.
- Level continuity.
- Neighboring walls, rooms, floors, openings, and host relationships.
- Explicit labels and physical-construction continuity.
- Planar-region and topological role continuity.

Geometry similarity alone cannot claim an existing identity. When a registry-owned original still exists, an identical copy receives new source and semantic UUIDs.

Ambiguous reconciliation creates a new semantic UUID plus diagnostics. It never aggressively reuses an old identity.

### 7.4 Splits, merges, and destructive operations

- A topology edit that only splits or merges source faces preserves the semantic entity when continuity is unambiguous.
- A semantic split permits at most one clearly dominant continuation to retain the prior UUID. Other results receive new UUIDs.
- A semantic merge retains a predecessor UUID only when one predecessor is clearly dominant and no competing match exists. Otherwise the merged entity receives a new UUID and predecessors retire.
- Delete followed by recreation produces new identity unless explicit reconciliation evidence proves continuity.
- Explode preserves semantic identity only when surviving UUID ancestry and topology establish one unambiguous continuation.

### 7.5 Derived Level and Room lineage

Derived Levels and Rooms do not depend only on raw source overlap.

A derived Level lineage includes reconciled member floor and room UUIDs, neighboring level order, and elevation continuity.

A Room lineage includes:

- Reconciled level UUID.
- Floor UUID when present.
- Ordered boundary wall UUIDs, normalized ranges, and sides.
- Neighbor-room topology.
- Host-opening relationships.
- Planar-region overlap and centroid continuity.

Opening creation, face splitting, or floor remeshing therefore does not change a Room UUID when its semantic boundary lineage survives.

## 8. Versioned reconstruction policy

All tolerances and detector thresholds live in one immutable policy object identified as `bom-semantic-reconstruction/1.0.0`. Detector-local geometric constants are prohibited.

The policy defines:

- Linear, angular, coplanarity, and intersection tolerances.
- Minimum fragment, opening, and room-region sizes.
- Wall surface-overlap and thickness-consistency requirements.
- Floor planarity and polygon-validity requirements.
- Room planar-region classification thresholds.
- Reconciliation scoring weights, dominance thresholds, and ambiguity margins.
- Decorative and analysis export policy categories.

Diagnostics record the policy identifier, semantic version, canonical policy hash, and every effective value. Policy changes may alter reconstructed output, but identity reconciliation still runs against established semantic lineage.

## 9. Reconstruction pipeline

### 9.1 Pass order

The Semantic v2 compiler runs deterministic passes:

1. Normalize coordinate and topology evidence using the effective reconstruction policy.
2. Apply explicit semantic evidence before geometry heuristics.
3. Reconstruct Levels.
4. Merge compatible coplanar surface regions.
5. Reconstruct Walls and Floors.
6. Reconstruct wall-hosted Openings.
7. Build level planar arrangements and classify bounded regions.
8. Reconstruct Rooms and relationships.
9. Reconcile semantic identities.
10. Partition source coverage.
11. Generate GenericMesh resources for fallback fragments.
12. Validate, stage, and publish.

Failure of a semantic reconstruction gate does not discard source geometry. It routes unclaimed fragments to GenericMesh unless policy explicitly excludes them.

### 9.2 Levels

Explicit level or storey metadata wins. Otherwise architectural horizontal regions are clustered by elevation. Furniture, entourage, decoration, and policy-excluded geometry do not contribute. Elevation is a mutable property, not identity.

### 9.3 Walls

A Wall requires a reliable semantic classification and straight plan baseline. Near-vertical coplanar regions and compatible opposing surfaces provide base, height, and thickness evidence. Face splits introduced by openings or edge operations merge before semantic reconstruction.

Opposing surfaces may establish thickness, but absent or ambiguous opposing surfaces yield `thickness_m: null`, not GenericMesh fallback. Height may likewise remain incomplete when the wall primitive and baseline are reliable. Rendering and analysis report degraded capabilities for missing dimensions.

T-junctions split the planar analytical arrangement while leaving the continuous physical wall intact. Room boundaries refer to normalized wall ranges.

### 9.4 Floors

Compatible horizontal coplanar regions merge into ordered outer and hole boundaries. A reliable polygon and elevation create a Floor. Opposing surfaces or explicit metadata may establish thickness; otherwise thickness is `null`.

### 9.5 Openings

Openings derive from wall-region voids, explicit components intersecting a wall volume or plane, or compatible combinations of both. Candidates project into host-wall coordinates and must satisfy containment and dimensional reliability requirements.

Explicit source semantics may set authoritative kind. Geometric inference produces `kind: unknown` plus a computed classification hint. Opening-induced changes in contributing wall faces participate in wall-lineage reconciliation rather than creating a new wall automatically.

### 9.6 Planar-region Room classification

Closed cycles are candidates, not Rooms. For each level, the compiler constructs a planar arrangement from wall baselines and their intersections, then classifies arrangement faces.

It explicitly distinguishes:

- The unbounded exterior face.
- Bounded occupiable interior regions.
- Courtyard or void regions using containment nesting, floor coverage, and connectivity.
- Wall-thickness regions between paired wall surfaces.
- Accidental micro-cycles below policy area, width, or perimeter thresholds.
- Duplicate or overlapping cycles caused by coincident evidence.

Only bounded occupiable regions with consistent floor support, ordered wall-range boundaries, and resolvable initial vertical extent become Rooms. Openings add connectivity relationships after region classification.

### 9.7 GenericMesh fallback

GenericMesh receives only eligible normalized fragments not claimed by a semantic entity and not excluded by policy. A partially semantic occurrence can therefore contribute distinct fragments to semantic entities and GenericMesh without forcing occurrence-wide fallback.

## 10. Source-coverage partition

The normalized extraction and clipping stages define `eligible_source_geometry` as a finite set of identity-based geometry fragments. Every fragment receives exactly one disposition:

```text
eligible_source_geometry
  = semantic_claimed
  union generic_fallback
  union policy_excluded
```

The three sets are pairwise disjoint.

`policy_excluded` entries retain a policy rule ID and diagnostic reason. They are not silently dropped. Semantic claims record the owning semantic UUID internally. Generic fallback records the owning geometry-resource fragment internally. The normal public manifest contains aggregate coverage counts and hashes; the diagnostic export may include the full ledger.

The coverage ledger uses polygon-derived fragments as authority. Triangulation may implement GenericMesh buffers and coverage verification, but triangles never become semantic source of truth.

## 11. Validation

Validation runs before registry commit or output publication.

### 11.1 Structural and identity validation

- Format identity, version, and required extensions are supported.
- Model, source, semantic, generation, and relationship IDs have valid form and required uniqueness.
- Every relationship endpoint exists and has an allowed type.
- Occurrence paths contain UUID identity components only.
- Registry-owned originals remain owners after collision repair.

### 11.2 Semantic and relationship validation

- Every Wall, Floor, Opening, and Room belongs to exactly one Level.
- Every Opening has exactly one host Wall.
- Room boundaries have consecutive order values and valid nonzero wall ranges in `[0, 1]`.
- A Room has a valid Floor relationship when floor support was required by its reconstruction method.
- Nullable incomplete properties are represented explicitly and do not invalidate entity certainty.
- An inferred classification cannot overwrite authoritative Opening kind.
- Bounded-room regions exclude exterior, courtyard, wall-solid, and micro-cycle classifications.

### 11.3 Geometry and resource validation

- All authoritative numbers are finite and within schema ranges.
- Wall baselines are nonzero and Floor polygons are valid.
- Openings remain within their host ranges under the declared tolerance policy.
- The three-way source partition is complete and pairwise disjoint.
- Geometry resource ranges, component types, byte counts, and SHA-256 checksums are valid.
- Missing GenericMesh resources produce explicit capability degradation.

### 11.4 Computed validation

- Hash algorithm and policy are recognized.
- Every declared transitive dependency exists.
- Referenced authoritative content hashes and relationship hashes match.
- A stale or unverifiable computed value is discarded before use.

Blocking structural, identity, coverage, or reference failures prevent Semantic v2 publication. Incomplete optional physical properties produce capability diagnostics rather than publication failure.

## 12. Serialization and recoverable publication

### 12.1 Deterministic serialization

Entities sort by semantic UUID. Relationships sort by type, source, target, order, and range. Floating-point normalization is centralized. JSON is UTF-8 and schema-valid. Generic binary resources contain versioned buffer views, `float32` positions, indexed triangles, byte lengths, and SHA-256 checksums.

### 12.2 Separate transactional domains

The SketchUp model transaction and filesystem publication are not atomic together. The exporter uses a staged, recoverable protocol. `model_id` and monotonic `registry_revision` are recorded in both the registry and serialized output. Every serialized output also carries a `generation_uuid`; the registry records that generation only when the same export commits registry changes. This preserves recovery evidence without modifying a clean model merely to record an otherwise stateless re-export.

The protocol is:

1. **Recover:** inspect prior staged generations, the current registry revision, and the published manifest. Complete or quarantine interrupted tool-owned stages deterministically by revision and checksum.
2. **Prepare:** compile against registry revision `R`, choose generation `G`, and compute intended revision `R'`. Write an immutable generation-specific binary companion and a staged manifest containing `model_id`, `R'`, `G`, and resource checksums. Fully validate both.
3. **Commit model domain:** if identity or lineage changes are required, commit source UUIDs, registry entries, revision `R'`, and prepared generation `G` in one undoable SketchUp operation. If no registry state changes, retain `R` and do not open an operation.
4. **Publish filesystem domain:** atomically replace the small final JSON manifest with the validated staged manifest. The manifest references the already complete immutable generation-specific companion.
5. **Retain recovery evidence:** keep enough generation and revision information to recognize completion on the next export. Older tool-owned sidecars may be collected only after a newer manifest is verified as published.

Crash recovery is deterministic:

- A staged generation whose intended revision was never committed is an orphan and is quarantined or removed.
- A model registry at `R'` with an older published manifest and a valid staged `R'` generation completes filesystem publication.
- If the staged files are missing after model commit, the exporter recompiles using the committed identities and publishes a replacement generation without changing those identities.
- A published manifest whose `model_id` or registry revision differs from the open model is reported as a stale or foreign export; it is never silently treated as synchronized.
- When registry state did not change, a crash before manifest replacement leaves the prior valid generation published and requires no model rollback.

This protocol provides recovery and detection, not false cross-domain atomicity.

## 13. Compatibility adapter

The current Canonical v3 builder is refactored to consume the extraction snapshot through a dedicated adapter. The adapter preserves existing definition-local geometry, instance transforms, holes, labels, materials, IDs, and exporter settings. BOME2 continues to derive from the current canonical graph.

Existing Canonical v3, BOME2, and Model-Eval JSON commands and schemas remain available. Semantic v2 receives a distinct export option and becomes the preferred architecture without silently changing legacy output contracts.

Compatibility regression tests verify current readers, transforms, instance reuse, face holes, semantic labels, checksums, and output validation. A dependency-boundary test prevents Semantic v2 modules from importing legacy serializers.

## 14. Native model-eval consumption

### 14.1 Loader

`model-eval` dispatches on `format.identifier`, validates Semantic v2, resolves a selected companion by declared name and checksum, constructs `BuildingSemanticModelV2`, and builds forward and reverse relationship indices once.

It does not convert Semantic v2 to Canonical v3, BOME2, legacy `BomEntity`, or initial `FaceRecord` arrays. Existing geometry-based wall and room detection is bypassed.

### 14.2 Rendering

- Walls with known height and thickness render as prisms.
- Walls with known height but unknown thickness render as clearly non-physical double-sided display planes.
- Walls with unknown height render as baseline-only diagnostic geometry and report height-dependent rendering and analysis capabilities as unavailable.
- Floors render as planes or prisms according to thickness completeness.
- Openings subtract from host-wall meshes using authoritative host-relative parameters.
- Room overlays derive from ordered wall ranges, floor relationships, and vertical extent.
- GenericMesh buffers render separately when available and are never implicitly reclassified.

Parametric renderer meshes are disposable and regenerated from semantic properties.

### 14.3 Analysis and compatibility facade

Native semantic entities feed analysis directly. Missing physical properties produce explicit per-capability unavailable or degraded results. Missing GenericMesh data affects only analyses that declare that dependency.

A compatibility facade populates current summaries, room lists, component indices, validation messages, and prepared render structures while retaining the native Semantic v2 model on `ParsedBuildingModel`. It must not recreate authoritative rooms or walls from generated faces.

Local upload accepts the manifest and optional companion together. If the companion is missing, all parametric content remains usable and affected GenericMesh capabilities report `geometry_unavailable`.

## 15. Error handling and diagnostics

- Identity, registry, reconstruction, validation, staging, and publication failures have distinct error codes.
- Cancellation aborts any open SketchUp operation and removes uncommitted staged files.
- Ambiguous reconstruction falls back by fragment; ambiguous identity produces new semantic identity plus diagnostics.
- Policy exclusions identify the exact policy rule.
- Diagnostics report reconstruction policy, counts by entity type, completeness, source coverage disposition, reconciliation outcome, capability degradation, and recovery state.
- Normal diagnostics stay compact. Full lineage and fragment mappings require explicit diagnostic export.

## 16. Test strategy

### 16.1 Standalone plugin tests

Pure Ruby tests with normalized snapshot fixtures cover:

- Source UUID validation, missing assignment decisions, collision ownership, and UUID-only occurrence paths.
- Exact lineage, reconciled lineage, ambiguity, split, merge, retirement, and non-reuse.
- Derived Level and Room dependency lineage.
- Wall and Floor reconstruction with unknown thickness.
- Wall certainty with incomplete height or construction.
- Opening host projection and authoritative versus inferred kind.
- T-junctions, shared walls, and normalized wall ranges.
- Exterior, courtyard, wall-thickness, accidental micro-cycle, and occupiable planar-region classification.
- Complete pairwise-disjoint three-way source coverage, including partially semantic occurrences.
- Versioned reconstruction policy application and diagnostics.
- Generic binary buffer ranges and checksums.
- Missing and corrupt GenericMesh capability behavior.
- Transitive computed dependency invalidation when referenced construction content changes without UUID change.
- Deterministic serialization and schema/reference validation.
- Recoverable publication state-machine transitions.
- Semantic-to-legacy dependency boundary enforcement.

### 16.2 SketchUp runtime identity tests

Tests run inside SketchUp and assert:

- Save/reopen preserves model, source, and semantic identity.
- Save As preserves the model namespace and identities.
- Re-export with valid identity state does not modify the model.
- Move and vertex edit preserve identity while changing properties and invalidating computed data.
- Copy and duplicate preserve the registry-owned original and re-ID the copy.
- Invalid duplicated UUID attributes are repaired deterministically.
- Delete/recreate yields new identity without explicit continuity.
- Group edits, instance edits, and shared component-definition edits preserve surviving instance semantic identities.
- Opening creation and face split/merge preserve the host Wall and surviving Room identities.
- Explode preserves identity only with unique surviving ancestry and topology; otherwise it creates new identity.
- Foreign-model pasted or inserted content is rebased into the destination source namespace.
- Failed or cancelled export leaves no partial registry transaction.

### 16.3 Compatibility tests

- Existing Canonical v3 and BOME2 fixtures validate.
- Existing Model-Eval JSON remains readable.
- Definition transforms, face holes, instance reuse, labels, materials, and checksums remain correct.
- `model-viewer` continues using existing formats unchanged.

### 16.4 Model-eval tests

- Semantic v2 schema parsing and required-extension rejection.
- Directional relationship-index construction.
- Parametric Wall and Floor mesh generation.
- Opening subtraction and wall-range handling.
- Unknown-thickness display and capability degradation.
- Direct Room consumption with no room-detection pass.
- Derived cache rejection after transitive dependency changes.
- Missing and corrupt GenericMesh companion handling.
- Native semantic analysis and current-UI compatibility facade.
- Existing Canonical v3, BOME2, Model-Eval JSON, and legacy JSON suites.
- End-to-end browser upload of a mixed semantic/GenericMesh fixture.
- Type checking, production build, and browser smoke coverage.

### 16.5 Required verification commands

Plugin standalone verification uses the available Ruby runtime for all `bom_engine/tests/test_*.rb` files plus syntax checks for every Ruby file. SketchUp-specific identity cases run in the supported SketchUp Ruby environment.

Model-eval verification runs its full unit suite, type checker, production build, and targeted browser smoke suite using the repository's declared package manager.

## 17. Acceptance criteria

The vertical slice is complete when:

- A SketchUp fixture exports Semantic v2 containing Level, Wall, Floor, Opening, Room, and GenericMesh entities.
- Semantic IDs survive re-export and qualifying topology edits under the documented rules.
- Parametric entities contain no authoritative or repeated triangle, loop, or face arrays.
- Nullable physical properties degrade explicit capabilities without destroying valid semantic entities.
- Every eligible source fragment has exactly one semantic, GenericMesh, or policy-excluded disposition.
- Room boundaries reference wall ranges and exclude non-occupiable planar regions.
- The output records true north, reconstruction policy, compact provenance, registry revision, and generation UUID.
- Computed values reject stale transitive dependencies.
- Interrupted publication is detectable and recoverable.
- `model-eval` loads, renders, queries, and analyzes Semantic v2 natively without room or wall reconstruction from faces.
- Canonical v3, BOME2, Model-Eval JSON, and existing viewers continue to work.
- The implementation and integration test suites pass with no unexplained warnings.

## 18. Future extension path

Future entity types add schemas, reconstruction passes, relationships, renderer generators, and capabilities without changing Semantic v2 authority rules. Doors and Windows specialize Opening semantics; Ceilings and Roofs extend Room vertical extents; structural elements add typed primitives; delta editing operates on semantic UUIDs and authoritative properties. None of those additions require making render geometry authoritative or routing Semantic v2 through a legacy format.
