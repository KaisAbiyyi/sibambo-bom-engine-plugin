# Manual SketchUp texture acceptance

Package: `{{PACKAGE_NAME}}`  
Commit: `{{GIT_COMMIT}}`

## A. Simple textured box

1. Apply different textures to walls, including one rotated/scaled texture.
2. Apply a transparent textured material and a distinct back-face texture.
3. Export **Clean Visual Package...** and inspect `model.json` plus `assets/`.
4. Verify orientation, scale, repetition, front/back appearance, and opacity in the consumer.

## B. Complex real model

1. Export the unchanged complex model as Clean Visual.
2. Confirm shared definitions remain shared and excluded entourage assets are absent.
3. Confirm every material asset reference resolves to exactly one ZIP entry.

## C. Size

Record `model.json` bytes, summed texture asset bytes, total ZIP bytes, unique texture count, original texture references, dedup ratio, and UV JSON overhead.

## D. Determinism

Export twice. Extract both packages and confirm the `model.json` SHA256 values match and every texture filename/hash matches.

## E. Model-Eval inspection

Later inspect texture orientation, scale, repetition, opacity, and instance appearance. Record the final result as `REAL SKETCHUP TEXTURE ACCEPTANCE: PASS/FAIL`.
