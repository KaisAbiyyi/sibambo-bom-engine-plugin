# Manual SketchUp acceptance — {{PACKAGE_NAME}}

Source commit: `{{GIT_COMMIT}}`

Record SketchUp/Windows versions, model names, output sizes, SHA-256 hashes, material counts, and any visual mismatch. This package was built on a computer without SketchUp; acceptance is pending.

## A. Install and simple fixture

Install using `INSTALL.md`. Export a painted simple fixture through **Plugins > BOM Engine Clean Analysis (Experimental) > Export Clean Analysis JSON...**. Confirm format `bom_engine_clean_v1` version `1.0.0`, a top-level `materials` array, normalized RGBA/opacity, and front/back references where explicitly painted. Confirm an unpainted face remains without a material reference.

## B. RUMAH L structure and size

Export RUMAH L as `RUMAH_L_run1_clean.json`. The optimized baseline was approximately 26 MB (prior measured files were about 27.3 MB). Reasonable compact appearance overhead is acceptable; regression toward 60–300 MB is FAIL.

Confirm shared definitions, lightweight instances, definition-local pooled vertices, indexed polygon topology, holes, and analytical surfaces remain present. Confirm there is no triangle dump or occurrence-expanded definition geometry.

## C. Determinism

Without modifying, saving, renaming, or reopening RUMAH L, export `RUMAH_L_run2_clean.json` with identical options:

```powershell
Get-FileHash '<path>\RUMAH_L_run1_clean.json' -Algorithm SHA256
Get-FileHash '<path>\RUMAH_L_run2_clean.json' -Algorithm SHA256
```

PASS requires byte-identical sizes and SHA-256 hashes.

## D. Appearance inspection

Inspect run 1 and verify:

- `materials` exists and material IDs resolve;
- painted walls carry front/back material references as appropriate;
- roof references exist where the source roof is painted;
- window and door definition polygons and/or retained instances carry the relevant references;
- one material is not repeated as full properties on every polygon;
- explicit face paint remains distinguishable from default faces inheriting occurrence paint;
- texture values are metadata only, with no embedded image bytes and no fabricated UV data.

Example summary:

```powershell
$clean = Get-Content -Raw -LiteralPath '<path>\RUMAH_L_run1_clean.json' | ConvertFrom-Json
[pscustomobject]@{
  Bytes = (Get-Item '<path>\RUMAH_L_run1_clean.json').Length
  Materials = $clean.materials.Count
  AnalyticalSurfaces = $clean.surfaces.Count
  Definitions = $clean.definitions.Count
  DefinitionSurfaces = ($clean.definitions.geometry.surfaces | Measure-Object).Count
  Instances = $clean.instances.Count
}
```

## E. Model-Eval visual acceptance

Load the run 1 CleanV1 JSON in Model-Eval. Compare wall, floor, ceiling, roof, window, and door base colors and opacity against the source SketchUp model. Record front/back or inheritance errors separately. Texture image/UV fidelity is deferred for this build.

Until A–E pass in real SketchUp:

```text
SKETCHUP ACCEPTANCE: PENDING
FREEZE bom_engine_clean_v1: NOT YET
```
