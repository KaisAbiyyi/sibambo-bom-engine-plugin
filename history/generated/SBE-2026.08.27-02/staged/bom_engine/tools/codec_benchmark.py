#!/usr/bin/env python3
"""Benchmark BOMC section payloads with practical entropy codecs."""

import io
import json
import math
import struct
import sys
import time
import zlib
from pathlib import Path


HEADER = struct.Struct("<8sHHIIIQ")
DIRECTORY = struct.Struct("<HBBQQQIII")


def elapsed(callable_, repeats=1):
    started = time.perf_counter()
    value = None
    for _ in range(repeats):
        value = callable_()
    return value, (time.perf_counter() - started) * 1000.0 / repeats


def load_sections(path):
    content = Path(path).read_bytes()
    magic, major, minor, endian, flags, count, directory_offset = HEADER.unpack_from(content, 0)
    if magic != b"BOMC\r\n\x1a\n" or (major, minor) != (1, 0):
        raise ValueError("not a BOMC 1.0 file")
    sections = []
    for index in range(count):
        entry = DIRECTORY.unpack_from(content, directory_offset + index * DIRECTORY.size)
        section_type, codec, section_flags, offset, stored_size, raw_size, item_count, crc32, reserved = entry
        stored = content[offset : offset + stored_size]
        if zlib.crc32(stored) != crc32:
            raise ValueError(f"section {index} checksum mismatch")
        if codec == 0:
            raw = stored
        elif codec == 1:
            raw = zlib.decompress(stored)
        else:
            raise ValueError(f"unsupported source codec {codec}")
        if len(raw) != raw_size:
            raise ValueError(f"section {index} raw length mismatch")
        sections.append({"type": section_type, "count": item_count, "raw": raw})
    return sections


def codec_functions():
    codecs = {
        "deflate": (
            lambda raw: zlib.compress(raw, 9),
            zlib.decompress,
            zlib.ZLIB_VERSION,
        )
    }
    unavailable = {}
    try:
        import brotli

        codecs["brotli"] = (
            lambda raw: brotli.compress(raw, quality=11),
            brotli.decompress,
            getattr(brotli, "__version__", "installed"),
        )
    except Exception as error:  # pragma: no cover - environment report
        unavailable["brotli"] = f"{type(error).__name__}: {error}"
    try:
        import zstandard

        compressor = zstandard.ZstdCompressor(level=19)
        decompressor = zstandard.ZstdDecompressor()
        codecs["zstandard"] = (
            compressor.compress,
            decompressor.decompress,
            getattr(zstandard, "__version__", "installed"),
        )
    except Exception as error:  # pragma: no cover - environment report
        unavailable["zstandard"] = f"{type(error).__name__}: {error}"
    return codecs, unavailable


def benchmark_sections(sections):
    codecs, unavailable = codec_functions()
    results = {"unavailable": unavailable, "versions": {}, "totals": {}, "sections": []}
    totals = {name: {"bytes": 0, "compress_ms": 0.0, "decompress_ms": 0.0} for name in codecs}
    for name, (_, _, version) in codecs.items():
        results["versions"][name] = version
    for section in sections:
        row = {"type": section["type"], "count": section["count"], "raw_bytes": len(section["raw"]), "codecs": {}}
        for name, (compress, decompress, _) in codecs.items():
            encoded, compress_ms = elapsed(lambda: compress(section["raw"]))
            decoded, decompress_ms = elapsed(lambda: decompress(encoded), repeats=5)
            if decoded != section["raw"]:
                raise ValueError(f"{name} round-trip failed for section {section['type']}")
            row["codecs"][name] = {
                "bytes": len(encoded),
                "compress_ms": compress_ms,
                "decompress_ms": decompress_ms,
            }
            totals[name]["bytes"] += len(encoded)
            totals[name]["compress_ms"] += compress_ms
            totals[name]["decompress_ms"] += decompress_ms
        results["sections"].append(row)
    results["totals"] = totals
    return results


def image_mse(left, right):
    left_rgb = left.convert("RGB")
    right_rgb = right.convert("RGB")
    left_pixels = list(left_rgb.get_flattened_data())
    right_pixels = list(right_rgb.get_flattened_data())
    squared = 0.0
    components = len(left_pixels) * 3
    for left_pixel, right_pixel in zip(left_pixels, right_pixels):
        for a, b in zip(left_pixel, right_pixel):
            squared += (a - b) ** 2
    return squared / components if components else 0.0


def benchmark_texture(path):
    if not path or not Path(path).is_file():
        return {"status": "not_available", "selected": "source"}
    try:
        from PIL import Image
    except Exception as error:  # pragma: no cover - environment report
        return {"status": f"Pillow unavailable: {error}", "selected": "source"}
    source_bytes = Path(path).read_bytes()
    image = Image.open(path).convert("RGB")
    output = io.BytesIO()
    started = time.perf_counter()
    image.save(output, format="WEBP", quality=95, method=6)
    encode_ms = (time.perf_counter() - started) * 1000.0
    encoded = output.getvalue()
    started = time.perf_counter()
    decoded = Image.open(io.BytesIO(encoded)).convert("RGB")
    decoded.load()
    decode_ms = (time.perf_counter() - started) * 1000.0
    mse = image_mse(image, decoded)
    psnr = float("inf") if mse == 0.0 else 10.0 * math.log10((255.0 * 255.0) / mse)
    return {
        "status": "benchmarked",
        "source_format": Image.open(path).format,
        "source_bytes": len(source_bytes),
        "webp_bytes": len(encoded),
        "webp_quality": 95,
        "psnr_db": psnr,
        "encode_ms": encode_ms,
        "decode_ms": decode_ms,
        "selected": "source",
        "selection_reason": "transcoding remains opt-in; source bytes are the conservative production default",
    }


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: codec_benchmark.py INPUT.bomc OUTPUT.json [TEXTURE.png]")
    sections = load_sections(sys.argv[1])
    result = benchmark_sections(sections)
    result["texture"] = benchmark_texture(sys.argv[3] if len(sys.argv) > 3 else None)
    Path(sys.argv[2]).write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")


if __name__ == "__main__":
    main()
