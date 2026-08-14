# BOMC 1.1 Compiled Building Format

Status: release candidate contract for Model-Eval implementers.

BOMC is a deterministic, little-endian, single-file compiled representation of a BOM Engine canonical building graph. Its production profile contains no JSON manifest, no Ruby serialization, no base64, and no external asset folder. Geometry stays definition-local and each instance references one shared definition.

## 1. Primitive conventions

- All multi-byte numbers are little-endian.
- Integers are unsigned unless the primitive name begins with `int`.
- `float32` and `float64` are IEEE-754 binary32 and binary64.
- `varuint` is unsigned LEB128, seven payload bits per byte.
- `zigzag-varint` maps signed `n` to `2*n` for nonnegative values and `2*abs(n)-1` for negative values, then writes `varuint`.
- File offsets and lengths are bytes from the beginning of the BOMC file.
- Section payload offsets are aligned to eight bytes. Padding is zero and is not part of a section's stored or raw length.
- Internal geometry-block offsets are relative to the beginning of their containing raw section and are aligned to eight bytes.
- Text is UTF-8 without terminators.

## 2. Fixed header (32 bytes)

| Offset | Bytes | Type | Meaning |
|---:|---:|---|---|
| 0 | 8 | bytes | Magic `42 4f 4d 43 0d 0a 1a 0a` (`BOMC\r\n\x1a\n`) |
| 8 | 2 | uint16 | Container major version, `1` |
| 10 | 2 | uint16 | Container minor version, `1` (`0` remains readable) |
| 12 | 4 | uint32 | Endianness marker, `0x01020304` |
| 16 | 4 | uint32 | Profile flags |
| 20 | 4 | uint32 | Section count |
| 24 | 8 | uint64 | Section-directory offset, `32` in BOMC 1.0 |

Profile flags:

| Bit | Value | Meaning |
|---:|---:|---|
| 0 | `0x00000001` | Production profile |
| 1 | `0x00000002` | Debug profile |
| 4 | `0x00000010` | Compact 24-byte section directory |

Exactly one of production/debug is emitted by this implementation.

## 3. Section directory

BOMC 1.1 production uses compact 24-byte entries. Offsets and sizes are uint32, which supports containers up to 4 GiB; the encoder refuses compact output outside that range. BOMC 1.0's fixed 40-byte entries remain decoder-compatible for existing files.

### BOMC 1.1 compact entry (24 bytes)

| Entry offset | Bytes | Type | Meaning |
|---:|---:|---|---|
| 0 | 2 | uint16 | Section type |
| 2 | 1 | uint8 | Compression codec |
| 3 | 1 | uint8 | Section flags |
| 4 | 4 | uint32 | Stored payload offset |
| 8 | 4 | uint32 | Stored byte length |
| 12 | 4 | uint32 | Raw byte length after decompression |
| 16 | 4 | uint32 | Logical record/block count |
| 20 | 4 | uint32 | CRC32 of stored bytes |

### BOMC 1.0 legacy entry (40 bytes)

Entries are sorted by numeric section type. A reader must use recorded offsets and must not assume payloads are contiguous.

| Entry offset | Bytes | Type | Meaning |
|---:|---:|---|---|
| 0 | 2 | uint16 | Section type |
| 2 | 1 | uint8 | Compression codec |
| 3 | 1 | uint8 | Section flags; zero in BOMC 1.0 |
| 4 | 8 | uint64 | Stored payload offset |
| 12 | 8 | uint64 | Stored byte length |
| 20 | 8 | uint64 | Raw byte length after decompression |
| 28 | 4 | uint32 | Logical record/block count |
| 32 | 4 | uint32 | CRC32 of stored bytes |
| 36 | 4 | uint32 | Reserved; must be zero |

Compression codecs:

| Value | Name | BOMC 1.1 status |
|---:|---|---|
| 0 | STORE | Implemented |
| 1 | DEFLATE (zlib wrapper) | Implemented |
| 2 | Brotli | Reserved |
| 3 | Zstandard | Reserved |

A production reader must reject an unsupported codec on a section it needs. It must skip an unknown section type by using `offset + storedLength`; an unknown type is not a file-version error.

## 4. Section type registry

