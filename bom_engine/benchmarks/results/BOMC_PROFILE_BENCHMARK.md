# BOMC 1.2 Three-Profile Corpus Benchmark Report

- **Producer SHA:** `e51f50433a7e533b4b5058327cf314053da9dffe`
- **Generated At:** 2026-09-07T14:00:37Z
- **Total Fixtures:** 7
- **Certification Status:** **INCOMPLETE**
- **Profile Runs Passed:** 9/21
- **Missing Evidence:** source_textures: expected >= 1, got 0; source_scenes: expected >= 2, got 0; source_clip_planes: expected >= 1, got 0

## Aggregate Performance Summary

| Profile | Target / Budget | Min Ratio | Median Ratio | Mean Ratio | p95 Ratio | Worst Ratio | Max Pos Err (m) | Max Normal Err (deg) | Invariants Pass |
|---|---|---|---|---|---|---|---|---|---|
| **Visual** (Recommended) | ~60% target / 90% hard | 0.5% | 3.9% | 5.1% | 10.0% | 10.0% | 0.000435397729636876 | 0.0036283931540966805 | 7/7 |
| **Research** (Bounded) | 90% hard ceiling | 0.5% | 3.9% | 5.1% | 10.0% | 10.0% | 0.000435397729636876 | 0.0036283931540966805 | 7/7 |
| **Exact** (Reference) | No size guarantee | 0.5% | 9.0% | 10.3% | 22.4% | 22.4% | 0.0 | 1.7075472925031877e-06 | 7/7 |

## Corpus Fixture Breakdown

| Fixture | Category | SKP Size | Visual BOMC (Ratio) | Research BOMC (Ratio) | Exact BOMC (Ratio) | Textures | Scenes | Triangles |
|---|---|---|---|---|---|---|---|---|
| `tiny-box` | tiny | 160.1 KB | 880 B (0.5%; pass) | 896 B (0.5%; pass) | 862 B (0.5%; pass) | 0 | 1 | 2 |
| `small-textured-house2` | small-textured | 429.7 KB | 42.9 KB (10.0%; incomplete) | 42.9 KB (10.0%; incomplete) | 66.5 KB (15.5%; incomplete) | 0 | 1 | 5600 |
| `medium-architectural-presentation20` | medium-architectural | 2.06 MB | 114.7 KB (5.5%; pass) | 114.7 KB (5.5%; pass) | 209.4 KB (10.0%; pass) | 0 | 1 | 25518 |
| `complex-architectural-sboost1` | complex-architectural | 3.38 MB | 125.2 KB (3.6%; pass) | 125.2 KB (3.6%; pass) | 245.7 KB (7.1%; pass) | 0 | 1 | 13868 |
| `texture-heavy-rumah-y` | texture-heavy | 39.85 MB | 1.55 MB (3.9%; incomplete) | 1.55 MB (3.9%; incomplete) | 3.58 MB (9.0%; incomplete) | 0 | 1 | 237889 |
| `scene-heavy-sboost2` | scene-heavy | 3.21 MB | 125.2 KB (3.8%; incomplete) | 125.3 KB (3.8%; incomplete) | 245.8 KB (7.5%; incomplete) | 0 | 1 | 13842 |
| `section-cut-heavy-rumah-l` | section-cut-heavy | 31.51 MB | 2.75 MB (8.7%; incomplete) | 2.75 MB (8.7%; incomplete) | 7.05 MB (22.4%; incomplete) | 0 | 1 | 483287 |

## Evidence Notes

- A profile passes only when validator output is positive, scene/clip evidence matches, and its size budget applies.
- Missing required fixtures or source features keep certification incomplete; missing metrics remain null.
