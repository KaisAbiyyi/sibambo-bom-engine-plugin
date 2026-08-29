# Historical Origin & Attribution

- **Version ID**: `SBE-2026.08.29-01`
- **Label**: `[18] 2026-08-29 — Scene/Page BOMC — Resilient Texture-Heavy Export`
- **Date**: `2026-08-29T00:10:00+07:00`
- **Source Repository**: [https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin](https://github.com/KaisAbiyyi/sibambo-bom-engine-plugin)
- **Commit SHA**: `a158b75dca55766e0d53a74349a9a746e98c06d3`
- **Commit Message**: `fix(export): publish complete BOMC when size target is missed`
- **Classification**: `RELEASE`
- **License**: GNU General Public License v3.0 (GPL-3.0)

## Historical Intent
Production Scene/Page BOMC exporter that keeps the smaller-than-SKP target as a diagnostic while atomically publishing the best complete lossless candidate for texture-heavy models.

## Selection Reason
First Evolution Lab exporter that does not reject a valid complete BOMC solely because container bytes exceed the differently compressed source SKP.
