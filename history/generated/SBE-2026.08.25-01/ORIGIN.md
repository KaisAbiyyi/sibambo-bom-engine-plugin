# Historical Origin & Attribution

- **Version ID**: `SBE-2026.08.25-01`
- **Label**: `[10] 2026-08-25 — Scene/Page BOMC — Correct Visibility Semantics`
- **Date**: `2026-08-25T13:45:00+07:00`
- **Source Repository**: [https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin](https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin)
- **Commit SHA**: `6501ff8fbaf325a536f4e8e5725db1bbcd8cbd23`
- **Commit Message**: `fix(scene): resolve explicit DrawingElement node overrides and deterministic visibility signatures`
- **Classification**: `RELEASE`
- **License**: GNU General Public License v3.0 (GPL-3.0)

## Historical Intent
Fix SketchUp Scene/Page DrawingElement node visibility overrides and calculate deterministic geometry visibility signatures that vary only when geometry visibility changes.

## Selection Reason
Corrected production Scene/Page BOMC exporter fixing silent skip in Model-Eval scene switching.
