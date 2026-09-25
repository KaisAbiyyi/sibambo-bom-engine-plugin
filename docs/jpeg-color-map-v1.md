# Experimental Exact JPEG color map v1

Not certified. Existing releases, loaders and installed packages are unchanged.
This representation is not JPEG or WebP and must never use their media IDs.

Canonical pixels are top-down, tightly packed RGBA8, opaque (alpha 255).
The base is an 8-bit one- or three-component baseline/progressive JPEG with
no APP1–APP15 metadata. The producer may strip these markers before the first
scan without re-encoding, but must decode the resulting JPEG before building
the dictionary. A consumer must match the canonical base digest exactly.
Different JPEG rounding is an unsupported decoder, not a tolerance allowance.

All integers below are unsigned little-endian. Header is exactly 128 bytes:

| Offset | Contents |
| --- | --- |
| 0 | Eight magic bytes `BOMJCM\r\n` |
| 8 | Version 1, flags 0, dictionary codec 0 (stored), layout 1 (RGBA8) |
| 12 | Width u32, height u32, entry count u32, JPEG length u32 |
| 28 | Reserved u32, zero |
| 32 | SHA-256 of the embedded JPEG bytes, 32 raw bytes |
| 64 | SHA-256 of decoded canonical base RGBA, 32 raw bytes |
| 96 | SHA-256 of reconstructed target RGBA, 32 raw bytes |
| 128 | JPEG bytes followed by exactly entry_count * 7 dictionary bytes |

Each entry is RGB input (3 bytes) followed by RGBA output (4 bytes), sorted
strictly by RGB integer key. Duplicate keys, alpha other than 255, missing
pixel keys, mismatched hashes, malformed JPEG structure, trailing bytes and
unknown headers fail closed. A map conflicting for the same input RGB is not
encodable; use existing verified lossless formats instead. No nearest colors.

Limits: each side at most 16,384; at most 32,000,000 pixels; JPEG at most
32 MiB; at most 262,144 entries and no more entries than pixels. There is no
nested dictionary decompression. JPEG dimensions are inspected before native
image decode, including marker validation after entropy scans. Hashes detect
corruption and decoder disagreement; they are not signatures or proof of origin.

Container texture table version 2 introduces media ID 6 for this representation.
Both reference and browser readers reject table v2 unless explicitly opted in;
table v1 rejects media ID 6. Browser identity `bomc-next-jcm-v1` is registered but
no existing catalog release is changed. PNG assets are generated only after all
canonical pixel checks pass. The browser additionally limits the aggregate of
mapped textures to 64 million pixels per model.

Adaptive staging is experimental/opt-in, Windows-only (verified BGR/BGRA host
layout), and Exact-only. It competes complete payload bytes against the already
verified PNG/native JPEG/WebP choice. Thirty-second mapping budget, conflicting
maps, excessive entries, unsupported metadata, alpha and decode failures retain
the earlier verified candidate. Normal export menus never opt in.

The isolated texture-only capture builder does not install an extension or
export geometry. A lean entry captures original host buffers and native JPEGs;
offline encoding and browser verification bind canonical pixels to those files.
Four large captured textures now pass this host-to-browser equality gate.

Experimental export plumbing is explicit via `allow_jpeg_color_map: true`,
Exact only and disabled in existing menus. Runtime source must be saved and
unmodified, with a known positive source size. The experimental file must be
strictly smaller than that source before publication; no quality relaxation.
Material staging shares a 64M mapped-pixel budget, charging unique payloads
once. Writer and consumer enforce the same aggregate bound independently.
Already-verified native JPEG does not spend mapped-pixel budget for marginal
size savings. Consumer payload-byte metrics exclude reconstructed PNG assets;
asset bytes are reported separately.

Full-model runtime export using this latest plumbing, broader browser/runtime
matrix, responsiveness and whole-model size certification remain pending.
