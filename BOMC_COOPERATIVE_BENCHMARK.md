# BOMC 1.1 Cooperative/Size Benchmark

Generated 2026-08-13 with pure Ruby detached fixtures. SketchUp was not launched or automated.

## Corpus: BOMC 1.0 fixed/full vs BOMC 1.1 compact/sparse

| Fixture | Old BOMC | New BOMC | Saved | Old sections | New sections | Empty removed | Header+directory old/new | Minimal metadata | Metadata removed | Texture bytes | Unaccounted |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TINY simple box | 1,176 | 735 | 441 | 18 | 13 | 5 | 752 / 344 | 719 | 16 | 0 | 0 |
| SMALL texture-heavy synthetic | 3,147,048 | 3,146,728 | 320 | 18 | 17 | 1 | 752 / 440 | 3,146,696 | 32 | 3,145,730 | 0 |
| MEDIUM architectural export | 112,016 | 111,576 | 440 | 18 | 13 | 5 | 752 / 344 | 111,576 | 0 | 0 | 0 |
| COMPLEX existing export | 1,598,216 | 1,597,776 | 440 | 18 | 13 | 5 | 752 / 344 | 1,597,776 | 0 | 0 | 0 |

The SMALL fixture embeds a deterministic 3 MiB already-efficient JPEG-like source. It is retained verbatim; structural savings come from the compact directory and absent empty streams, not quality loss.

## Responsiveness and preset determinism (10,000 shared/nested instances)

| Mode | Total ms | Maximum uninterrupted interval ms | Max stage | Yield count | Bytes | SHA256 |
|---|---:|---:|---|---:|---:|---|
| Synchronous baseline | 1985.599 | 1985.599 | whole_export | 0 | 300,304 | `7e58ebf24d5ec1b4e0971bb2c1c288fb9f3a1cf22eeb40ca9cc60be5c8c388dc` |
| Batch=1 | 2829.300 | 113.394 | encode_transforms | 300031 | 300,304 | `7e58ebf24d5ec1b4e0971bb2c1c288fb9f3a1cf22eeb40ca9cc60be5c8c388dc` |
| Light | 1576.483 | 118.497 | encode_transforms | 617 | 300,304 | `7e58ebf24d5ec1b4e0971bb2c1c288fb9f3a1cf22eeb40ca9cc60be5c8c388dc` |
| Balanced | 1662.382 | 111.935 | encode_transforms | 150 | 300,304 | `7e58ebf24d5ec1b4e0971bb2c1c288fb9f3a1cf22eeb40ca9cc60be5c8c388dc` |
| Fast | 1742.684 | 108.824 | encode_transforms | 44 | 300,304 | `7e58ebf24d5ec1b4e0971bb2c1c288fb9f3a1cf22eeb40ca9cc60be5c8c388dc` |
| Huge custom | 1862.793 | 160.687 | encode_transforms | 17 | 300,304 | `7e58ebf24d5ec1b4e0971bb2c1c288fb9f3a1cf22eeb40ca9cc60be5c8c388dc` |

All scheduled modes emitted byte-identical BOMC: **PASS** (`7e58ebf24d5ec1b4e0971bb2c1c288fb9f3a1cf22eeb40ca9cc60be5c8c388dc`). The processing mode changes only checkpoint/yield frequency.

Stress differential validation: unaccounted=0, topology exact=true, textures exact=true.

Maximum intervals include indivisible codec/DEFLATE calls and are therefore an honest upper bound for current cooperative work. Live SketchUp responsiveness remains pending user testing.
