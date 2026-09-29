# Exact JPEG color map v1

Not certified. The current E4 Exact producer may select this lossless representation when it is smaller; Visual and Research never use it.
This representation is not JPEG or WebP and must never use their media IDs.

Canonical pixels are top-down, tightly packed RGBA8, opaque (alpha 255). JCM v1 now supports three exact correction codecs: stored dictionary (0), zlib-deflated dictionary (1), and zlib-deflated per-pixel RGBA XOR residual (2). The producer measures all applicable forms and keeps the smallest complete payload.
The base is an 8-bit one- or three-component baseline/progressive JPEG with
no APP1–APP15 metadata. The producer may strip these markers before the first
scan without re-encoding, but must decode the resulting JPEG before building
the dictionary. A consumer must match the canonical base digest exactly.
Different JPEG rounding is an unsupported decoder, not a tolerance allowance.

All integers below are unsigned little-endian. Header is exactly 128 bytes:

| Offset | Contents |
| --- | --- |
| 0 | Eight magic bytes `BOMJCM\r\n` |
| 8 | Version 1, flags 0, correction codec (0 stored dictionary, 1 deflated dictionary, 2 deflated XOR residual), layout 1 (RGBA8) |
| 12 | Width u32, height u32, entry count u32, JPEG length u32 |
| 28 | Correction payload byte length for codecs 1/2; zero for codec 0 |
| 32 | SHA-256 of the embedded JPEG bytes, 32 raw bytes |
| 64 | SHA-256 of decoded canonical base RGBA, 32 raw bytes |
| 96 | SHA-256 of reconstructed target RGBA, 32 raw bytes |
| 128 | JPEG bytes followed by exactly entry_count * 7 dictionary bytes |

Dictionary codecs use entries of RGB input (3 bytes) followed by RGBA output
(4 bytes), sorted strictly by RGB integer key. Codec 1 zlib-compresses that
exact table per texture. When one JPEG RGB would require multiple target colors
or the dictionary is otherwise inefficient, codec 2 stores a zlib-compressed
RGBA XOR residual for every pixel. Reconstruction remains exact and is verified
against the target pixel SHA-256. Duplicate keys, alpha other than 255, missing
pixel keys, malformed correction streams, mismatched hashes, malformed JPEG
structure, trailing bytes and unknown headers fail closed. No nearest colors.

Limits: each side at most 16,384; at most 32,000,000 pixels; JPEG at most
32 MiB; at most 262,144 entries and no more entries than pixels. There is no
nested dictionary decompression. JPEG dimensions are inspected before native
image decode, including marker validation after entropy scans. Hashes detect
corruption and decoder disagreement; they are not signatures or proof of origin.

Container texture table version 2 introduces media ID 6 for this representation.
Current Ruby and browser E4 readers accept table v2/media 6 by default; callers
may explicitly disable JCM compatibility when testing a legacy consumer. PNG
assets are generated only after all canonical pixel checks pass. The producer
and browser retain the 64 million aggregate mapped-pixel bound per model.

Adaptive JCM staging is Windows-only (verified BGR/BGRA host layout) and
Exact-only. Standard Exact enables it automatically and competes complete payload
bytes against the already verified PNG/native JPEG/WebP choice. The correction
budget scales from 30 to 90 seconds with texture size, while the common BGRA32
conversion path uses row-wise native unpack/pack. Unsupported metadata, alpha,
decode failures, or an oversized JCM payload retain the earlier verified
lossless candidate.

The isolated texture-only capture builder does not install an extension or
export geometry. A lean entry captures original host buffers and native JPEGs;
offline encoding and browser verification bind canonical pixels to those files.
Four large captured textures now pass this host-to-browser equality gate.

Standard Exact resolves `allow_jpeg_color_map: nil` to enabled; explicit
`false` remains available for legacy-consumer compatibility tests. JCM no
longer imposes a source-size publication gate: fidelity remains mandatory while
source-vs-output size stays benchmark evidence. Material staging shares a 64M
mapped-pixel budget, charging unique payloads once. Writer and consumer enforce
the same aggregate bound independently.
Already-verified native JPEG does not spend mapped-pixel budget for marginal
size savings. Consumer payload-byte metrics exclude reconstructed PNG assets;
asset bytes are reported separately.

Full-model runtime export using this latest plumbing, broader browser/runtime
matrix, responsiveness and whole-model size certification remain pending.
