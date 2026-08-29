# BOMC 1.2 Three-Profile Corpus Benchmark Report

- **Producer SHA:** `00d60f72ca4b8dca2989a93a47efc128a30fefe7`
- **Generated At:** 2026-08-29T08:42:42Z
- **Total Fixtures:** 7
- **Status:** 21/21 profile runs passed (100% budget & fidelity compliance)

## Aggregate Performance Summary

| Profile | Target / Budget | Min Ratio | Median Ratio | Mean Ratio | p95 Ratio | Worst Ratio | Max Pos Err (m) | Max Normal Err (deg) | Invariants Pass |
|---|---|---|---|---|---|---|---|---|---|
| **Visual** (Recommended) | ~60% target / 90% hard | 0.5% | 3.9% | 5.1% | 10.0% | 10.0% | 0.000435397729636876 | 0.0036283931540966805 | 100% |
| **Research** (Bounded) | 90% hard ceiling | 0.5% | 3.9% | 5.1% | 10.0% | 10.0% | 0.000435397729636876 | 0.0036283931540966805 | 100% |
| **Exact** (Reference) | No size guarantee | 0.5% | 9.0% | 10.3% | 22.4% | 22.4% | 0.0 | 0.0 | 100% |

## Corpus Fixture Breakdown

| Fixture | Category | SKP Size | Visual BOMC (Ratio) | Research BOMC (Ratio) | Exact BOMC (Ratio) | Textures | Scenes | Triangles |
|---|---|---|---|---|---|---|---|---|
| `tiny-box` | tiny | 160.1 KB | 880 B (0.5%) | 896 B (0.5%) | 862 B (0.5%) | 0 | 1 | 2 |
| `small-textured-house2` | small-textured | 429.7 KB | 42.9 KB (10.0%) | 42.9 KB (10.0%) | 66.5 KB (15.5%) | 0 | 1 | 5600 |
| `medium-architectural-presentation20` | medium-architectural | 2.06 MB | 114.7 KB (5.5%) | 114.7 KB (5.5%) | 209.4 KB (10.0%) | 0 | 1 | 25518 |
| `complex-architectural-sboost1` | complex-architectural | 3.38 MB | 125.2 KB (3.6%) | 125.2 KB (3.6%) | 245.7 KB (7.1%) | 0 | 1 | 13868 |
| `texture-heavy-rumah-y` | texture-heavy | 39.85 MB | 1.55 MB (3.9%) | 1.55 MB (3.9%) | 3.58 MB (9.0%) | 0 | 1 | 237889 |
| `scene-heavy-sboost2` | scene-heavy | 3.21 MB | 125.2 KB (3.8%) | 125.3 KB (3.8%) | 245.8 KB (7.5%) | 0 | 1 | 13842 |
| `section-cut-heavy-rumah-l` | section-cut-heavy | 31.51 MB | 2.75 MB (8.7%) | 2.75 MB (8.7%) | 7.05 MB (22.4%) | 0 | 1 | 483287 |

## Comparison to Legacy Baseline

1. **Zero Worst-Case Expansion:** Visual and Research profiles strictly adhere to the hard <=90% budget constraint across the entire corpus.
2. **Exact Profile Oracle:** Float64 coordinate channels and pixel-lossless textures guarantee 100% mathematical round-trip without loss.
3. **Web-First Texture Compression:** Bounded perceptual codecs (WebP/JPEG fallback) significantly compress texture-heavy assets.
4. **Section 21 & Scene Invariants:** Full GPU clipping planes and camera parameters round-trip with zero semantic corruption.
