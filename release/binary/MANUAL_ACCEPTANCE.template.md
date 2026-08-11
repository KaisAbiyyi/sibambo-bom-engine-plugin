# Manual SketchUp binary package acceptance

Package: `{{PACKAGE_NAME}}`

Commit: `{{GIT_COMMIT}}`

Export the unchanged complex model using **Export Optimized Clean Package (.cleanpkg)...**.

Record source SKP bytes; old `model.json`, asset, and ZIP bytes; new `manifest.json`, `buffers.bin`, asset, and `.cleanpkg` bytes; export time; analytical, visual-retained, excluded, fallback, unaccounted, definition, instance, material, and texture counts.

Required: `unaccounted = 0`. Coverage counts must match the equivalent Clean Visual export.

Visually verify windows, window frames, doors, door frames, roof detail, railings, balusters, facade detail, fences, and textures. Confirm rotated/scaled/repeated UVs, transparent textures, front/back materials, mirrored instances, non-uniform scale, nested instances, holes, fallback geometry, and visual edges.

Export twice and compare `manifest.json`, `buffers.bin`, asset, and whole-package SHA256 values. Record the final result as `REAL SKETCHUP BINARY PACKAGE ACCEPTANCE: PASS/FAIL`.
