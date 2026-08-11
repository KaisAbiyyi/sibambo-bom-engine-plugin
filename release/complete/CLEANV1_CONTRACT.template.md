# CleanV1 completeness contract

Package: `{{PACKAGE_NAME}}`
Commit: `{{GIT_COMMIT}}`

The format remains `bom_engine_clean_v1` version `1.0.0`.

- `materials` contains only reachable material records, with deterministic ID, name, normalized sRGB RGBA, opacity, color space, and optional portable texture metadata.
- `surfaces` contains top-level analytical polygons with explicit coordinate loops, holes, normal, area, orientation, source count, compact classification, and optional material references.
- Top-level loops remain explicit for compatibility. Compact topology diagnostics report coordinate occurrences and unique positions; this candidate does not silently replace coordinates with incompatible indices.
- `definitions[].geometry` contains definition-local pooled `vertices`, indexed polygon `surfaces`, and indexed standalone visual `edges`.
- `instances` references shared definitions and preserves transforms, parent relationships, material overrides, and non-uniform normal-transform requirements.
- Single-use and unknown visible components are retained as definition plus instance, never as geometry-omitted placeholders.
- `visual_edges` contains world-space standalone visible edge segments not duplicated from polygon topology.
- `fallback_geometry` preserves polygon loops and material references when validation prevents normal retention.
- `excluded_objects` is reserved for explicit policy exclusions and includes a reason.
- Production output carries compact coverage/material/topology/definition diagnostics and compact classification methods. Debug output additionally carries verbose classification provenance and the full coverage ledger.
- Required empty holes/source counts, bounds, normals, and areas remain present for compatibility and utility.
- Triangles, occurrence-expanded shared geometry, UV data, and embedded texture bytes are not emitted.
