# Manual SketchUp acceptance

Package: `{{PACKAGE_NAME}}`
Commit: `{{GIT_COMMIT}}`

## Test A - installation

1. Close SketchUp and disable `bom_engine_clean_dev_loader.rb` if it is installed.
2. Install `{{PACKAGE_NAME}}.rbz` with Extension Manager.
3. Restart SketchUp.
4. Confirm exactly one **BOM Engine Clean Analysis (Experimental)** menu exists.
5. Run **Plugins > BOM Engine Clean Analysis (Experimental) > Development Build Info** and record its output.

## Test B - simple box

1. Open the simple box model and run **Export Clean Analysis JSON...**.
2. Record output bytes and elapsed export time.
3. Record material count, analytical surfaces, `diagnostics.topology.top_level_unique_vertices`, and `diagnostics.coverage.unaccounted`.
4. Expect six primary surfaces when the source really is a closed six-face box, approximately eight unique box corners, only referenced materials, and `unaccounted = 0`.
5. Do not hardcode classification when explicit source semantics say otherwise.

## Test C - complex real architecture

1. Open the known complex architecture model without changing visibility.
2. Export CleanV1 and record bytes, conversion time, analytical count, visual-retained count, fallback, excluded, unaccounted, definitions, instances, polygons, standalone edges, and materials.
3. Required coverage condition: `diagnostics.coverage.unaccounted = 0`.
4. Real conversion time is accepted or rejected from this manual run only.

## Test D - visual detail

Open the output in Model-Eval/viewer and compare source and output individually: windows, window frames, doors, door frames, railings, balusters, roof trim/details, facade profiles, fences, and nested components. For each missing eligible detail, record its source name/category and coverage disposition/reason. Do not pass if eligible visible detail disappears.

## Test E - appearance

Check wall and roof colors, door/window colors, instance-painted components, and transparency. Texture images and UV fidelity remain outside this candidate's scope.

## Test F - determinism

Export the unchanged complex model twice, then run:

```powershell
Get-FileHash "run1.json" -Algorithm SHA256
Get-FileHash "run2.json" -Algorithm SHA256
```

The hashes must match exactly.

## Test G - size

Compare with the previous approximately 26 MB result. Growth is acceptable when it restores missing detail. Fail unexplained growth caused by occurrence expansion, duplicated definitions, unused materials, or avoidable repeated geometry.

Record the final result as `REAL SKETCHUP ACCEPTANCE: PASS/FAIL`.
