# BOMC 1.0 Manual Acceptance

This acceptance pass belongs to the user because automated development must not open or automate SketchUp.

## Install

1. In SketchUp, open Extension Manager.
2. Install the supplied RC `.rbz`.
3. Restart SketchUp if Extension Manager requests it.
4. Confirm legacy Canonical JSON, BOME2, and Model-Eval JSON commands remain available.
5. Confirm `BOM Engine: Export Compiled BOMC...` is available.

## Known complex model export

Open the known complex model, preferably `RUMAH L.skp`, and export production BOMC. The command must publish one `.bomc` file with no required adjacent manifest, buffer, or assets folder.

Record exact values:

| Measurement | Result |
|---|---|
| SKP bytes | |
| Old Clean JSON bytes | |
| Old Clean Visual package bytes | |
| Old CleanPackage bytes | |
| New BOMC bytes | |
| BOMC percentage of SKP | |
| BOMC percentage of CleanPackage | |
| Export time | |
| Analytical count | |
| Visual-retained count | |
| Fallback count | |
| Explicitly excluded count | |
| Unaccounted count | |
| Definitions | |
| Instances | |
| Textures referenced | |
| Unique texture blobs | |

Hard acceptance requirement:

```text
unaccounted = 0
```

If `unaccounted` is nonzero, keep the `.bomc`, record the model/exporter log, and treat the RC as failed even if the file is small.

## One-file and determinism checks

- Move the `.bomc` by itself to a different folder. It must remain the only required file.
- Export the unchanged model twice with the same production profile.
- Compute SHA256 for both outputs. They must match.
- Confirm there is no `.part` file after a successful export.
- Confirm no temporary texture folder remains beside the output.

## Model-Eval logical load

When the BOMC TypeScript loader is connected, record:

- header/version accepted as BOMC 1.0;
- directory parsed without loading all sections;
- analytical core load time;
- visual geometry load time;
- texture load time;
- total decode time;
- material, mesh, face, definition, instance, and texture counts;
- checksum failures, warnings, or missing references; and
- coverage with `unaccounted = 0`.

## Visual fidelity checklist

Compare the SketchUp model and Model-Eval view at close and whole-building scales:

- overall building geometry and bounds;
- walls, floors, ceilings, and room analytical surfaces;
- roof planes, ridges, slopes, overhangs, and small roof details;
- windows, glass, frames, mullions, and openings;
- doors, leaves, frames, and openings;
- railing posts, rails, balusters, and stairs;
- facade panels, trims, grooves, and other retained detail;
- mirrored components and non-uniformly scaled components;
- nested definitions and repeated components;
- hidden/soft/smooth visual-edge behavior;
- front and back materials;
- every texture's appearance, orientation, repeat, scale, and seam placement;
- negative and greater-than-one UV behavior; and
- holes, polygon winding, and triangle orientation.

Do not accept file-size savings caused by missing geometry, missing occurrences, flattened definitions, absent textures, or changed analytical classifications.

## Result

Record one:

- `PASS`: one-file load, visual/analytical fidelity accepted, counts reconcile, and `unaccounted = 0`.
- `FAIL`: attach exact discrepancy, object/material name, camera/view, counts, output SHA256, and exporter log.

REAL SKETCHUP COMPILED-FORMAT ACCEPTANCE: PENDING USER TEST
