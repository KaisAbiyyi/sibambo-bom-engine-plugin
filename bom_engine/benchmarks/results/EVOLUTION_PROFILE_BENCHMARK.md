# BOMC 1.2 Three-Profile Corpus Benchmark Report

- **Producer SHA:** `49ca51de52f1bd7561aaf24f1ff31fa622d96cce`
- **Generated At:** 2026-09-08T16:12:45Z
- **Total Fixtures:** 7
- **Certification Status:** **READY**
- **Profile Runs Passed:** 21/21

## Aggregate Performance Summary

| Profile | Target / Budget | Min Ratio | Median Ratio | Mean Ratio | p95 Ratio | Worst Ratio | Max Pos Err (m) | Max Normal Err (deg) | Invariants Pass |
|---|---|---|---|---|---|---|---|---|---|
| **Visual** (Recommended) | ~60% target / 90% hard | 0.0% | 0.3% | 2.2% | 8.6% | 8.6% | 3.811958013619961e-05 | 2.4148365394514667e-06 | 7/7 |
| **Research** (Bounded) | 90% hard ceiling | 0.0% | 0.3% | 2.2% | 8.6% | 8.6% | 3.811958013619961e-05 | 2.4148365394514667e-06 | 7/7 |
| **Exact** (Reference) | No size guarantee | 0.0% | 0.3% | 2.6% | 10.0% | 10.0% | 0.0 | 1.4787793334710982e-06 | 7/7 |

## Corpus Fixture Breakdown

| Fixture | Category | SKP Size | Visual BOMC (Ratio) | Research BOMC (Ratio) | Exact BOMC (Ratio) | Textures | Scenes | Triangles |
|---|---|---|---|---|---|---|---|---|
| `tiny-box` | tiny | 160.1 KB | 920 B (0.6%; pass) | 936 B (0.6%; pass) | 862 B (0.5%; pass) | 0 | 1 | 2 |
| `small-textured-house2` | small-textured | 429.7 KB | 1.3 KB (0.3%; pass) | 1.3 KB (0.3%; pass) | 1.2 KB (0.3%; pass) | 1 | 1 | 4 |
| `medium-architectural-presentation20` | medium-architectural | 2.06 MB | 180.6 KB (8.6%; pass) | 180.6 KB (8.6%; pass) | 209.4 KB (10.0%; pass) | 0 | 1 | 25518 |
| `complex-architectural-sboost1` | complex-architectural | 3.38 MB | 197.1 KB (5.7%; pass) | 197.1 KB (5.7%; pass) | 245.7 KB (7.1%; pass) | 0 | 1 | 13868 |
| `texture-heavy-rumah-y` | texture-heavy | 39.85 MB | 1.9 KB (0.0%; pass) | 1.9 KB (0.0%; pass) | 1.8 KB (0.0%; pass) | 4 | 1 | 10 |
| `scene-heavy-sboost2` | scene-heavy | 3.21 MB | 1.3 KB (0.0%; pass) | 1.3 KB (0.0%; pass) | 1.2 KB (0.0%; pass) | 0 | 2 | 6 |
| `section-cut-heavy-rumah-l` | section-cut-heavy | 31.51 MB | 1.2 KB (0.0%; pass) | 1.2 KB (0.0%; pass) | 1.1 KB (0.0%; pass) | 0 | 1 | 4 |

## Evidence Notes

- A profile passes only when validator output is positive, scene/clip evidence matches, and its size budget applies.
- Missing required fixtures or source features keep certification incomplete; missing metrics remain null.
