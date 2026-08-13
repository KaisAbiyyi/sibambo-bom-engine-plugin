# BOMC Hypercompression Benchmark Report

Generated: 2026-08-13 (Asia/Jakarta). Automated corpus only; no SketchUp process was launched.

## Corpus size comparison

| Fixture | Previous JSON | Previous DEFLATE | BOMC raw sections | BOMC production | Reduction vs JSON | Source SKP | BOMC vs SKP |
|---|---:|---:|---:|---:|---:|---:|---:|
| Tiny | 1,377 | 713 | 1,456 | 1,176 | 14.60% | n/a | n/a |
| Medium | 696,657 | 27,493 | 123,744 | 9,664 | 98.61% | n/a | n/a |
| Complex existing export | 19,092,163 | 4,288,406 | 4,329,216 | 1,598,216 | 91.63% | 41,785,434 | 3.82% |

No `.cleanpkg` fixture exists in this repository, so CleanPackage columns cannot be measured without inventing data. The previous-format comparison uses the available Model-Eval JSON plus its direct DEFLATE result.

## Complex fixture section attribution

| Section | Raw bytes | Stored bytes | Container codec | Count |
|---|---:|---:|---:|---:|
| model | 96 | 95 | 1 | 1 |
| strings | 9,339 | 3,927 | 1 | 596 |
| materials | 2,383 | 673 | 1 | 125 |
| tags | 130 | 96 | 1 | 57 |
| meshes | 43,064 | 9,572 | 1 | 936 |
| faces | 1,340,960 | 41,033 | 1 | 121,833 |
| positions | 819,948 | 452,407 | 1 | 936 |
| topology | 1,500,036 | 715,564 | 1 | 936 |
| normals | 487,344 | 349,019 | 1 | 121,833 |
| uv | 0 | 0 | 0 | 0 |
| definitions | 5,723 | 2,034 | 1 | 1,143 |
| instances | 47,712 | 8,480 | 1 | 3,180 |
| transforms | 71,645 | 14,477 | 1 | 2,145 |
| visual_edges | 12 | 12 | 0 | 0 |
| texture_table | 8 | 8 | 0 | 0 |
| textures | 0 | 0 | 0 | 0 |
| coverage | 24 | 16 | 1 | 1 |
| fallback | 8 | 8 | 0 | 0 |

Header + directory: **752 bytes**. BOMC SHA256: `1a64b643b904ae84193aa95b7246fed9945b3b508f8a495f0e9c6c35e0b5e5ba`.

## Logical counts and differential validation

| Fixture | Meshes | Faces | Definitions | Instances | Fallback | Materials | Textures | Unaccounted |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Tiny | 1 | 1 | 2 | 2 | 0 | 1 | 0 | 0 |
| Medium | 12 | 12 | 13 | 2,001 | 0 | 2 | 0 | 0 |
| Complex existing export | 936 | 121,833 | 1,143 | 3,180 | 0 | 125 | 0 | 0 |

| Fixture | Position max / p95 / RMS (m) | Normal max (deg) | UV max | Transform max | Tables | Topology | Edges | Fallback | Textures |
|---|---|---:|---:|---:|---|---|---|---|---|
| Tiny | 3.31604e-13 / 3.31604e-13 / 2.34479e-13 | 0 | 0 | 0 | exact | exact | exact | exact | exact |
| Medium | 0 / 0 / 0 | 0 | 0 | 3.8147e-07 | exact | exact | exact | exact | exact |
| Complex existing export | 0.000362081 / 9.89978e-06 / 1.13864e-05 | 0.00362839 | 0 | 9.90922e-06 | exact | exact | exact | exact | exact |

## Production and debug profiles

| Profile | Container bytes | Debug section raw | Debug section stored | Runtime stable-ID/provenance mappings |
|---|---:|---:|---:|---|
| Production | 1,598,216 | 0 | 0 | omitted |
| Debug | 3,765,597 | 3,919,967 | 1,318,045 | included |

Production saves 2,167,381 bytes on the complex fixture by omitting stable-ID and provenance mappings. Runtime/user-facing names and semantic labels remain dictionary encoded in both profiles.

## Complex codec decisions

| Position candidate | Raw bytes | Candidate DEFLATE bytes | Max error (m) | Passing blocks |
|---|---:|---:|---:|---:|
| float64_absolute | 2,839,440 | 1,168,405 | 0 | 936/936 |
| float32_local | 1,419,720 | 704,006 | 2.34683e-06 | 936/936 |
| int32_quantized | 1,419,720 | 734,717 | 5.52476e-09 | 936/936 |
| int16_quantized | 709,860 | 512,229 | 0.000362081 | 933/936 |
| delta_varint | 999,810 | 790,261 | 0.000362081 | 936/936 |

Selected per-block codec counts: enum 2=5, enum 3=3, enum 4=928.

Normals selected codec enum `2`; max/p95/RMS angular error 0.00362839 / 0.0021832 / 0.00119019 degrees.