| Type | Name | Logical layer |
|---:|---|---|
| 1 | MODEL | Core metadata and counts |
| 2 | STRINGS | Shared UTF-8 dictionary |
| 3 | MATERIALS | Columnar material table |
| 4 | TAGS | Columnar tag/layer table |
| 5 | MESHES | Per-definition geometry-block directory |
| 6 | FACES | Analytical surface metadata and loop counts |
| 7 | POSITIONS | Independently encoded definition-local position blocks |
| 8 | TOPOLOGY | Loop and triangle index blocks |
| 9 | NORMALS | Face normal stream |
| 10 | UVS | Per-corner front/back UV blocks |
| 11 | DEFINITIONS | Shared definition table |
| 12 | INSTANCES | Instance hierarchy and transform references |
| 13 | TRANSFORMS | Affine transform stream |
| 14 | VISUAL_EDGES | Retained visual edge stream |
| 15 | TEXTURE_TABLE | Texture metadata, hashes, and blob ranges |
| 16 | TEXTURE_BLOBS | Concatenated source texture bytes |
| 17 | COVERAGE | Completeness/disposition counters |
| 18 | FALLBACK | Image/text placement and resource records |
| 240 | DEBUG | Optional stable-ID/provenance mappings |

MODEL, STRINGS, DEFINITIONS, INSTANCES, TRANSFORMS, and COVERAGE are always present. Zero-count optional tables/streams are absent in BOMC 1.1. A reader treats absent optional sections as empty only when MODEL declares a corresponding zero count; otherwise absence is invalid. TEXTURE_TABLE and TEXTURE_BLOBS must appear together.

FACES and COVERAGE form the analytical core when faces exist. POSITIONS, TOPOLOGY, NORMALS, UVS, VISUAL_EDGES, and FALLBACK are independently addressable visual/geometry streams. TEXTURE_TABLE and TEXTURE_BLOBS are independently addressable resources.

## 5. Adaptive references and sentinels

A table header records the byte width of each reference column.

| Referenced row count | Width | Missing sentinel | Largest valid index |
|---:|---:|---:|---:|
| 0..255 | 1 | `255` | `254` |
| 256..65,535 | 2 | `65,535` | `65,534` |
| 65,536+ | 4 | `4,294,967,295` | `4,294,967,294` |

The row count includes the number of potentially valid zero-based indices. A value equal to the width's sentinel means no material, tag, texture, owner, mesh, label, or other optional reference. Required references must not contain a sentinel.

## 6. Shared string dictionary (section 2)

Production stores only runtime/user-facing text such as model/material/tag/definition/instance names and semantic labels. Stable IDs, persistent IDs, classification sources, and provenance are not interned in production. Debug interns those strings once and references them from section 240.

Header:

| Bytes | Type | Meaning |
|---:|---|---|
| 1 | uint8 | Table version `1` |
| 3 | bytes | Reserved zero |
| 4 | uint32 | String count `N` |
| 4 | uint32 | Concatenated UTF-8 byte length `B` |
| `4*(N+1)` | uint32[] | Monotonic offsets, beginning with 0 and ending with `B` |
| `B` | bytes | Concatenated UTF-8 strings |

The compiler sorts unique strings lexicographically before assigning indices, removing input hash-order dependence.

## 7. Model section (section 1)

| Bytes | Type | Meaning |
|---:|---|---|
| 1 | uint8 | Version `1` |
| 1 | uint8 | Profile: `1` production, `2` debug |
| 1 | uint8 | String reference width |
| 1 | uint8 | Coordinate flags: bit 0 right-handed; bits 1..2 up axis (`0=X`, `1=Y`, `2=Z`) |
| 4 | uint32 | Root instance index |
| 48 | float64[6] | Definition-local aggregate bounds: min XYZ, max XYZ, metres |
| 36 | uint32[9] | Material, tag, mesh, face, definition, instance, transform, texture, visual-edge counts |
| `2*stringWidth` | adaptive[] | Source filename and model name |

Units are metres in BOMC 1.1.

## 8. Material and tag tables

### 8.1 Materials (section 3)

Header: `version:uint8`, `stringWidth:uint8`, `textureWidth:uint8`, `reserved:uint8`, `count:uint32`.

Columns follow in this exact order:

1. `name[count]`, adaptive string references.
2. `displayName[count]`, adaptive string references.
3. `colorRGBA[count][4]`, uint8.
4. `opacity[count]`, uint16 normalized to `0..65535`.
5. `texture[count]`, adaptive texture references with sentinel.
6. `textureWidthM[count]`, float32.
7. `textureHeightM[count]`, float32.

### 8.2 Tags (section 4)

