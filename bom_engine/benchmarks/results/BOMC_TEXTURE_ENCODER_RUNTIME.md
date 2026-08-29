# BOMC Texture Encoder Runtime Evidence

## Runtime

- Status: **PASS**
- SketchUp: 26.2.243
- OS/runtime: Windows x64 (`x64-mswin64_140`)
- SketchUp Ruby: 3.2.2
- Encoder: libwebp `cwebp` 1.6.0 / libsharpyuv 0.4.2
- Bundled encoder SHA-256: `6a2f5cb5dce71366353ab1d9caf9c636e039f25703acfce1c148eed346f2f72a`
- Checksum verified before use: yes

## Real SketchUp results

| Case | Source bytes | WebP bytes | Dimensions | Alpha | Pixel metric |
|---|---:|---:|---|---|---|
| Opaque RGBA | 71 | 38 | 2x1 -> 2x1 | preserved | exact RGBA |
| Alpha RGBA | 71 | 40 | 2x1 -> 2x1 | preserved | exact RGBA |

Both outputs were encoded by the bundled `cwebp.exe` from the SketchUp 2026
Ruby process and decoded by the bundled `dwebp.exe`. Both RIFF/WebP headers,
dimensions, alpha values, and decoded pixels passed.

## Browser decode results

- Browser: Google Chrome 151.0.0.0 on Windows 10 x64
- Opaque lossless WebP: **PASS**, decoded at 2x1
- Alpha lossless WebP: **PASS**, decoded at 2x1
- Alpha visual check: checkerboard visible through translucent blue pixel
- Verification page: `../browser_verify/verify.html`
- Operator screenshot: `BOMC_TEXTURE_ENCODER_BROWSER_CHROME_151.png`

The operator opened the fixture page in Chrome. The page used `HTMLImageElement.decode()`
and verified both images' `naturalWidth` and `naturalHeight`. The supplied screenshot
shows both decode checks passing and visually confirms alpha transparency.

Machine-readable evidence:

- `BOMC_TEXTURE_ENCODER_SKETCHUP_RUNTIME.json`
- `BOMC_TEXTURE_ENCODER_BROWSER_RUNTIME.json`
