# Sibambo BOM Engine Plugin

Repo producer aktif untuk dua jalur paket SketchUp: **BOMC 1.2 individual** dan **Evolution E1–E4**. Kandidat terbaru, SHA, dan statusnya ada di [indeks output workspace](../outputs/README.md); perjalanan E4 ada di [milestone](MILESTONE_EVOLUTION_LINEUP_2026-09-25.md). Keduanya belum tersertifikasi lintas-model.

Paket individual dibangun dari runtime repo ini dengan [`tools/build_individual_candidate.ps1`](tools/build_individual_candidate.ps1); paket Evolution dibangun dari [`tools/history/build_evolution_lineup.rb`](tools/history/build_evolution_lineup.rb). Script lama `package.ps1` masih memakai SHA **commit** pada worktree yang bisa dirty dan menulis RBZ ke root workspace; jangan pakai itu untuk menyatakan identitas kandidat saat ini.

Bagian JSON di bawah mendokumentasikan jalur historis yang masih dipertahankan di repo, **bukan** petunjuk paket E4 terkini.

SketchUp Ruby extension. Exports a SketchUp model or active selection into Sibambo BOM JSON for downstream visualization and building analysis.

## Repository network

- [Sibambo Model Viewer](https://github.com/KaisAbiyyi/sibambo-model-viewer): browser viewer for visual BOM exports.
- [Sibambo Model Eval](https://github.com/KaisAbiyyi/sibambo-model-eval): SvelteKit application for early-stage building evaluation.

Version 3.1 adds label-aware export. Name a Group/Component in Entity Info or attach leader text to it (for example `Pintu Utama`, `Jendela Kamar`, or `Dinding Luar`). Model-Eval JSON v1.1 records the label, its source, the normalized building role, and a `label_first` policy. Tags and component definition names are lower-priority fallbacks; generated names and `Untagged` are ignored.

## What it exports

Plugin writes geometry, hierarchy, transforms, material information, holes/openings, and—on `full` export—texture and spatial-analysis data. Geometry uses metres in world space. SketchUp stores native lengths in inches; exporter converts them before writing JSON.

| Level | Purpose |
| --- | --- |
| `visual` | Small geometry payload for viewers. |
| `standard` | Geometry, material and hierarchy basics. |
| `full` | UV/material library, optional textures, tags, scenes, definitions and spatial analysis. |

Exports default to gzip. A source name such as `house_bom.json` becomes `house_bom_visual.json.gz`, `house_bom_standard.json.gz`, or `house_bom_full.json.gz`.

## Legacy JSON installation notes

1. Pilih paket yang sesuai dari [output bertanggal](../outputs/README.md). Untuk membangun ulang kandidat individual, jalankan `tools/build_individual_candidate.ps1`; untuk Evolution, pakai builder lineup dan periksa manifest/SHA hasilnya. Langkah `package.sh`/`package.ps1` di dokumen lama bukan jalur kandidat saat ini.
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

- `.skp` source models are deliberately **local-only** and ignored by Git (including those formerly tracked in `skps/`); never re-add them to a PR. Keep safe JSON fixtures, hashes, size/provenance manifests and user-approved local SketchUp qualification separate. Historical Git commits may still contain prior SKP bytes; this change does not rewrite history.
- [Plugin development guide](SKETCHUP_PLUGIN_DEV.md)
- [Canonical v3 format](FORMAT_V3.md)
- [BOME2 format](BOME2_FORMAT.md)
- [Model Eval JSON guide](MODEL_EVAL_JSON_GUIDE.md)

## License

GPL-3.0-only. See [LICENSE](LICENSE).

## Multi-agent orchestration

See [AGENTS.md](AGENTS.md) and [docs/AGENT-ORCHESTRATION.md](docs/AGENT-ORCHESTRATION.md) for unassigned tasks, exclusive agent claims, pushed checkpoint/recovery, author attribution, and cross-repository Sibambo integration acceptance. SketchUp-specific manual acceptance and E4 qualification remain required.
