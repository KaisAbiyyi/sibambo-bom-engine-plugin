# Bundled libwebp tools

- Version: libwebp 1.6.0
- Runtime: Windows x64 (SketchUp 2026)
- Upstream archive: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-windows-x64.zip
- Upstream archive SHA-256: `48886f506b21f62e4661f0f4cbfca19800897c385128e8902542d29a950c93f1`
- Source archive SHA-256: `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`
- `cwebp.exe` SHA-256: `6a2f5cb5dce71366353ab1d9caf9c636e039f25703acfce1c148eed346f2f72a`
- `dwebp.exe` SHA-256: `17c1488bf84b7834e9aa908bb40afd0be2e55d57567d210e96336c56bb6ae993`

`BOMCTextureEncoder` verifies bundled `cwebp.exe` before use. A missing or
modified binary produces an explicit capability failure. Runtime downloads are
not used. Process launch uses an argument array, a timeout, cancellation, exit
status checks, and atomic output publication.

`dwebp.exe` is bundled for release/runtime compatibility verification. Export
uses `cwebp.exe` only.

License terms and patent grant are in `LICENSE.libwebp.txt` and
`PATENTS.libwebp.txt`.