Header: `version:uint8`, `stringWidth:uint8`, two reserved zero bytes, `count:uint32`.

Columns:

1. `name[count]`, adaptive string references.
2. Visibility bitset, `ceil(count/8)` bytes, least-significant bit first in each byte.

## 9. Mesh directory (section 5)

Header: `version:uint8`, `definitionWidth:uint8`, two reserved bytes, `count:uint32`.

Columns:

1. `definition[count]`, adaptive required definition references.
2. Eleven uint32 columns in order:
   `vertexCount`, `faceStart`, `faceCount`, `edgeStart`, `edgeCount`, `positionOffset`, `positionLength`, `topologyOffset`, `topologyLength`, `uvOffset`, `uvLength`.

`faceStart` and `edgeStart` index global FACES and VISUAL_EDGES rows. Geometry offsets address raw section 7/8/10 bytes. A mesh with no UV has `uvLength=0`.

## 10. Analytical face table (section 6)

Header (24 bytes):

| Bytes | Type | Meaning |
|---:|---|---|
| 1 | uint8 | Version `1` |
| 1 | uint8 | Material reference width |
| 1 | uint8 | Tag reference width |
| 1 | uint8 | String reference width |
| 4 | uint32 | Face count `F` |
| 4 | uint32 | Total polygon-loop count `L` |
| 4 | uint32 | Byte length of face loop-count varints |
| 4 | uint32 | Byte length of face triangle-index-count varints |
| 4 | uint32 | Byte length of loop-length varints |

Columns:

1. `surfaceType[F]`, uint8 enum.
2. `flags[F]`, uint8 bitfield.
3. `semanticRole[F]`, uint8 enum.
4. `frontMaterial[F]`, adaptive with sentinel.
5. `backMaterial[F]`, adaptive with sentinel.
6. `tag[F]`, adaptive with sentinel.
7. `semanticLabel[F]`, adaptive string reference with sentinel.
8. `loopCount[F]`, varuint stream.
9. `triangleIndexCount[F]`, varuint stream; always divisible by three for triangulated faces.
10. `loopLength[L]`, varuint stream.

Face flags:

| Bit | Meaning |
|---:|---|
| 0 | Hidden |
| 1 | Has one or more holes |
| 2 | Has front UV |
| 3 | Has back UV |
| 4 | Geometry-fallback disposition |

Side appearance and UV presence are distinct. A decoded face always requires its
front appearance. It requires an independent back appearance only when
`backMaterial` is not the sentinel. Instance/group paint remains an instance
material override and supplies an unpainted front side without duplicating the
definition geometry. The UV flags report mapping payload only; they never imply
that a side requires a render pass.

Surface enum:

| Value | Meaning | Value | Meaning |
|---:|---|---:|---|
| 0 | unknown | 1 | wall |
| 2 | floor | 3 | ceiling |
| 4 | roof | 5 | roof_slope |
| 6 | roof_flat | 7 | opening |
| 8 | window | 9 | door |
| 10 | railing | 11 | room |
| 12 | facade | 13 | column |
| 14 | beam | 15 | stair |

Semantic-role enum: `0 unknown`, `1 wall`, `2 floor`, `3 ceiling`, `4 roof`, `5 opening`, `6 window`, `7 door`, `8 railing`, `9 room`, `10 facade`, `11 column`, `12 beam`, `13 stair`.

Area is not persisted in production. The decoder computes outer Newell area minus hole Newell areas once at load. Orientation and azimuth are derived from the decoded normal. This avoids repeated Float64 area/orientation/azimuth fields while retaining the source polygons needed to reproduce them.

## 11. Position streams (section 7)

Each mesh owns one block. MESHES records its offset and length. Block header (60 bytes):

| Bytes | Type | Meaning |
|---:|---|---|
| 1 | uint8 | Block version `1` |
| 1 | uint8 | Position codec |
| 2 | bytes | Reserved zero |
| 4 | uint32 | Vertex count |
| 4 | uint32 | Payload byte length |
| 24 | float64[3] | Origin XYZ |
| 24 | float64[3] | Scale XYZ |
| variable | bytes | Codec payload |

Position codecs:

| Value | Encoding |
|---:|---|
| 1 | Float64 absolute XYZ; origin/scale are zero |
| 2 | Float32 XYZ relative to per-axis minimum origin; scale is zero |
| 3 | Int32 XYZ relative to bounding-box centre; `p = origin + q*scale` |
| 4 | Int16 XYZ relative to bounding-box centre; `p = origin + q*scale` |
| 5 | Same passing Int16/Int32 quantization, flattened signed deltas encoded as zigzag-varints |