Transforms selected codec enum `5`; max/p95/RMS matrix error 9.90922e-06 / 4.11858e-07 / 1.23565e-06.
The 3,180 instance rows reference 2,145 transform rows; numeric references preserve 1,035 existing transform reuses without expanding matrices per occurrence.

Topology absolute uint32 baseline: 4,776,120 bytes; delta-zigzag-varint blocks: 1,499,362 bytes; saved 3,276,758 bytes before section compression.

Adaptive reference columns: 2,052,992 byte uint32 baseline; 654,512 bytes selected; saved 1,398,480 bytes.

The existing complex Model-Eval JSON contains no UV or embedded texture payloads; UV candidate results therefore come from the medium architectural fixture, while complex UV error is zero for an empty stream.

| UV candidate | Raw bytes | Candidate DEFLATE bytes | Max error | Passing blocks |
|---|---:|---:|---:|---:|
| float32 | 768 | 408 | 0 | 12/12 |
| float16 | 384 | 336 | 0 | 12/12 |
| int16_quantized | 384 | 372 | 1.07899e-05 | 12/12 |
| delta_varint | 468 | 480 | 1.07899e-05 | 12/12 |
| float64 | 1,536 | 456 | 0 | 12/12 |

## Section entropy-codec search

| Codec | Total bytes | Compress ms | Decompress ms | Version |
|---|---:|---:|---:|---|
| brotli | 1,339,721 | 9821.643 | 25.844 | 1.2.0 |
| deflate | 1,597,446 | 329.225 | 14.927 | 1.3.2 |
| zstandard | 1,434,100 | 720.178 | 6.760 | 0.25.0 |

Production selection remains per-section DEFLATE or STORE: it is available in the supported Ruby standard library and needs no mandatory WASM/runtime dependency. Brotli and Zstandard measurements are retained as evidence for a future format version.

## Texture transcoding experiment

| Representation | Bytes | Quality / error | Encode ms | Decode ms | Selected |
|---|---:|---|---:|---:|---|
| Source PNG | 10,362 | lossless source | 0 | n/a | yes |
| WebP | 320 | quality 95, PSNR 45.984 dB | 82.301 | 0.384 | no (optional only) |
| AVIF | unavailable in installed Pillow encoder | n/a | n/a | n/a | no |
| KTX2/Basis | unavailable in repository toolchain | n/a | n/a | n/a | no |

Source texture bytes remain the default production representation. Optional WebP is not emitted by this RC.

## Decode performance and allocation counters

| Fixture | Encode ms | Header parse ms | Directory-only ms | Verify/inflate ms | Decoder container ms | Metadata ms | Analytical ms | Visual ms | Texture ms | Validation ms | Total reference decode ms | Encode allocated objects | Decode allocated objects | Final typed-array bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Tiny | 3.841 | 0.005 | 0.043 | 0.070 | 0.064 | 0.092 | 0.053 | 0.044 | 0.005 | 0.015 | 0.293 | 3,422 | 1,267 | 196 |
| Medium | 198.973 | 0.002 | 0.040 | 0.208 | 0.225 | 5.052 | 0.085 | 0.562 | 0.006 | 2.252 | 8.208 | 620,901 | 43,837 | 99,744 |
| Complex existing export | 11129.455 | 0.006 | 0.052 | 15.755 | 26.355 | 300.170 | 681.851 | 1584.879 | 0.025 | 479.276 | 3072.596 | 36,442,762 | 11,243,901 | 7,760,796 |

Allocation counts are Ruby VM `GC.stat[:total_allocated_objects]` deltas. Final typed-array bytes estimate browser Float32 positions/normals/UV/transforms plus Uint32 topology/edges; peak temporary bytes are not exposed reliably by Ruby 2.5/3.2.

## Shared definition scaling

| Instances | Total BOMC bytes | Geometry section bytes | Instance section bytes | Transform section bytes |
|---:|---:|---:|---:|---:|
| 1 | 1,288 | 159 | 32 | 14 |
| 10 | 1,352 | 159 | 48 | 60 |
| 100 | 1,680 | 159 | 145 | 283 |
| 1,000 | 4,768 | 159 | 1,604 | 1,916 |
| 10,000 | 37,088 | 159 | 18,175 | 17,672 |

Geometry section bytes remain constant across all five scales; only instance and transform streams grow.

## Known-model context

The complex JSON is paired by filename with `RUMAH Y.skp` (41,785,434 bytes). Its BOMC is 1,598,216 bytes (3.82% of SKP). This is a file-size comparison only, not a claim of real SketchUp compiled-format acceptance.

The requested known `RUMAH L.skp` is 33,035,617 bytes, but no matching existing CleanPackage/Model-Eval JSON fixture is available, so an honest RUMAH L compiled byte count remains pending the user export.

REAL SKETCHUP COMPILED-FORMAT ACCEPTANCE: PENDING USER TEST
