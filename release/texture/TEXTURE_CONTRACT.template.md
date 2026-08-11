# CleanV1 texture contract

Package: `{{PACKAGE_NAME}}`  
Commit: `{{GIT_COMMIT}}`

- JSON-only export retains the existing CleanV1 document contract.
- Clean Visual produces a ZIP with deterministic `model.json` and content-addressed `assets/tex-<sha256>.<ext>` entries.
- Texture bytes are never embedded in JSON.
- Materials retain sRGB fallback color, opacity, physical texture dimensions, and an asset reference or explicit missing status.
- UVs come from SketchUp UVHelper UVQ coordinates divided by Q. Invalid UVQ values are omitted, never synthesized.
- Root surfaces use a document UV pool. Shared definitions use one definition-local UV pool and remain instanced.
- Textured analytical faces are not coplanar-merged because a merged UV boundary cannot be inferred safely.
- Only assets referenced by emitted materials are packaged.