For every mesh, the compiler measures Float64, Float32-local, Int32, Int16, and delta-varint candidates. A lossy candidate is rejected if:

- maximum Euclidean vertex error exceeds 0.001 m;
- a polygon's area error exceeds `max(1e-6 m2, sourceArea*0.001)`; or
- a nondegenerate loop reverses its Newell-vector direction.

Among passing candidates, the compiler compares candidate DEFLATE byte length, then decode complexity. It records maximum, p95, and RMS errors in benchmark output, not in production BOMC.

## 12. Topology streams (section 8)

Each mesh owns one block:

| Bytes | Type | Meaning |
|---:|---|---|
| 1 | uint8 | Version `1` |
| 3 | bytes | Reserved zero |
| 4 | uint32 | Flattened loop-index count |
| 4 | uint32 | Triangle-index count |
| 4 | uint32 | Loop varint byte length |
| 4 | uint32 | Triangle varint byte length |
| variable | zigzag-varint[] | Loop vertex-index deltas |
| variable | zigzag-varint[] | Triangle vertex-index deltas |

The previous index begins at zero for each of the two streams. Face loop counts, loop lengths, and triangle counts reconstruct every offset through prefix sums; no duplicate offset arrays are stored.

## 13. Normal stream (section 9)

Generic codec-section prefix: `version:uint8`, `codec:uint8`, two reserved bytes, `count:uint32`, `payloadLength:uint32`, followed by payload.

| Codec | Encoding |
|---:|---|
| 1 | Float32 XYZ, 12 bytes/normal |
| 2 | Octahedral Int16 XY, 4 bytes/normal |

Octahedral quantization uses `-32767..32767`. The otherwise-unused pair `(-32768,-32768)` is an exact zero/degenerate-normal sentinel. The encoder chooses octahedral encoding only when maximum angular error is at most 0.1 degree; otherwise it preserves Float32 XYZ.

## 14. UV stream (section 10)

Each mesh with UV owns one block. Header (44 bytes): version, codec, two reserved bytes, UV pair count, payload length, Float64 origin UV, Float64 scale UV, then payload.

Per face, values occur front side then back side. Within a side, values occur outer loop then hole loops. Loop lengths come from FACES, so no UV offset objects are stored.

The producer emits a side's UV mapping only when that exact face side has an
explicit textured material. In particular, UV coordinates merely obtainable
from SketchUp's UV helper for an unpainted/default back side are omitted. An
explicit textured back material retains its distinct back mapping. This matches
CleanPKG's side-material, inherited-material, and UV ownership contract.

| Codec | Encoding |
|---:|---|
| 1 | Float32 UV |
| 2 | IEEE Float16 UV |
| 3 | Int16 with per-axis centre origin and scale |
| 4 | Int16 quantized flattened deltas as zigzag-varints |
| 5 | Float64 fallback |

The numeric gate is maximum Euclidean UV error `1e-4`. Values are never clamped; negative coordinates, rotation, repeat, scale, and values above one survive. Candidate DEFLATE size chooses among passing representations.

## 15. Definitions and instances

### 15.1 Definitions (section 11)

Header: version, string width, mesh width, reserved, count. Columns: name string references, uint8 definition kinds, optional mesh references.

Definition kinds: `0 unknown`, `1 model_definition`, `2 component_definition`, `3 group_definition`.

### 15.2 Instances (section 12)

Header: version, string width, definition width, transform width, material width, tag width, two reserved bytes, count.

Columns: name, uint8 node kind, optional owner definition, referenced definition (required for root/component/group and sentinel for image/text), required transform, optional material override, optional tag, uint8 flags, uint8 semantic role, optional semantic label.

Node kinds: `0 unknown`, `1 root`, `2 component_instance`, `3 group_instance`, `4 image`, `5 text`.

Instance flag bit 0 is visibility. Bit 1 marks geometry-fallback classification. Definition child-node lists are reconstructed by grouping instance rows by owner definition, eliminating another offset/list column.

## 16. Transform stream (section 13)

The generic codec-section prefix is followed by one of:

