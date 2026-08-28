# Historical Origin & Attribution

- **Version ID**: `SBE-2026.08.28-01`
- **Label**: `[17] 2026-08-28 — Scene/Page BOMC — Compiled Face/Edge Visibility`
- **Date**: `2026-08-28T20:05:00+07:00`
- **Source Repository**: [https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin](https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin)
- **Commit SHA**: `6b0d381f9b03c701e27be01f5a2ccb6a1a3b9c9c`
- **Commit Message**: `fix(scenes): preserve primitive visibility in shared BOMC universe`
- **Classification**: `RELEASE`
- **License**: GNU General Public License v3.0 (GPL-3.0)

## Historical Intent
Shared-universe Scene/Page BOMC exporter preserving top-level SketchUp Face and Edge hide/show overrides as stable identities compiled to runtime indices, with explicit unresolved primitive diagnostics.

## Selection Reason
First production Scene/Page BOMC contract that carries non-instance drawing geometry visibility through Section 19 v4 instead of silently discarding it.
