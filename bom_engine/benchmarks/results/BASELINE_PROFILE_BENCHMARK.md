# BOMC Profile Benchmark: Legacy Baseline Report

**Producer SHA:** `529daa3b3e31a15751765023dc14ff59061f531d`  
**Timestamp:** 2026-08-29 03:36:55 UTC  
**Fixtures Measured:** 6

---

## Legacy Baseline Summary Table

| Fixture | SKP Bytes | Legacy Strategy | BOMC Bytes | Ratio vs SKP | Legacy Status | Textures (Unique / Bytes) |
|---|---|---|---|---|---|---|
| tiny-box | 160.1 KB (163,941 B) | `standard` | 767 B | 0.5% | `pass` | 0 / 0 B |
| small-textured-house2 | 429.7 KB (440,016 B) | `standard` | 41.76 KB (42,760 B) | 9.7% | `pass` | 0 / 0 B |
| medium-architectural-presentation20 | 2.06 MB (2,155,445 B) | `standard` | 113.29 KB (116,008 B) | 5.4% | `pass` | 0 / 0 B |
| complex-architectural-sboost1 | 3.38 MB (3,548,875 B) | `standard` | 123.82 KB (126,792 B) | 3.6% | `pass` | 0 / 0 B |
| texture-heavy-rumah-y | 39.85 MB (41,785,434 B) | `standard` | 1.55 MB (1,622,216 B) | 3.9% | `pass` | 0 / 0 B |
| scene-heavy-sboost2 | 3.21 MB (3,363,219 B) | `standard` | 123.86 KB (126,832 B) | 3.8% | `pass` | 0 / 0 B |

---

## Detailed Fixture Breakdown

### tiny-box

- **Source Fixture:** `D:/projects/sibambo/bom_engine_plugin/examples/model-eval-json-v1-small.json`
- **SKP Size:** 160.1 KB (163,941 B)
- **Legacy Result:** 767 B (`standard`, status: `pass`, ratio: 0.5%)

#### Section Breakdown

| Section | Raw Bytes | Stored Bytes | Codec | Count |
|---|---|---|---|---|
| `model` | 94 B | 32 B | DEFLATE | 1 |
| `strings` | 137 B | 106 B | DEFLATE | 10 |
| `materials` | 25 B | 23 B | DEFLATE | 1 |
| `tags` | 10 B | 10 B | STORE | 1 |
| `meshes` | 53 B | 28 B | DEFLATE | 1 |
| `faces` | 34 B | 25 B | DEFLATE | 1 |
| `positions` | 108 B | 27 B | DEFLATE | 1 |
| `topology` | 30 B | 25 B | DEFLATE | 1 |
| `normals` | 16 B | 16 B | STORE | 1 |
| `definitions` | 14 B | 14 B | STORE | 2 |
| `instances` | 32 B | 32 B | STORE | 2 |
| `transforms` | 92 B | 25 B | DEFLATE | 2 |
| `coverage` | 24 B | 15 B | DEFLATE | 1 |

#### Codec Metrics

- **Normals Codec:** 2 (1 items, 0 B)
- **Transforms:** 2 transforms, 0 uniform scale
- **Topology Saved Bytes:** 10 B

### small-textured-house2

- **Source Fixture:** `D:/projects/sibambo/bom_engine_plugin/skps/model-eval-exports/house2_model-eval.json`
- **SKP Size:** 429.7 KB (440,016 B)
- **Legacy Result:** 41.76 KB (42,760 B) (`standard`, status: `pass`, ratio: 9.7%)

#### Section Breakdown

| Section | Raw Bytes | Stored Bytes | Codec | Count |
|---|---|---|---|---|
| `model` | 94 B | 86 B | DEFLATE | 1 |
| `strings` | 8.98 KB (9,192 B) | 1.73 KB (1,767 B) | DEFLATE | 164 |
| `materials` | 331 B | 133 B | DEFLATE | 19 |
| `tags` | 14 B | 14 B | STORE | 5 |
| `meshes` | 1.63 KB (1,673 B) | 635 B | DEFLATE | 37 |
| `faces` | 17.45 KB (17,871 B) | 2.1 KB (2,146 B) | DEFLATE | 1777 |
| `positions` | 18.76 KB (19,212 B) | 11.73 KB (12,015 B) | DEFLATE | 37 |
| `topology` | 29.04 KB (29,734 B) | 19.69 KB (20,158 B) | DEFLATE | 37 |
| `normals` | 6.95 KB (7,120 B) | 3.78 KB (3,867 B) | DEFLATE | 1777 |
| `definitions` | 131 B | 105 B | DEFLATE | 41 |
| `instances` | 922 B | 311 B | DEFLATE | 91 |
| `transforms` | 3.53 KB (3,612 B) | 1.1 KB (1,125 B) | DEFLATE | 90 |
| `coverage` | 24 B | 16 B | DEFLATE | 1 |