| Codec | Encoding |
|---:|---|
| 1 | Float64 affine 3x4, 96 bytes/transform |
| 2 | Float32 affine 3x4, 48 bytes/transform |
| 3 | Float32 translation XYZ + quaternion XYZW + scale XYZ, 40 bytes/transform |
| 4 | Float32 translation + Int16 normalized quaternion + Float32 signed scale, 32 bytes/transform |
| 5 | Hybrid: subtype byte per transform; subtype 0 identity has no payload, otherwise subtype 1/2/4 payload |

The omitted 4x4 elements are restored to affine values: indices 3, 7, 11 are zero and index 15 is one. Signed X scale preserves mirror transforms. Decomposition is rejected for zero-scale, shear, or non-orthogonal bases. The selected section candidate must keep maximum matrix-element error at or below `1e-5` and supports translation, rotation, uniform/non-uniform scale, mirror, and affine fallback.

## 17. Visual edges (section 14)

Header: version, tag width, two reserved bytes, edge count, endpoint-varint byte length. Columns: optional tag references, uint8 flags, then two absolute varuint vertex indices per edge. Mesh edge start/count ranges assign rows to meshes.

Edge flags: bit 0 hidden, bit 1 soft, bit 2 smooth.

## 18. Textures (sections 15 and 16)

TEXTURE_TABLE header: version and three reserved bytes, then count. Columns:

1. Media codec/format uint8: `0 binary`, `1 PNG`, `2 JPEG`, `3 WebP`, `4 AVIF`, `5 KTX2`.
2. Pixel width uint32.
3. Pixel height uint32.
4. SHA256 content hash, 32 bytes per texture.
5. Blob offset uint64, relative to raw TEXTURE_BLOBS.
6. Blob length uint64.

TEXTURE_BLOBS concatenates source bytes sorted by SHA256 and uses STORE by default because PNG/JPEG/WebP/KTX2 are already compressed. Materials reference numeric texture indices. Identical bytes are emitted once regardless of filenames, materials, or instances. Production does not require texture filename strings.

The RC benchmarks optional high-quality WebP but conservatively stores original bytes. No destructive transcoding occurs by default.

## 19. Coverage section (section 17)

Six uint32 values: `eligible`, `analytical`, `visualRetained`, `fallback`, `excluded`, `unaccounted`.

The required disposition invariant is:

```text
eligible = analytical + fallback + excluded + unaccounted
unaccounted = 0
```

`visualRetained` is an additional visual-edge/detail count and is not added to the mutually exclusive face disposition sum.

## 20. Image/text fallback stream (section 18)

The fallback stream preserves non-mesh visual nodes without serializing SketchUp Ruby objects. Its header is version uint8, instance-index width uint8, texture-index width uint8, string-index width uint8, and record count uint32. It is followed by columnar arrays:

1. required instance references at the declared adaptive width;
2. node kind uint8 (`4 image`, `5 text`);
3. Float32 position X, Y, and Z columns in metres;
4. Float32 width and height columns in metres;
5. optional embedded-texture references at the declared adaptive width;
6. optional text string references at the declared adaptive width.

Image bytes use the same SHA256-sorted TEXTURE_TABLE/TEXTURE_BLOBS registry as material textures, so identical material and image resources are emitted once. Image filenames are not stored in production. Text content remains a user-facing runtime string and is interned once. The matching INSTANCES row retains hierarchy, transform, material/tag overrides, visibility, semantic role, and label.

## 21. Debug mappings (section 240)

The section begins with version and three reserved bytes, then record count. Each variable record is:

```text
entityCategory:uint8
fieldKind:uint8
rowIndex:varuint
stringIndex:varuint
```

Entity categories: material 1, tag 2, mesh 3, face 4, definition 5, instance 6, visual edge 7. Field kinds: stable ID 1, persistent ID 2, semantic/classification source 3, classification policy/provenance 4.

Debug mappings do not alter numeric runtime IDs. A production decoder may skip section 240 entirely.

## 22. Checksums and corruption handling

CRC32 covers stored section bytes, so corruption is detectable before decompression. A decoder must reject:

- wrong magic/version/endianness;
- directory outside the file;
- nonzero reserved directory fields;
- unaligned, overlapping, or out-of-file sections;
- CRC mismatch;
- unsupported required-section codec;
- decompressed length mismatch;
- truncated/overflowed varints;
- out-of-range table or geometry references;
- texture SHA256 mismatch; or
- nonzero unaccounted geometry.

Texture SHA256 serves both deduplication and end-to-end resource verification. Per-section runtime integrity remains CRC32 for speed.

