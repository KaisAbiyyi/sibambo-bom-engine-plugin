# Sibambo BOM Engine Plugin

SketchUp Ruby extension. Exports a SketchUp model or active selection into Sibambo BOM JSON for downstream visualization and building analysis.

## Repository network

- [Sibambo Model Viewer](https://github.com/KaisAbiyyi/sibambo-model-viewer): browser viewer for visual BOM exports.
- [Sibambo Model Eval](https://github.com/KaisAbiyyi/sibambo-model-eval): SvelteKit application for early-stage building evaluation.

## What it exports

Plugin writes geometry, hierarchy, transforms, material information, holes/openings, and—on `full` export—texture and spatial-analysis data. Geometry uses metres in world space. SketchUp stores native lengths in inches; exporter converts them before writing JSON.

| Level | Purpose |
| --- | --- |
| `visual` | Small geometry payload for viewers. |
| `standard` | Geometry, material and hierarchy basics. |
| `full` | UV/material library, optional textures, tags, scenes, definitions and spatial analysis. |

Exports default to gzip. A source name such as `house_bom.json` becomes `house_bom_visual.json.gz`, `house_bom_standard.json.gz`, or `house_bom_full.json.gz`.

## Install in SketchUp

1. Build an `.rbz` package with `./package.sh` (Git Bash/WSL) or `./package.ps1` (PowerShell).
2. In SketchUp Desktop, open **Extension Manager → Install Extension**.
3. Select generated `.rbz`, restart SketchUp if requested.
4. Use **Extensions → BOM Engine Exporter** or toolbar button.

SketchUp desktop is required. Runtime depends on `Sketchup`, `UI`, and `Geom` Ruby APIs.

## Development and verification

```powershell
ruby -c bom_engine_loader.rb
Get-ChildItem bom_engine -Recurse -Filter *.rb | ForEach-Object { ruby -c $_.FullName }
```

Runtime tests require SketchUp Ruby Console. Load test files from `bom_engine/tests/` there; standalone Ruby only verifies syntax.

Important rules:

- Calculate transformed area with `Traversal.world_area_m2`.
- Derive normal from world vertices with `Traversal.world_normal`.
- Preserve face `holes`; otherwise windows and doors render as filled faces.
- Use `Sketchup.create_texture_writer`, never `Sketchup::TextureWriter.new`.
- Keep export dialog scrollable and resizable.

## Data and documentation

- `skps/` contains tracked `.skp` source models and JSON exports used for manual validation. Do not remove it from version control.
- [Plugin development guide](SKETCHUP_PLUGIN_DEV.md)
- [Canonical v3 format](FORMAT_V3.md)
- [BOME2 format](BOME2_FORMAT.md)
- [Model Eval JSON guide](MODEL_EVAL_JSON_GUIDE.md)

## License

GPL-3.0-only. See [LICENSE](LICENSE).