#### Codec Metrics

- **Normals Codec:** 2 (1777 items, 0 B)
- **Transforms:** 90 transforms, 0 uniform scale
- **Topology Saved Bytes:** 71.39 KB (73,099 B)

### medium-architectural-presentation20

- **Source Fixture:** `D:/projects/sibambo/bom_engine_plugin/skps/model-eval-exports/presentation20_model-eval.json`
- **SKP Size:** 2.06 MB (2,155,445 B)
- **Legacy Result:** 113.29 KB (116,008 B) (`standard`, status: `pass`, ratio: 5.4%)

#### Section Breakdown

| Section | Raw Bytes | Stored Bytes | Codec | Count |
|---|---|---|---|---|
| `model` | 96 B | 90 B | DEFLATE | 1 |
| `strings` | 33.01 KB (33,803 B) | 4.46 KB (4,570 B) | DEFLATE | 603 |
| `materials` | 597 B | 225 B | DEFLATE | 31 |
| `tags` | 19 B | 19 B | STORE | 5 |
| `meshes` | 5.06 KB (5,183 B) | 1.52 KB (1,561 B) | DEFLATE | 115 |
| `faces` | 125.05 KB (128,051 B) | 4.07 KB (4,170 B) | DEFLATE | 11625 |
| `positions` | 114.67 KB (117,420 B) | 30.76 KB (31,500 B) | DEFLATE | 115 |
| `topology` | 141.67 KB (145,072 B) | 50.69 KB (51,908 B) | DEFLATE | 115 |
| `normals` | 45.42 KB (46,512 B) | 14.58 KB (14,928 B) | DEFLATE | 11625 |
| `definitions` | 756 B | 258 B | DEFLATE | 187 |
| `instances` | 5.68 KB (5,820 B) | 1.29 KB (1,318 B) | DEFLATE | 484 |
| `transforms` | 7.78 KB (7,962 B) | 4.93 KB (5,047 B) | DEFLATE | 206 |
| `coverage` | 24 B | 16 B | DEFLATE | 1 |

#### Codec Metrics

- **Normals Codec:** 2 (11625 items, 0 B)
- **Transforms:** 206 transforms, 0 uniform scale
- **Topology Saved Bytes:** 347.13 KB (355,462 B)

### complex-architectural-sboost1

- **Source Fixture:** `D:/projects/sibambo/bom_engine_plugin/skps/model-eval-exports/PROJECT SBOOST 1_model-eval.json`
- **SKP Size:** 3.38 MB (3,548,875 B)
- **Legacy Result:** 123.82 KB (126,792 B) (`standard`, status: `pass`, ratio: 3.6%)

#### Section Breakdown

| Section | Raw Bytes | Stored Bytes | Codec | Count |
|---|---|---|---|---|
| `model` | 96 B | 88 B | DEFLATE | 1 |
| `strings` | 12.84 KB (13,153 B) | 3.21 KB (3,286 B) | DEFLATE | 305 |
| `materials` | 958 B | 304 B | DEFLATE | 50 |
| `tags` | 55 B | 55 B | STORE | 22 |
| `meshes` | 3.08 KB (3,158 B) | 965 B | DEFLATE | 70 |
| `faces` | 76.28 KB (78,110 B) | 4.25 KB (4,354 B) | DEFLATE | 7092 |
| `positions` | 52.72 KB (53,988 B) | 31.56 KB (32,322 B) | DEFLATE | 70 |
| `topology` | 94.89 KB (97,168 B) | 57.7 KB (59,086 B) | DEFLATE | 70 |
| `normals` | 27.71 KB (28,380 B) | 23.4 KB (23,966 B) | DEFLATE | 7092 |
| `definitions` | 468 B | 267 B | DEFLATE | 115 |
| `instances` | 1.58 KB (1,620 B) | 613 B | DEFLATE | 134 |
| `transforms` | 3.92 KB (4,012 B) | 1.07 KB (1,091 B) | DEFLATE | 100 |
| `coverage` | 24 B | 16 B | DEFLATE | 1 |