## 23. Determinism

Deterministic compilation controls:

- numeric section order;
- lexicographically sorted unique string dictionary;
- SHA256-sorted unique texture blobs;
- measured codec selection with stable tie-breaking;
- fixed zlib compression level;
- zero padding;
- no timestamps or random IDs in production; and
- no gzip timestamp wrapper.

The same logical input and profile must produce the same file SHA256.

## 24. Browser decoder pseudocode

```text
view = DataView(arrayBuffer)
assert bytes[0..7] == BOMC_MAGIC
assert view.getUint32(12, true) == 0x01020304

for i in 0..<sectionCount:
  entryBytes = compactDirectoryFlag ? 24 : 40
  d = readDirectoryEntry(directoryOffset + i*entryBytes, littleEndian=true)
  validate d.offset, d.storedLength, alignment, overlap
  remember d by numeric type            # unknown type: remember or skip

function loadSection(type):
  d = directory[type]
  stored = Uint8Array(buffer, d.offset, d.storedLength)
  assert crc32(stored) == d.crc32
  raw = d.codec == STORE ? stored : inflateZlib(stored)
  assert raw.byteLength == d.rawLength
  return raw

strings = decodeStrings(loadSection(STRINGS))
model = decodeModel(loadSection(MODEL), strings)
faces = decodeColumnarFaces(loadSection(FACES))
meshes = decodeMeshDirectory(loadSection(MESHES))

for mesh in meshes:
  positions = decodePositionBlock(loadSection(POSITIONS), mesh.positionRange)
  topology = decodeDeltaTopology(loadSection(TOPOLOGY), mesh.topologyRange)
  reconstruct face offsets with prefix sums of loopCount/loopLength/triangleCount
  if mesh.uvLength > 0: decode per-corner UV in face/side/loop order

definitions = decodeDefinitions(...)
instances = decodeInstances(...)
group instance rows by ownerDefinition to reconstruct definition children
assert coverage.unaccounted == 0
```

## 25. ArrayBuffer and zero-copy guidance

- Parse header/directory with `DataView` and explicit `littleEndian=true`.
- STORE sections already occupy stable byte ranges and can back `Uint8Array` views without copying.
- After inflating a compressed section, retain its `ArrayBuffer`; fixed-width column offsets can back `Uint8Array`, `Uint16Array`, `Uint32Array`, `Int16Array`, `Int32Array`, `Float32Array`, or `Float64Array` views when aligned.
- Delta-varint and quantized blocks decode directly into final typed arrays; do not create per-vertex JavaScript objects.
- Positions should normally decode to `Float32Array` for Three.js `BufferAttribute`, unless a Model-Eval analysis path explicitly requires Float64.
- Topology decodes to `Uint32Array`; a renderer may downcast a mesh to `Uint16Array` only after verifying its vertex count.
- Analytical FACES/MODEL/COVERAGE can load before UV, visual edges, and texture blobs.
- BOMC 1.1 DEFLATE uses the zlib wrapper. A TypeScript decoder may use `DecompressionStream('deflate')` when available or a library fallback. WASM is not mandatory.

## 26. Forward compatibility

- Minor-version readers must rely on header/directory sizes from this specification and skip unknown section types.
- Existing section layouts do not grow in place. A changed layout receives a new per-section version or new section type.
- New codecs require decoder support before use on a required section.
- New optional visual/resource sections may be ignored without changing analytical data.
- A future major version may widen table counts or introduce level-aware chunks while retaining definition sharing.

## 27. Migration

- Canonical v3 remains the human-readable/debug source graph.
- BOME2 remains a legacy sectioned runtime format with a JSON manifest.
- Model-Eval JSON v1 remains a legacy compact JSON interchange.
- BOMC 1.1 is an independent compiled container version, not a renamed BOME2 contract. BOMC 1.0 fixed-directory files remain readable.
- The reference adapter accepts Canonical v3 and existing Model-Eval JSON v1.0/v1.1 fixtures, then emits the same BOMC tables.
- Production runtime IDs are numeric. Consumers that persist selections by stable external ID must compile/use the debug mapping during migration, establish their own durable mapping, or retain the Canonical/JSON sidecar in their migration pipeline. Production BOMC does not silently promise persistent stable strings that the existing compact runtime does not require.

REAL SKETCHUP COMPILED-FORMAT ACCEPTANCE: PENDING USER TEST
