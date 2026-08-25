# Sibambo BOM Engine Evolution Lab — Manual Acceptance Guide

**Purpose**: Verify that all 10 historical BOM Engine exporter generations run side-by-side inside SketchUp without collisions, and benchmark format evolution on test models.

---

## 1. Test Preparation

### Test Models
1. **Model A (Controlled Fixture)**: A simple SketchUp model with:
   - 2 Groups (e.g. Wall, Floor)
   - 2 Component Instances of the same Component Definition (e.g. Column / Window)
   - 2 Scenes (`PERS`, `STR`)
   - 2 Tags (`Layer0`, `Struktur`)
2. **Model B (Production Benchmark)**: `RUMAH L.skp` (Full architectural house model with multiple scenes, materials, components, and section cuts).

---

## 2. Test Matrix

### Manual Test A — Extension Loading & Menu Hierarchy
1. Start SketchUp.
2. Open the **Ruby Console** (`Extensions -> Developer -> Ruby Console` or `Window -> Ruby Console`).
3. Verify that **no error messages** or duplicate constant warnings appear during startup.
4. Check the menu bar under **Extensions**:
   - Verify `Sibambo BOM Engine Evolution Lab` exists.
   - Verify submenu `Major & Release Versions` lists versions in **strict chronological order** (Oldest at top, Newest at bottom):
     - `[01] 2026-05-11 — Original BOM JSON`
     - `[02] 2026-05-11 — Visual / Standard / Full JSON`
     - `[03] 2026-05-11 — Minified Visual JSON`
     - `[04] 2026-07-16 — Canonical JSON v3 + Gzip`
     - `[05] 2026-07-16 — Model-Eval Compact JSON`
     - `[06] 2026-07-16 — BOME2 Binary Runtime`
     - `[07] 2026-08-12 — CleanPKG Binary Container`
     - `[08] 2026-08-13 — First BOMC Compiled Format`
     - `[09] 2026-08-19 — Scene/Page-Preserving BOMC`
     - `[10] 2026-08-25 — Scene/Page BOMC — Correct Visibility Semantics`
   - Verify submenu `Experiments` contains:
     - `[EXP-01] 2026-05-11 — Nano BBox JSON`
   - Verify the separate **Production BOM Engine** menu entry remains present and functional.

---

### Manual Test B & C — Small Model Export & Format Fingerprint Matrix (Model A)

Open Model A in SketchUp and execute each menu command once. Verify the output file matches the format fingerprint:

| Seq | Menu Item | Expected Output File | Format Fingerprint / Magic | Pass/Fail |
| :--- | :--- | :--- | :--- | :--- |
| **01** | `[01] Original BOM JSON` | `*_SBE-2026.05.11-01_bom.json` | First char is `{`, contains `"schema_version": "2.0"` | [ ] |
| **02** | `[02] Visual/Standard/Full` | `*_SBE-2026.05.11-02_visual.json` | JSON with `"export_level": "visual"` | [ ] |
| **EXP**| `[EXP-01] Nano BBox` | `*_SBE-2026.05.11-EXP_nano.json` | JSON with `"bounding_box"` array, no faces | [ ] |
| **03** | `[03] Minified Visual JSON`| `*_SBE-2026.05.11-03_visual.json` | Compact JSON (single line without newlines) | [ ] |
| **04** | `[04] Canonical v3 + Gzip` | `*_SBE-2026.07.16-01_canonical.json.gz` | Magic bytes `1F 8B` (gzip); decompresses to JSON | [ ] |
| **05** | `[05] Model-Eval JSON` | `*_SBE-2026.07.16-02_model-eval.json` | JSON with `positions`, `faces`, `strings` tables | [ ] |
| **06** | `[06] BOME2 Binary` | `*_SBE-2026.07.16-03_runtime.bome2` | Magic ASCII `BOME2\n` (bytes: `42 4F 4D 45 32 0A`) | [ ] |
| **07** | `[07] CleanPKG Container` | `*_SBE-2026.08.12-01.cleanpkg` | ZIP magic `PK\x03\x04` containing `manifest.json` & `buffers.bin` | [ ] |
| **08** | `[08] First BOMC` | `*_SBE-2026.08.13-01.bomc` | Magic bytes `BOMC\x01\x00\x00\x00` (8 bytes) | [ ] |
| **09** | `[09] Scene BOMC` | `*_SBE-2026.08.19-01.bomc` | Magic `BOMC\x01\x00\x00\x00` + Section 19 (Initial layout) | [ ] |
| **10** | `[10] Correct Scene BOMC` | `*_SBE-2026.08.25-01.bomc` | Magic `BOMC\x01\x00\x00\x00` + Section 19 (Node overrides + dynamic signatures) | [ ] |

---

### Manual Test D — RUMAH L Production Benchmark

Open `RUMAH L.skp` and export using the major lineage engines:
1. Export with `[01] Original BOM JSON` -> Record export time & file size.
2. Export with `[03] Minified Visual JSON` -> Record export time & file size.
3. Export with `[04] Canonical JSON v3 (Gzip)` -> Record export time & file size.
4. Export with `[06] BOME2 Binary` -> Record export time & file size.
5. Export with `[07] CleanPKG` -> Record export time & file size.
6. Export with `[09] Scene/Page BOMC` -> Record export time & file size.
7. Export with `[10] Scene/Page BOMC — Correct Visibility Semantics` -> Record export time & file size.

Record your measured values in [`history/BENCHMARK_TEMPLATE.csv`](file:///d:/projects/sibambo/bom_engine_plugin/history/BENCHMARK_TEMPLATE.csv).

---

### Manual Test E — Scene/Page Preservation Acceptance (`RUMAH L.skp`)

Using `[10] 2026-08-25 — Scene/Page BOMC — Correct Visibility Semantics`:
1. In SketchUp, go to:
   **Extensions -> Sibambo BOM Engine Evolution Lab -> Major Release Versions -> [10] 2026-08-25 — Scene/Page BOMC — Correct Visibility Semantics**
2. Export `RUMAH L.skp`.
3. Open `model-eval` web viewer (`http://localhost:5173/`).
4. Load the exported `.bomc` file.
5. Test scene switcher buttons:
   - [ ] `PERS`: Perspective camera, furniture and architectural tags visible.
   - [ ] `STR`: Structural elements only; furniture and wall finishes hidden.
   - [ ] `LT1`: First floor plan view; upper levels hidden.
   - [ ] `LT2`: Second floor plan view.
   - [ ] `TAMPAK A` / `TAMPAK B`: Orthographic elevation views with correct cameras.
   - [ ] `POT A` / `POT B`: Section metadata recognized (marked metadata-only).
   - [ ] **Performance**: Scene transitions execute instantly without full model re-decode or mesh rebuild.
   - [ ] **Historical Compare**: Repeat with `[09]` to observe that `[09]` missed per-scene node visibility overrides while `[10]` properly changes geometry between scenes.

---

## 3. Troubleshooting & Uninstallation

- If you need to reinstall the Evolution Lab:
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\history\install_evolution_lab.ps1
  ```
- If you need to remove the Evolution Lab:
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools\history\uninstall_evolution_lab.ps1
  ```
- The current production BOM Engine remains untouched in the Plugins directory under `bom_engine_loader.rb`.
