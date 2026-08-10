# CleanV1 appearance contract

Package: `{{PACKAGE_NAME}}`

Source commit: `{{GIT_COMMIT}}`

The format remains `bom_engine_clean_v1` version `1.0.0`. Every field below is optional/additive except fields inside an emitted material record. A consumer that does not implement appearance can ignore them.

## Shared material table

`materials` is a top-level array sorted deterministically by the source material UUID. Each SketchUp source material is emitted once:

```json
{
  "id": "mat-0123456789abcdef",
  "name": "Wall Paint",
  "base_color_rgba": [0.72, 0.71, 0.68, 1.0],
  "opacity": 1.0,
  "color_space": "srgb",
  "texture": null
}
```

`id` is `mat-` followed by 16 lowercase hexadecimal characters derived by the existing deterministic CleanV1 stable-ID function from the material source UUID. `base_color_rgba` contains four normalized floating-point values in the inclusive range 0..1, converted directly from SketchUp's RGBA byte values. `opacity` repeats the alpha channel for convenient consumers and is also 0..1. `color_space` is `srgb`; no display transform is applied.

## Assignments and inheritance

Analytical `surfaces`, definition-local `geometry.surfaces`, and unresolved fallback surfaces may carry `front_material_id` and `back_material_id`. Their absence means the corresponding SketchUp face side used the default/unpainted material; no synthetic gray material is emitted.

Retained shared `instances` and compact `components` may carry `material_id`. Expanded analytical surfaces may instead carry `inherited_material_id`, preserving the occurrence paint without duplicating geometry. For rendering, an explicit face-side reference wins. An absent face-side reference may inherit the relevant occurrence `material_id`/`inherited_material_id` according to normal SketchUp hierarchy. Null/default and explicit paint therefore remain distinguishable.

## Texture metadata and UV status

When SketchUp reports a texture, `texture` may contain `reference` (filename basename), `width_m`, and `height_m`. The JSON never embeds image bytes, base64, data URIs, or absolute source paths. This build does not extract or copy texture assets.

Texture UV fidelity is deferred. No `uv`/`uvs` fields are emitted and no UV values are fabricated. Portable UV extraction requires SketchUp's live `UVHelper`, so base color and opacity are the acceptance target for this release candidate.
