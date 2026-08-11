# BOM Engine Clean Package Binary Contract

Status: Binary RC, pending real SketchUp acceptance

Package identifier: `bom_engine_clean_package`

Package version: `1.0.0`

Logical source: `bom_engine_clean_v1` `1.0.0`

## Container

A `.cleanpkg` is a deterministic ZIP containing exactly:

- `manifest.json`: minified UTF-8 JSON, DEFLATE compressed.
- `buffers.bin`: typed-array payload, DEFLATE only when smaller than STORE.
- referenced `assets/tex-<sha256>.<extension>` files: source bytes, normally STORE.

Entry names are relative, sorted lexically, and use `/`. Timestamps and extra fields are normalized. Texture assets are content-addressed, deduplicated, never base64 encoded, and are not resized or recompressed.

## Manifest

The manifest retains units, coordinate-system metadata, model bounds, stable external IDs, material and texture metadata, semantic classifications, definition/instance metadata, fallback metadata, compact diagnostics, and binary references. High-volume XYZ, topology, UV, normal, area, material-reference, and transform arrays are absent.

`format.identifier` is `bom_engine_clean_package`; `format.version` is `1.0.0`. `format.logical_identifier` and `format.logical_version` identify the reconstructed CleanV1 document.

`buffers.uri` is `buffers.bin`; `buffers.byte_length` is the decompressed byte length; `buffers.endianness` is `little`; and `buffers.padding_bytes` reports all inter-section padding.

`buffers.section_descriptor_fields` defines each positional row in `buffers.sections`:

```json
["byte_offset", "byte_length", "count", "component_count", "component_type"]
```

A `section` value elsewhere in the manifest is a zero-based row index. This removes repeated section names and keys. The descriptor row can be expanded conceptually to:

```text
byte_offset, byte_length, count, component_count, component_type
```

Offsets are relative to the first byte of decompressed `buffers.bin`. Sections are ordered deterministically. Types of width 2 or 4 are aligned to 4 bytes; Float64 sections are aligned to 8 bytes. Padding is zero-filled.

## Numeric types

All values are little-endian and directly match JavaScript typed arrays:

| component_type | JavaScript view | bytes |
|---|---|---:|
| `float32` | `Float32Array` | 4 |
| `float64` | `Float64Array` | 8 |
| `uint16` | `Uint16Array` | 2 |
| `uint32` | `Uint32Array` | 4 |
| `int32` | `Int32Array` | 4 |

Create a view with `new TypedArray(arrayBuffer, byte_offset, count * component_count)`. ZIP decompression must yield the `buffers.bin` ArrayBuffer first; no intermediate JavaScript Number arrays are required.

## Positions

Every logical position pool has a descriptor with `section`, `component_type`, `origin`, and `scale`. Codecs are benchmarked per pool against a 1e-6 metre error budget:

- `float64`: absolute XYZ; `origin` and `scale` are null.
- `float32`: XYZ relative to `origin`; decoded XYZ is `origin + stored`.
- `int32`: quantized XYZ relative to `origin`; decoded XYZ is `origin + stored * scale`.

The encoder selects the smallest passing representation after measuring maximum, p95, and RMS error. It falls back to Float64 when Int32 range or Float32 accuracy is unsafe. Definition geometry remains definition-local.

## Topology

Persisted surfaces are polygons, not triangles. A surface table uses:

- `positions`
- `loop_vertex_indices`
- `loop_offsets`
- `polygon_loop_offsets`

For polygon `p`, its loops occupy `polygon_loop_offsets[p]...polygon_loop_offsets[p+1]`. For loop `l`, vertex references occupy `loop_offsets[l]...loop_offsets[l+1]`. The first loop is the outer loop; subsequent loops are holes. Ordering and winding are preserved. Definition loops index definition-local positions. Root and fallback loops index their table-local position pools. Definition `edges` stores pairs of position indices.

Index sections use Uint16 when the maximum value is at most 65,535 and Uint32 otherwise. No triangulation, decimation, face removal, or architectural-detail reduction occurs.

## Surface fields

Normals are Float32 triples and areas are Float64 scalars. Material references are compact integer indices into `materials`; 65,535 denotes no Uint16 reference. `surface_flags` preserves optional-key presence:

| bit | field |
|---:|---|
| 0 | `normal` |
| 1 | `area_m2` |
| 2 | `front_material_id` |
| 3 | `back_material_id` |
| 4 | `inherited_material_id` |
| 5 | `front_uv` |
| 6 | `back_uv` |

Surface semantic metadata remains in the corresponding manifest metadata row. Definition polygon type may be represented by `default_surface_type: "polygon"`.

## UVs

UV coordinate pools are Float32 pairs. UVs are never clamped: negative values, values greater than one, repeats, rotations, and scales are retained. Each front/back mapping has a per-surface offset plus flattened loop UV indices; `4294967295` denotes an absent mapping. Loop lengths come from topology, so the decoder divides each mapping into outer and hole loops without redundant counts. Shared-definition UV data is serialized once with its definition.

## Definitions and instances

Each `definitions[i]` retains its stable external ID and metadata. `geometry.surface_metadata` holds compact per-polygon metadata and `geometry.binary` references the definition-local typed sections.

Each manifest instance retains its stable external ID and descriptive metadata. High-volume values are columnar sections in `binary_tables.instances`:

- `definition_indices`
- `material_indices`
- `parent_indices`
- `transforms`

Transforms are Float64 affine 3x4 rows of 12 values selected from logical column-major 4x4 indices `[0,1,2,4,5,6,8,9,10,12,13,14]`. Decode into a zero-filled 16-value matrix and set element 15 to 1. This is exact for translation, rotation, uniform/non-uniform scale, and mirrored affine transforms. Parent index `4294967295` and material index `65535` mean absent.

## Visual edges and fallback

Visual edges retain metadata in the manifest and store two endpoint positions per edge in `visual_edge_positions`. Fallback geometry uses the same polygon topology contract as root surfaces plus numeric definition references. Optimization must preserve the CleanV1 coverage dispositions (`analytical`, `visual_retained`, `fallback`, `explicitly_excluded`) exactly.

## Optional fields and versioning

Optional surface keys are governed by `surface_flags`; absent material/parent/definition references use the documented sentinels. Other optional metadata remains optional exactly as in CleanV1.

Readers must reject unsupported major package versions. New optional manifest keys or section tables may be added in a compatible minor version. Existing field meaning, layout, type, endianness, or decoding rules require a new major version. This package does not silently overload the CleanV1 JSON format.

## Decoding pseudocode

```text
manifest = JSON.parse(zip.read("manifest.json"))
buffer = zip.readArrayBuffer("buffers.bin")
fields = manifest.buffers.section_descriptor_fields

view(sectionIndex):
  d = zipObject(fields, manifest.buffers.sections[sectionIndex])
  T = typedArrayConstructor(d.component_type)
  return new T(buffer, d.byte_offset, d.count * d.component_count)

decodePositions(info):
  values = view(info.section)
  for each XYZ:
    if info.component_type == "float64": result = XYZ
    if info.component_type == "float32": result = info.origin + XYZ
    if info.component_type == "int32": result = info.origin + XYZ * info.scale

decodePolygon(p):
  loopRange = polygon_loop_offsets[p : p + 2]
  for each loop in loopRange:
    indexRange = loop_offsets[loop : loop + 2]
    yield loop_vertex_indices[indexRange]

decodeInstance(i):
  resolve definition/material/parent integer indices through manifest tables
  expand the 12 Float64 affine values to the logical 4x4 matrix
```

The Ruby reference implementation is `bom_engine/clean_analysis/binary/reference_decoder.rb`.
