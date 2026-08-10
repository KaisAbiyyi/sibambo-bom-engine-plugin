# Manual SketchUp acceptance — {{PACKAGE_NAME}}

Source commit: `{{GIT_COMMIT}}`

Record the SketchUp version, Windows version, model filename, output byte count, and SHA-256 results. Do not freeze `bom_engine_clean_v1` unless every test below passes in real SketchUp.

## Test A — simple fixture

1. Open the existing scratch/simple fixture in SketchUp.
2. Choose **BOM Engine Clean Analysis (Experimental) > Export Clean Analysis JSON...** from the menu registered under `UI.menu('Plugins')`.
3. Save the result as `simple_clean.json` and wait for **Clean export complete**.
4. Confirm the JSON reports format `bom_engine_clean_v1`, version `1.0.0`.
5. Confirm no `triangles` property is serialized, polygon validation has not routed valid fixture geometry to `fallback_geometry`, and hole loops remain present and valid.
6. Confirm Sree/human entourage is excluded as before and other entourage behavior matches the accepted baseline.

Useful PowerShell checks:

```powershell
$simple = Get-Content -Raw -LiteralPath '<path>\simple_clean.json' | ConvertFrom-Json
$simple.format
if ((Get-Content -Raw -LiteralPath '<path>\simple_clean.json') -match '"triangles"\s*:') { throw 'serialized triangles found' }
$simple.fallback_geometry
```

## Test B — complex real architecture

1. Open the same real architecture model used for the previous optimized runs.
2. Export to `complex_run1_clean.json` without modifying the model.
3. Confirm the export completes and inspect the byte size.

Previous optimized sizes were 27,303,023 and 27,305,000 bytes. A small change caused by deterministic IDs is acceptable. A regression toward 67 MB or 307 MB fails acceptance.

## Test C — determinism

1. Without modifying, saving, renaming, or reopening the model, export again to `complex_run2_clean.json` using the same options.
2. Compare the actual bytes with SHA-256:

```powershell
Get-FileHash '<path>\complex_run1_clean.json' -Algorithm SHA256
Get-FileHash '<path>\complex_run2_clean.json' -Algorithm SHA256
```

PASS requires identical hashes and identical file sizes. Any difference fails acceptance; retain both files for diagnosis.

## Test D — retained structure

Inspect `complex_run1_clean.json` and confirm it still has approximately the accepted structure:

- retained shared definitions (previously about 431);
- lightweight instances (previously about 8,164);
- indexed definition-local vertex pools;
- analytical surfaces (previously about 8,627);
- holes (previously about 478);
- no occurrence-expanded duplication of definition geometry.

The previous definition-surface count was about 177,326 and the total polygon count about 185,953. Large movement toward occurrence-expanded geometry is a failure.

Useful PowerShell structure summary:

```powershell
$clean = Get-Content -Raw -LiteralPath '<path>\complex_run1_clean.json' | ConvertFrom-Json
[pscustomobject]@{
  Definitions = $clean.definitions.Count
  Instances = $clean.instances.Count
  AnalyticalSurfaces = $clean.surfaces.Count
  DefinitionSurfaces = ($clean.definitions.geometry.surfaces | Measure-Object).Count
  PooledVertices = ($clean.definitions.geometry.vertices | Measure-Object).Count
}
```

## Acceptance result

Report each test as PASS or FAIL and attach both complex JSON hashes, sizes, and the structure summary. Until all four tests pass:

```text
SKETCHUP ACCEPTANCE: PENDING
FREEZE bom_engine_clean_v1: NOT YET
```
