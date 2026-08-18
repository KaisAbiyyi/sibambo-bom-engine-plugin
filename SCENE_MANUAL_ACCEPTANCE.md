# SIBAMBO — Scene / Page Preservation Manual Acceptance Guide

This document outlines the manual verification checklist in SketchUp for testing Scene / Page preservation on real models (e.g. `RUMAH L.skp`).

---

## 1. Test Model: `RUMAH L.skp`

### Verification Matrix

| Scene Name | Purpose | Expected Visible Geometry | Expected Hidden Geometry | Section Plane State |
|---|---|---|---|---|
| **PERS** | Architectural Perspective | Walls, Floors, Roof, Ceilings, Doors, Windows | Structural Beams/Columns (`STRUCT`) | Inactive / None |
| **STR** | Structural Overview | Columns, Beams, Foundations (`STRUCT`) | Walls, Finishes, Furniture (`ARCH`) | Inactive / None |
| **LT1** | Ground Floor Plan | Floor 1 Walls, Doors, Windows, Slabs | Floor 2, Roof, Foundations | Floor 1 Plan Section (if active) |
| **LT2** | Upper Floor Plan | Floor 2 Walls, Doors, Windows, Slabs | Floor 1, Roof, Foundations | Floor 2 Plan Section (if active) |
| **TAMPAK A** | Front Elevation | Full Exterior Front Facade | Interior-only objects | None |
| **TAMPAK B** | Side Elevation | Full Exterior Side Facade (Camera rotated) | Interior-only objects | None |
| **POT A / POT B** | Architectural Sections | Sectioned Interior / Structural Cut | Geometry behind cut plane | Section Plane Active (`sectionStateUnsupported = true` reported in metadata-only mode) |

---

## 2. Export Modes

### A. Active Scene Export (`scene_scope: 'active'`)
1. In SketchUp, select page `PERS`.
2. Run BOM Engine Export (Active View / Current Scene).
3. Open exported `.bomc` in Model-Eval.
4. **Pass Criteria**:
   - Only `PERS` required geometry is present in the runtime.
   - `STRUCT` objects are completely omitted from the scoped export.
   - Container header has flag `FLAG_SCOPE_ACTIVE` (`0x0100`).

### B. All Scenes Export (`scene_scope: 'all'`)
1. In SketchUp, ensure all pages (`PERS`, `STR`, `LT1`, `LT2`, `TAMPAK A`, `TAMPAK B`) are present.
2. Run BOM Engine Export (All Scenes).
3. Open exported `.bomc` in Model-Eval.
4. **Pass Criteria**:
   - Union-of-visible geometry is exported ONCE (zero geometry duplication).
   - Container header has flag `FLAG_SCOPE_ALL` (`0x0200`) and `FLAG_HAS_SCENES` (`0x0400`).
   - Switching between `PERS` and `STR` in Model-Eval updates instance visibility in < 100 ms with 0 mesh rebuilds.
   - Switching between `TAMPAK A` and `TAMPAK B` executes instant camera transition with 0 room analysis recalculation (identical `visibilitySignature`).
   - Analytical Room Detection under `PERS` detects room enclosures without structural contamination.
   - Analytical Room Detection under `STR` reports `"This scene does not contain sufficient room-boundary geometry."` without inventing false rooms.
