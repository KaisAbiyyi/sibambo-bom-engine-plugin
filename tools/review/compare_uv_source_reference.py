"""Independent stdlib BOMC wire/reference diagnostic. Never imports a producer decoder.

Only explicit loop UVs can PASS. Whole-source and inherited appearance remain HOLD.
All lengths/counts/codecs fail closed; Float64 values never pass through a renderer.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib

SCHEMA = 'sibambo-native-uv-reference-v1'
MAX_BYTES = 256 * 1024 * 1024
MAX_ITEMS = 10_000_000


class Hold(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Hold(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Reader:
    def __init__(self, data):
        self.data, self.at = data, 0

    def take(self, size):
        require(0 <= size <= len(self.data) - self.at, 'truncated/unsafe table size')
        result = self.data[self.at:self.at + size]
        self.at += size
        return result

    def unpack(self, fmt):
        return struct.unpack('<' + fmt, self.take(struct.calcsize('<' + fmt)))

    def values(self, fmt, count):
        require(0 <= count <= MAX_ITEMS, 'unsafe item count')
        return list(self.unpack(str(count) + fmt))

    def indices(self, width, count):
        require(width in (1, 2, 4), 'unknown index width')
        null = (1 << (width * 8)) - 1
        return [None if n == null else n for n in self.values({1: 'B', 2: 'H', 4: 'I'}[width], count)]

    def varuint(self):
        n = 0
        for shift in range(0, 70, 7):
            byte, = self.unpack('B')
            n |= (byte & 127) << shift
            if byte < 128:
                require(n <= 0xffffffffffffffff, 'varuint overflow')
                return n
        raise Hold('varuint overflow')

    def done(self):
        require(self.at == len(self.data), 'trailing table bytes')


def varcolumn(data, count, delta=False):
    require(count <= len(data) and count <= MAX_ITEMS, 'unsafe varint count')
    reader, values, previous = Reader(data), [], 0
    for _ in range(count):
        value = reader.varuint()
        if delta:
            previous += (value >> 1) ^ -(value & 1)
            require(0 <= previous <= 0xffffffff, 'invalid topology index')
            value = previous
        values.append(value)
    reader.done()
    return values


def sections(data):
    r = Reader(data)
    require(r.take(8) == b'BOMC\r\n\x1a\n', 'invalid magic')
    major, minor, endian, flags, count, directory = r.unpack('HHIIIQ')
    require(major == 1 and minor <= 2 and endian == 0x01020304, 'unsupported container layout')
    stride = 24 if flags & 16 else 40
    require(0 < count <= 256 and directory >= 32 and directory + count * stride <= len(data), 'invalid directory')
    minimum = (directory + count * stride + 7) // 8 * 8
    result, ranges, counts = {}, [], {}
    for i in range(count):
        row = Reader(data[directory + i * stride:directory + (i + 1) * stride])
        kind, codec, _flags = row.unpack('HBB')
        if stride == 24:
            offset, stored_size, raw_size, items, crc = row.unpack('IIIII')
        else:
            offset, stored_size, raw_size, items, crc, reserved = row.unpack('QQQIII')
            require(reserved == 0, 'directory reserved field')
        require(kind not in result and codec in (0, 1), 'duplicate section/unknown storage codec')
        require(offset >= minimum and offset % 8 == 0 and offset + stored_size <= len(data), 'section outside container')
        require(raw_size <= MAX_BYTES and stored_size <= MAX_BYTES and items <= MAX_ITEMS, 'unsafe section size/count')
        payload = data[offset:offset + stored_size]
        require(zlib.crc32(payload) == crc, 'section CRC mismatch')
        if codec == 1:
            decoder = zlib.decompressobj()
            raw = decoder.decompress(payload, raw_size + 1)
            require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail, 'invalid/oversized deflate stream')
        else:
            raw = payload
        require(len(raw) == raw_size, 'section raw size mismatch')
        result[kind], counts[kind] = raw, items
        ranges.append((offset, offset + stored_size))
    ranges.sort()
    require(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])), 'overlapping sections')
    return result, counts


def header(reader, versions=(1,)):
    version, a, b, c = reader.unpack('BBBB')
    require(version in versions, 'unknown table version')
    return a, b, c


def codec_header(reader):
    codec, a, b = header(reader)
    require(a == b == 0, 'codec reserved fields')
    count, size = reader.unpack('II')
    require(count <= MAX_ITEMS, 'unsafe codec count')
    return codec, count, size


def numeric_block(data, dimensions):
    r = Reader(data)
    codec, count, size = codec_header(r)
    origin, scale = r.values('d', dimensions), r.values('d', dimensions)
    payload = r.take(size)
    r.done()
    n = count * dimensions
    p = Reader(payload)
    if dimensions == 3:
        require(codec in (1, 2, 3, 4, 5), 'unknown position codec')
        fmt = {1: 'd', 2: 'f', 3: 'i', 4: 'h'}.get(codec)
        if fmt:
            values = p.values(fmt, n)
        else:
            require(n <= len(payload), 'unsafe position delta count')
            values, previous = [], 0
            for _ in range(n):
                v = p.varuint()
                previous += (v >> 1) ^ -(v & 1)
                values.append(previous)
        if codec == 2:
            values = [x + origin[i % dimensions] for i, x in enumerate(values)]
        elif codec >= 3:
            values = [x * scale[i % dimensions] + origin[i % dimensions] for i, x in enumerate(values)]
    else:
        require(codec in (1, 2, 3, 4, 5), 'unknown UV codec')
        fmt = {1: 'f', 2: 'e', 3: 'h', 5: 'd'}.get(codec)
        # UV delta values are signed integers, unlike nonnegative topology indices.
        if codec == 4:
            values, previous = [], 0
            for _ in range(n):
                v = p.varuint()
                previous += (v >> 1) ^ -(v & 1)
                values.append(previous)
        else:
            values = p.values(fmt, n)
        if codec in (3, 4):
            values = [x * scale[i % dimensions] + origin[i % dimensions] for i, x in enumerate(values)]
    p.done()
    require(all(math.isfinite(x) for x in values), 'nonfinite coordinate')
    return [values[i:i + dimensions] for i in range(0, len(values), dimensions)], codec


def transform_table(data):
    r = Reader(data)
    mode, count, size = codec_header(r)
    p = Reader(r.take(size)); r.done()
    affine_indices = (0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14)

    def affine(values):
        matrix = [0.0] * 16
        matrix[15] = 1.0
        for index, value in zip(affine_indices, values):
            matrix[index] = value
        return matrix

    def decode(codec):
        if codec == 0:
            return affine([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
        if codec in (1, 2):
            return affine(p.values('d' if codec == 1 else 'f', 12))
        if codec == 6:
            return p.values('d', 16)
        if codec == 5:
            subtype, = p.unpack('B')
            require(subtype in (0, 1, 2, 4, 6), 'unknown hybrid transform subtype')
            return decode(subtype)
        if codec in (3, 4):
            translation = p.values('f', 3)
            q = p.values('f', 4) if codec == 3 else [n / 32767.0 for n in p.values('h', 4)]
            scale = p.values('f', 3)
            norm = math.sqrt(sum(n * n for n in q))
            require(norm > 0, 'zero quaternion')
            x, y, z, w = [n / norm for n in q]
            columns = [[1-2*(y*y+z*z), 2*(x*y+w*z), 2*(x*z-w*y)],
                       [2*(x*y-w*z), 1-2*(x*x+z*z), 2*(y*z+w*x)],
                       [2*(x*z+w*y), 2*(y*z-w*x), 1-2*(x*x+y*y)]]
            return affine([n * scale[i] for i, col in enumerate(columns) for n in col] + translation)
        raise Hold('unknown transform codec')
    require(mode in (0, 1, 2, 3, 4, 5, 6), 'unknown transform codec')
    # Nonidentity rows require at least one byte per row; identity mode is bounded.
    require(mode == 0 or count <= len(p.data), 'unsafe transform count')
    result = [decode(mode) for _ in range(count)]
    p.done()
    require(all(math.isfinite(x) for row in result for x in row), 'nonfinite transform')
    return result, mode


def decode_wire(data):
    sec, directory_counts = sections(data)
    require(all(n in sec for n in (1, 2, 11, 12, 13)), 'missing core tables')
    r = Reader(sec[2]); require(header(r) == (0, 0, 0), 'string header')
    count, size = r.unpack('II'); offsets = r.values('I', count + 1); payload = r.take(size); r.done()
    require(offsets[0] == 0 and offsets[-1] == size and offsets == sorted(offsets), 'string offsets')
    strings = [payload[a:b].decode('utf8') for a, b in zip(offsets, offsets[1:])]

    def string(index):
        require(index is not None and index < len(strings), 'string reference')
        return strings[index]

    r = Reader(sec[1])
    version, profile, sw, axis, root = r.unpack('BBBBI'); require(version == 1, 'model version')
    r.take(48); model_counts = r.values('I', 9); r.indices(sw, 2); r.done()
    require(all(n <= MAX_ITEMS for n in model_counts), 'unsafe model count')
    textures = []
    if 15 in sec:
        r = Reader(sec[15]); require(header(r) == (0, 0, 0), 'texture header')
        count, = r.unpack('I'); r.take(count)
        widths, heights = r.values('I', count), r.values('I', count)
        r.take(count * 32); offsets, lengths = r.values('Q', count), r.values('Q', count); r.done()
        require(16 in sec and all(o + n <= len(sec[16]) for o, n in zip(offsets, lengths)), 'texture payload bounds')
        textures = list(zip(widths, heights))
    materials = []
    if 3 in sec:
        r = Reader(sec[3]); version, sw, tw, reserved = r.unpack('BBBB'); require(version in (1, 2) and reserved == 0, 'material header')
        count, = r.unpack('I'); names = r.indices(sw, count); r.indices(sw, count); r.take(count * 6)
        tex = r.indices(tw, count); r.take(count * 8)
        if version == 2:
            r.take(count * 58)
        r.done()
        for name, t in zip(names, tex):
            require(t is None or t < len(textures), 'material texture reference')
            materials.append((string(name), textures[t] if t is not None else None))
    r = Reader(sec[11]); sw, mw, reserved = header(r); require(reserved == 0, 'definition header')
    count, = r.unpack('I'); names, kinds, mesh_ids = r.indices(sw, count), r.values('B', count), r.indices(mw, count); r.done()
    kind_names = {1: 'root', 2: 'component_definition', 3: 'group_definition'}
    definitions = []
    for name, kind, mesh in zip(names, kinds, mesh_ids):
        require(kind in kind_names, 'unknown definition kind')
        definitions.append(dict(key=(kind_names[kind], string(name)), mesh=mesh, children=[], faces=[]))
    transforms, transform_codec = transform_table(sec[13])
    r = Reader(sec[12]); version, sw, dw, xw, mw, tw, a, b, count = r.unpack('BBBBBBBBI'); require(version == 1 and a == b == 0, 'instance header')
    names = r.indices(sw, count); kinds = r.values('B', count)
    owners, defs, xforms, mats = r.indices(dw, count), r.indices(dw, count), r.indices(xw, count), r.indices(mw, count)
    r.indices(tw, count); r.take(count * 2); r.indices(sw, count); r.done()
    instances = []
    for owner, definition, transform, mat in zip(owners, defs, xforms, mats):
        require(definition is None or definition < len(definitions), 'instance definition reference')
        require(owner is None or owner < len(definitions), 'instance owner reference')
        require(transform is not None and transform < len(transforms), 'instance transform reference')
        require(mat is None or mat < len(materials), 'instance material reference')
        row = dict(definition=definition, transform=transforms[transform], material=materials[mat] if mat is not None else None)
        instances.append(row)
        if owner is not None:
            definitions[owner]['children'].append(row)
    faces, meshes, codecs = [], [], {'position': set(), 'uv': set(), 'transform': [transform_codec]}
    if 6 in sec:
        r = Reader(sec[6]); version, mw, tw, sw, count, loops, lc, tc, ll = r.unpack('BBBBIIIII'); require(version == 1, 'face version')
        r.take(count); flags = r.values('B', count); r.take(count)
        front, back = r.indices(mw, count), r.indices(mw, count); r.indices(tw, count); r.indices(sw, count)
        loop_counts, triangles, lengths = varcolumn(r.take(lc), count), varcolumn(r.take(tc), count), varcolumn(r.take(ll), loops); r.done()
        require(sum(loop_counts) == loops, 'face loop count mismatch')
        at = 0
        for flag, fm, bm, n, tri in zip(flags, front, back, loop_counts, triangles):
            require(all(m is None or m < len(materials) for m in (fm, bm)), 'face material reference')
            faces.append(dict(flags=flag, front_material=materials[fm] if fm is not None else None, back_material=materials[bm] if bm is not None else None,
                              lengths=lengths[at:at+n], triangle_count=tri, uv={}))
            at += n
    if 5 in sec:
        r = Reader(sec[5]); dw, a, b = header(r); require(a == b == 0, 'mesh header')
        count, = r.unpack('I'); defs = r.indices(dw, count); columns = [r.values('I', count) for _ in range(11)]; r.done()
        for i, definition in enumerate(defs):
            require(definition is not None and definition < len(definitions), 'mesh definition reference')
            vc, fs, fc, es, ec, po, pl, to, tl, uo, ul = [col[i] for col in columns]
            require(fs + fc <= len(faces), 'mesh face range')

            def block(kind, offset, size):
                require(kind in sec and offset + size <= len(sec[kind]), 'mesh block range')
                return sec[kind][offset:offset+size]
            positions, codec = numeric_block(block(7, po, pl), 3); codecs['position'].add(codec)
            require(len(positions) == vc, 'position vertex count')
            top = Reader(block(8, to, tl)); require(header(top) == (0, 0, 0), 'topology header')
            nl, nt, bl, bt = top.unpack('IIII'); loop_indices, triangle_indices = varcolumn(top.take(bl), nl, True), varcolumn(top.take(bt), nt, True); top.done()
            require(all(index < vc for index in loop_indices + triangle_indices), 'topology vertex reference')
            uv = []
            if ul:
                uv, codec = numeric_block(block(10, uo, ul), 2); codecs['uv'].add(codec)
            li = ti = ui = 0
            local_faces = faces[fs:fs+fc]
            for face in local_faces:
                face['loops'] = []
                for length in face['lengths']:
                    require(li + length <= nl, 'face loop range')
                    face['loops'].append([positions[j] for j in loop_indices[li:li+length]])
                    li += length
                size = face['triangle_count']; require(ti + size <= nt and size % 3 == 0, 'triangle range')
                face['triangle_positions'] = [positions[j] for j in triangle_indices[ti:ti+size]]; ti += size
                for side, bit in [('front', 4), ('back', 8)]:
                    if face['flags'] & bit:
                        face['uv'][side] = []
                        for length in face['lengths']:
                            require(ui + length <= len(uv), 'UV loop range')
                            face['uv'][side].append(uv[ui:ui+length]); ui += length
            require(li == nl and ti == nt and ui == len(uv), 'unconsumed mesh geometry')
            definitions[definition]['faces'].extend(local_faces)
            meshes.append(definition)
    actual = [len(materials), model_counts[1], len(meshes), len(faces), len(definitions), len(instances), len(transforms), len(textures), model_counts[8]]
    require(actual == model_counts, 'model table counts mismatch')
    for kind, expected in ((3, actual[0]), (5, actual[2]), (6, actual[3]), (11, actual[4]), (12, actual[5]), (13, actual[6]), (15, actual[7])):
        require(directory_counts.get(kind, 0) == expected, 'directory item count mismatch')
    for definition in definitions:
        require(definition['mesh'] is None or definition['mesh'] < len(meshes), 'definition mesh reference')
    return dict(definitions=definitions, materials=materials, instances=instances,
                codecs={k: sorted(v) for k, v in codecs.items()}, counts=actual)


def packed_point(point):
    require(len(point) == 3 and all(math.isfinite(x) for x in point), 'invalid projected position')
    return struct.pack('>ddd', *[0.0 if x == 0 else x for x in point])


def loop_key(points):
    require(len(points) >= 3, 'degenerate native/wire loop')
    values = [packed_point(p) for p in points]
    rotations = [tuple(values[i:] + values[:i]) for i in range(len(values))]
    key = min(rotations)
    require(rotations.count(key) == 1, 'ambiguous loop rotation')
    return key, rotations.index(key)


def material_key(value):
    if value is None:
        return None
    return value['name'], tuple(value['texture_pixels']) if value['texture_pixels'] is not None else None


def face_key(loops, front, back):
    outer = loop_key(loops[0])[0]
    holes = sorted(loop_key(loop)[0] for loop in loops[1:])
    require(len(set(holes)) == len(holes), 'duplicate hole mapping')
    return outer, tuple(holes), front, back


def compare(reference, wire):
    issues, failures, compared = [], [], 0
    f32_changes = projection_changes = native_points = interior_points = 0
    native_defs = reference['definitions']
    native_faces = defaultdict(list)
    for row in reference['faces']:
        native_faces[row['definition_id']].append(row)
    native_by_id = {row['native_id']: row for row in native_defs}
    require(len(native_by_id) == len(native_defs), 'duplicate native definition IDs')
    used_native_materials = {}
    for face in reference['faces']:
        for side in ('front', 'back'):
            value = face[side + '_material']
            if value:
                used_native_materials[value['native_id']] = material_key(value)
    for occurrence in reference['occurrences']:
        for field in ('explicit_material', 'inherited_material', 'effective_front_material', 'effective_back_material'):
            value = occurrence[field]
            if value:
                used_native_materials[value['native_id']] = material_key(value)
    if any(n > 1 for n in Counter(k[0] for k in used_native_materials.values()).values()) or any(n > 1 for n in Counter(k[0] for k in wire['materials']).values()):
        issues.append('duplicate material names: ownership cannot be uniquely mapped')
    native_candidates, wire_candidates = defaultdict(list), defaultdict(list)
    for row in native_defs:
        native_candidates[(row['kind'], row['exported_name'])].append(row)
    for row in wire['definitions']:
        wire_candidates[row['key']].append(row)
    for occurrence in reference['occurrences']:
        row = native_by_id.get(occurrence['definition_id'])
        if not row or (row['kind'], row['exported_name']) != (occurrence['kind'], occurrence['exported_name']):
            issues.append('occurrence definition/name alias is not uniquely represented')
    for key in sorted(set(native_candidates) | set(wire_candidates)):
        nr, wr = native_candidates[key], wire_candidates[key]
        if len(nr) != 1 or len(wr) != 1:
            issues.append(f'definition mapping {key}: native={len(nr)}, wire={len(wr)}')
            continue
        nd, wd = nr[0], wr[0]
        native_children, wire_children = [], []
        for child in nd['children']:
            native_children.append((child['kind'], child['exported_name'], tuple(child['projected_transform']), material_key(child['material'])))
        for child in wd['children']:
            if child['definition'] is None:
                issues.append(f'nondefinition child in {key}'); continue
            wire_children.append((*wire['definitions'][child['definition']]['key'], tuple(child['transform']), child['material']))
        if Counter(native_children) != Counter(wire_children):
            issues.append(f'child-transform/material multiset mismatch {key}')
            continue
        nf, wf = defaultdict(list), defaultdict(list)
        for face in native_faces[nd['native_id']]:
            loops = [[p['projected_position_m'] for p in loop] for loop in face['loops']]
            nf[face_key(loops, material_key(face['front_material']), material_key(face['back_material']))].append(face)
        for face in wd['faces']:
            wf[face_key(face['loops'], face['front_material'], face['back_material'])].append(face)
        for fk in set(nf) | set(wf):
            if len(nf[fk]) != 1 or len(wf[fk]) != 1:
                issues.append(f'face mapping {key}: native={len(nf[fk])}, wire={len(wf[fk])}'); continue
            a, b = nf[fk][0], wf[fk][0]
            native_loop_positions = {packed_point(p['projected_position_m']) for loop in a['loops'] for p in loop}
            samples = a['triangulation']['points']; native_points += len(samples)
            interior_points += sum(packed_point(p['projected_position_m']) not in native_loop_positions for p in samples)
            for side in ('front', 'back'):
                material = a[side + '_material']
                expected = material is not None and material['texture_pixels'] is not None
                if expected != (side in b['uv']):
                    failures.append(dict(face=a['native_id'], side=side, reason='explicit textured UV presence differs')); continue
                if not expected:
                    continue
                left, right = {}, {}
                for loop in a['loops']:
                    positions = [p['projected_position_m'] for p in loop]
                    lk, rotation = loop_key(positions)
                    left[lk] = loop[rotation:] + loop[:rotation]
                for positions, uvloop in zip(b['loops'], b['uv'][side]):
                    lk, rotation = loop_key(positions)
                    right[lk] = uvloop[rotation:] + uvloop[:rotation]
                for lk, points in left.items():
                    for point, uv in zip(points, right[lk]):
                        sample = point[side]
                        if sample.get('error') or not sample.get('raw_uvq') or sample['raw_uvq'][2] == 0:
                            issues.append(f'invalid native UVQ face {a["native_id"]} {side}'); continue
                        raw = sample['raw_uvq']; projected = sample['projected_uv']
                        require(all(math.isfinite(x) for x in raw + projected + uv), 'nonfinite UV reference')
                        compared += 1
                        projection_changes += sum(raw[i]/raw[2] != projected[i] for i in (0, 1))
                        f32_changes += sum(struct.unpack('<f', struct.pack('<f', x))[0] != x for x in uv)
                        if projected != uv:
                            failures.append(dict(face=a['native_id'], side=side, expected=projected, actual=uv))
    # Any unmapped/ambiguous row blocks a partial explicit PASS.
    status = 'FAIL' if failures else 'HOLD' if issues else 'PASS'
    return dict(schema='sibambo-independent-uv-comparison-v1', explicit_loop_uv=status, compared_loop_samples=compared,
                failures=failures, mapping_holds=issues,
                triangulation_sample_coverage=dict(native_points=native_points, interior_points=interior_points, loop_points=native_points-interior_points),
                inherited_appearance='HOLD', whole_source_numeric_fidelity='HOLD',
                raw_native_to_contract_projection=dict(changed_scalars=projection_changes),
                raw_wire_vs_render_projection=dict(float32_changed_scalars=f32_changes, informational=True),
                counts=dict(native_definitions=len(native_defs), native_faces=len(reference['faces']), native_occurrences=len(reference['occurrences'])),
                wire_codecs=wire['codecs'])


def load_reference(path, artifact_bytes):
    manifest = json.loads((path / 'manifest.json').read_text(encoding='utf8'))
    require(manifest['schema'] == SCHEMA and manifest['complete'] is True, 'reference incomplete/schema mismatch')
    require(manifest['source_before'] == manifest['source_after'], 'reference source SHA changed')
    source = Path(manifest['source_before']['path'])
    require(source.stat().st_size == manifest['source_before']['bytes'] and sha(source.read_bytes()) == manifest['source_before']['sha256'], 'current source identity mismatch')
    require(sha(artifact_bytes) == manifest['artifact_sha256'], 'artifact identity mismatch')
    result = {}
    for name in ('definitions', 'faces', 'occurrences'):
        data = (path / (name + '.ndjson')).read_bytes()
        require(sha(data) == manifest['files'][name + '.ndjson'], 'reference stream SHA mismatch')
        result[name] = [json.loads(line) for line in data.splitlines()]
        require(len(result[name]) == manifest['counts'][name], 'reference stream count mismatch')
    return result, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('--artifact', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    require(str(args.output.absolute()).replace('\\', '/').lower().startswith('d:/'), 'output must be on D:')
    args.output.mkdir(exist_ok=False)
    try:
        require(args.artifact.stat().st_size <= MAX_BYTES * 8, 'artifact exceeds diagnostic allocation limit')
        artifact = args.artifact.read_bytes()
        reference, manifest = load_reference(args.reference, artifact)
        report = compare(reference, decode_wire(artifact))
        report.update(artifact_sha256=sha(artifact), source_sha256=manifest['source_before']['sha256'])
    except (Hold, KeyError, IndexError, ValueError, OSError, struct.error, zlib.error) as error:
        report = dict(explicit_loop_uv='HOLD', whole_source_numeric_fidelity='HOLD', error=f'{type(error).__name__}: {error}')
    (args.output / 'comparison.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n', encoding='utf8')
    print(json.dumps(report))
    return 0 if report['explicit_loop_uv'] == 'PASS' else 2


if __name__ == '__main__':
    raise SystemExit(main())