#### Codec Metrics

- **Normals Codec:** 2 (7092 items, 0 B)
- **Transforms:** 100 transforms, 0 uniform scale
- **Topology Saved Bytes:** 176.95 KB (181,199 B)

### texture-heavy-rumah-y

- **Source Fixture:** `D:/projects/sibambo/bom_engine_plugin/skps/model-eval-exports/RUMAH Y_model-eval.json`
- **SKP Size:** 39.85 MB (41,785,434 B)
- **Legacy Result:** 1.55 MB (1,622,216 B) (`standard`, status: `pass`, ratio: 3.9%)

#### Section Breakdown

| Section | Raw Bytes | Stored Bytes | Codec | Count |
|---|---|---|---|---|
| `model` | 96 B | 95 B | DEFLATE | 1 |
| `strings` | 198.38 KB (203,144 B) | 24.53 KB (25,121 B) | DEFLATE | 3833 |
| `materials` | 2.33 KB (2,383 B) | 680 B | DEFLATE | 125 |
| `tags` | 130 B | 96 B | DEFLATE | 57 |
| `meshes` | 42.05 KB (43,064 B) | 9.35 KB (9,578 B) | DEFLATE | 936 |
| `faces` | 1.28 MB (1,340,960 B) | 41.96 KB (42,967 B) | DEFLATE | 121833 |
| `positions` | 800.73 KB (819,948 B) | 441.92 KB (452,524 B) | DEFLATE | 936 |
| `topology` | 1.43 MB (1,500,036 B) | 699.53 KB (716,318 B) | DEFLATE | 936 |
| `normals` | 475.92 KB (487,344 B) | 341.02 KB (349,200 B) | DEFLATE | 121833 |
| `definitions` | 5.59 KB (5,723 B) | 2.0 KB (2,049 B) | DEFLATE | 1143 |
| `instances` | 46.59 KB (47,712 B) | 8.41 KB (8,612 B) | DEFLATE | 3180 |
| `transforms` | 69.97 KB (71,645 B) | 14.24 KB (14,583 B) | DEFLATE | 2145 |
| `coverage` | 24 B | 16 B | DEFLATE | 1 |

#### Codec Metrics

- **Normals Codec:** 2 (121833 items, 0 B)
- **Transforms:** 2145 transforms, 0 uniform scale
- **Topology Saved Bytes:** 3.12 MB (3,276,758 B)

### scene-heavy-sboost2

- **Source Fixture:** `D:/projects/sibambo/bom_engine_plugin/skps/model-eval-exports/PROJECT SBOOST 2_model-eval.json`
- **SKP Size:** 3.21 MB (3,363,219 B)
- **Legacy Result:** 123.86 KB (126,832 B) (`standard`, status: `pass`, ratio: 3.8%)

#### Section Breakdown

| Section | Raw Bytes | Stored Bytes | Codec | Count |
|---|---|---|---|---|
| `model` | 96 B | 88 B | DEFLATE | 1 |
| `strings` | 11.1 KB (11,363 B) | 2.76 KB (2,831 B) | DEFLATE | 267 |
| `materials` | 920 B | 298 B | DEFLATE | 48 |
| `tags` | 49 B | 49 B | STORE | 19 |
| `meshes` | 2.91 KB (2,978 B) | 945 B | DEFLATE | 66 |
| `faces` | 75.79 KB (77,614 B) | 4.28 KB (4,382 B) | DEFLATE | 7047 |
| `positions` | 53.32 KB (54,604 B) | 32.01 KB (32,783 B) | DEFLATE | 66 |
| `topology` | 94.26 KB (96,520 B) | 57.95 KB (59,341 B) | DEFLATE | 66 |
| `normals` | 27.54 KB (28,200 B) | 23.35 KB (23,912 B) | DEFLATE | 7047 |
| `definitions` | 412 B | 240 B | DEFLATE | 101 |
| `instances` | 1.38 KB (1,416 B) | 520 B | DEFLATE | 117 |
| `transforms` | 3.84 KB (3,932 B) | 1.03 KB (1,055 B) | DEFLATE | 98 |
| `coverage` | 24 B | 16 B | DEFLATE | 1 |

#### Codec Metrics

- **Normals Codec:** 2 (7047 items, 0 B)
- **Transforms:** 98 transforms, 0 uniform scale
- **Topology Saved Bytes:** 176.81 KB (181,058 B)
