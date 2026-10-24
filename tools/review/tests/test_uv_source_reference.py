"""Synthetic wire fixtures authored independently here; no production decoder/writer."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

SPEC = importlib.util.spec_from_file_location('independent_uv', Path(__file__).parents[1] / 'compare_uv_source_reference.py')
uv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(uv)


def pack(fmt, *values):
    return struct.pack('<' + fmt, *values)


def varuint(n):
    data = bytearray()
    while n >= 128:
        data.append((n & 127) | 128); n >>= 7
    data.append(n)
    return bytes(data)


def delta(values):
    previous, result = 0, b''
    for value in values:
        d = value - previous; previous = value
        result += varuint(2*d if d >= 0 else -2*d-1)
    return result


def container(rows, deflate=False):
    directory, payloads = bytearray(), bytearray()
    offset = (32 + 24 * len(rows) + 7) // 8 * 8
    base = offset
    for kind, items, raw in rows:
        stored = zlib.compress(raw) if deflate else raw
        codec = 1 if deflate else 0
        directory.extend(pack('HBBIIIII', kind, codec, 0, offset, len(stored), len(raw), items, zlib.crc32(stored)))
        payloads.extend(stored)
        padding = (-len(stored)) % 8
        payloads.extend(b'\0' * padding)
        offset += len(stored) + padding
    header = b'BOMC\r\n\x1a\n' + pack('HHIIIQ', 1, 2, 0x01020304, 16, len(rows), 32)
    return header + directory + b'\0' * (base-len(header)-len(directory)) + payloads


IDENTITY = [1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.]
MOVED = IDENTITY[:]; MOVED[12] = 1.
POSITIONS = [[0.,0.,0.],[1.,0.,0.],[1.,1.,0.],[0.,1.,0.],[.2,.2,0.],[.3,.2,0.],[.2,.3,0.],[.5,.5,0.]]
LOOPS = [[0,1,2,3],[4,5,6]]
UVA = [[[.123456789 + i, float(i)/4] for i in loop] for loop in LOOPS]
UVB = [[[-float(i), -.987654321] for i in loop] for loop in LOOPS]


def fixture(deflate=False):
    strings = ['source.skp', 'Model Root', 'Part', 'Front', 'Back']
    text = ''.join(strings).encode(); offsets = [0]
    for value in strings:
        offsets.append(offsets[-1] + len(value.encode()))
    strings_data = pack('BBBBII',1,0,0,0,len(strings),len(text)) + pack('6I',*offsets) + text
    model_counts = [2,0,1,1,2,3,2,2,0]
    model = pack('BBBBI',1,1,1,0,0) + pack('6d',0,0,0,1,1,0) + pack('9I',*model_counts) + bytes([0,0])
    material = bytes([1,1,1,0]) + pack('I',2) + bytes([3,4,3,4]) + bytes([255]*8) + pack('2H',65535,65535) + bytes([0,1]) + pack('4f',1,1,1,1)
    texture = bytes([1,0,0,0]) + pack('I',2) + bytes([1,1]) + pack('4I',2,2,2,2) + bytes(64) + pack('4Q',0,0,0,0)
    defs = bytes([1,1,1,0]) + pack('I',2) + bytes([1,2]) + bytes([1,2]) + bytes([255,0])
    instances = bytes([1,1,1,1,1,1,0,0]) + pack('I',3)
    instances += bytes([1,2,2]) + bytes([1,2,2]) + bytes([255,0,0]) + bytes([0,1,1]) + bytes([0,0,1]) + bytes([255]*3) + bytes([255]*3) + bytes([1]*3) + bytes(3) + bytes([255]*3)
    affine_indices = [0,1,2,4,5,6,8,9,10,12,13,14]
    transform_payload = pack('24d',*[m[i] for m in (IDENTITY,MOVED) for i in affine_indices])
    transforms = bytes([1,1,0,0]) + pack('II',2,len(transform_payload)) + transform_payload
    faces = pack('BBBBIIIII',1,1,1,1,1,2,1,1,2) + bytes([0,12,0,0,1,255,255,2,9,4,3])
    pos_payload = pack('24d',*[x for point in POSITIONS for x in point])
    position = bytes([1,1,0,0]) + pack('II',8,len(pos_payload)) + bytes(48) + pos_payload
    loop_payload, triangles = delta([i for loop in LOOPS for i in loop]), delta([0,1,7,1,2,7,2,3,7])
    topology = bytes([1,0,0,0]) + pack('IIII',7,9,len(loop_payload),len(triangles)) + loop_payload + triangles
    uv_payload = pack('28d',*[n for side in (UVA,UVB) for loop in side for pair in loop for n in pair])
    uv_data = bytes([1,5,0,0]) + pack('II',14,len(uv_payload)) + bytes(32) + uv_payload
    meshes = bytes([1,1,0,0]) + pack('I',1) + bytes([1]) + pack('11I',8,0,1,0,0,0,len(position),0,len(topology),0,len(uv_data))
    rows = [(1,1,model),(2,5,strings_data),(3,2,material),(5,1,meshes),(6,1,faces),(7,1,position),(8,1,topology),(10,1,uv_data),(11,2,defs),(12,3,instances),(13,2,transforms),(15,2,texture),(16,0,b'')]
    native_materials = [dict(native_id='m'+str(i), name=name, texture_pixels=[2,2]) for i,name in enumerate(('Front','Back'))]

    def point(index, a=None, b=None):
        a = a if a is not None else [0.,0.]
        b = b if b is not None else [0.,0.]
        return dict(position_inches=[x/.0254 for x in POSITIONS[index]], projected_position_m=POSITIONS[index],
                    front=dict(raw_uvq=[a[0]*2,a[1]*2,2], projected_uv=a),
                    back=dict(raw_uvq=[b[0]*-2,b[1]*-2,-2], projected_uv=b))
    native_loops = [[point(index,UVA[j][i],UVB[j][i]) for i,index in enumerate(loop)] for j,loop in enumerate(LOOPS)]
    child = lambda n,m: dict(native_id=n, definition_id='part', kind='component_definition', exported_name='Part', projected_transform=m, material=None)
    reference = dict(definitions=[dict(native_id='root',kind='root',exported_name='Model Root',children=[child('one',IDENTITY),child('two',MOVED)]),dict(native_id='part',kind='component_definition',exported_name='Part',children=[])],
                     faces=[dict(native_id='face',definition_id='part',loops=native_loops,front_material=native_materials[0],back_material=native_materials[1],triangulation=dict(points=[point(i) for i in range(8)]))],
                     occurrences=[dict(path=[n], native_id=n,definition_id='part',kind='component_definition',exported_name='Part',explicit_material=None,inherited_material=None,effective_front_material=None,effective_back_material=None) for n in ('one','two')])
    return rows, reference


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.rows, self.ref = fixture()
        self.data = container(self.rows)
        self.wire = uv.decode_wire(self.data)

    def test_exact_front_back_hole_repeated_occurrence_negative_q_and_interior(self):
        report = uv.compare(self.ref,self.wire)
        self.assertEqual(report['explicit_loop_uv'],'PASS')
        self.assertEqual(report['compared_loop_samples'],14)
        self.assertEqual(report['triangulation_sample_coverage'],dict(native_points=8,interior_points=1,loop_points=7))
        self.assertGreater(report['raw_wire_vs_render_projection']['float32_changed_scalars'],0)
        self.assertEqual(report['whole_source_numeric_fidelity'],'HOLD')
        self.assertEqual(report['inherited_appearance'],'HOLD')

    def test_one_billionth_is_a_failure_not_float32_equality(self):
        self.ref['faces'][0]['loops'][0][0]['front']['projected_uv'][0] += 1e-9
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'FAIL')

    def test_cyclic_rotation_without_reversal(self):
        loops = self.ref['faces'][0]['loops']
        loops[0] = loops[0][1:] + loops[0][:1]
        loops[1] = loops[1][2:] + loops[1][:2]
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'PASS')
        loops[0].reverse()
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')

    def test_duplicate_face_keys_and_missing_native_mapping_hold(self):
        self.ref['faces'].append(copy.deepcopy(self.ref['faces'][0]))
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')
        self.ref['faces'] = []
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')

    def test_duplicate_definition_name_and_group_alias_hold(self):
        self.ref['definitions'].append(dict(native_id='duplicate',kind='component_definition',exported_name='Part',children=[]))
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')
        self.ref['definitions'].pop()
        self.ref['occurrences'][0]['exported_name']='Different group name'
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')

    def test_duplicate_material_names_hold(self):
        self.ref['faces'][0]['back_material']['name']='Front'
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')

    def test_zero_q_and_error_hold(self):
        self.ref['faces'][0]['loops'][0][0]['front']['raw_uvq'][2]=0
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')
        self.ref['faces'][0]['loops'][0][0]['front']['error']={'message':'SDK failure'}
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')

    def test_no_uv_is_not_synthetic_zero_uv(self):
        face = self.ref['faces'][0]
        face['front_material']=face['back_material']=None
        wire_face=self.wire['definitions'][1]['faces'][0]
        wire_face['front_material']=wire_face['back_material']=None
        wire_face['uv']={}
        report=uv.compare(self.ref,self.wire)
        self.assertEqual(report['explicit_loop_uv'],'PASS')
        self.assertEqual(report['compared_loop_samples'],0)

    def test_wrong_child_transform_holds(self):
        self.ref['definitions'][0]['children'][1]['projected_transform']=IDENTITY
        self.assertEqual(uv.compare(self.ref,self.wire)['explicit_loop_uv'],'HOLD')

    def test_crc_truncation_and_unknown_storage_codec_rejected(self):
        data=bytearray(self.data); data[-1]^=1
        # Corrupt the actual stored position payload rather than alignment padding.
        entry=32+5*24; offset=struct.unpack_from('<I',data,entry+4)[0]
        data[offset+60]^=1
        with self.assertRaises(uv.Hold): uv.decode_wire(data)
        with self.assertRaises(uv.Hold): uv.decode_wire(self.data[:32])
        data=bytearray(self.data); data[34]=99
        with self.assertRaises(uv.Hold): uv.decode_wire(data)

    def test_unknown_uv_codec_and_unsafe_count_rejected(self):
        rows=copy.deepcopy(self.rows)
        idx=next(i for i,r in enumerate(rows) if r[0]==10)
        kind,count,data=rows[idx]; data=bytearray(data); data[1]=99; rows[idx]=(kind,count,bytes(data))
        with self.assertRaises(uv.Hold): uv.decode_wire(container(rows))
        data[1]=5; struct.pack_into('<I',data,4,0xffffffff); rows[idx]=(kind,count,bytes(data))
        with self.assertRaises(uv.Hold): uv.decode_wire(container(rows))

    def test_store_and_deflate_equal_and_all_numeric_modes(self):
        self.assertEqual(self.wire,uv.decode_wire(container(self.rows,deflate=True)))
        for dim,codec,fmt in [(3,1,'d'),(3,2,'f'),(3,3,'i'),(3,4,'h'),(2,1,'f'),(2,2,'e'),(2,3,'h'),(2,5,'d')]:
            payload=pack(str(dim)+fmt,*range(dim))
            data=bytes([1,codec,0,0])+pack('II',1,len(payload))+pack(str(dim*2)+'d',*([0.]*dim+[1.]*dim))+payload
            result,_=uv.numeric_block(data,dim)
            self.assertEqual(result,[list(range(dim))])
        for dim,codec in ((2,4),(3,5)):
            payload=delta([0,-1]* (dim//2)+([2] if dim==3 else []))
            data=bytes([1,codec,0,0])+pack('II',1,len(payload))+pack(str(dim*2)+'d',*([0.]*dim+[1.]*dim))+payload
            self.assertEqual(uv.numeric_block(data,dim)[0],[[0,-1]+([2] if dim==3 else [])])

    def test_complete_stream_hash_and_source_identity_guards(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TEMP'],prefix='uv-compare-') as folder:
            root=Path(folder); source=root/'source.skp';source.write_bytes(b'synthetic')
            identity=dict(path=str(source),bytes=source.stat().st_size,sha256=uv.sha(source.read_bytes()))
            manifest=dict(schema=uv.SCHEMA,complete=True,source_before=identity,source_after=copy.deepcopy(identity),artifact_sha256=uv.sha(self.data),files={},counts={})
            for name,rows in self.ref.items():
                data=('\n'.join(json.dumps(row) for row in rows)+'\n').encode();(root/(name+'.ndjson')).write_bytes(data)
                manifest['files'][name+'.ndjson']=uv.sha(data);manifest['counts'][name]=len(rows)
            def save(): (root/'manifest.json').write_text(json.dumps(manifest))
            save(); self.assertEqual(uv.load_reference(root,self.data)[0],self.ref)
            manifest['complete']=False;save()
            with self.assertRaises(uv.Hold):uv.load_reference(root,self.data)
            manifest['complete']=True; manifest['source_after']['sha256']='changed';save()
            with self.assertRaises(uv.Hold):uv.load_reference(root,self.data)
            manifest['source_after']=copy.deepcopy(identity);save();source.write_bytes(b'modified')
            with self.assertRaises(uv.Hold):uv.load_reference(root,self.data)
            source.write_bytes(b'synthetic');(root/'faces.ndjson').write_text('[]')
            with self.assertRaises(uv.Hold):uv.load_reference(root,self.data)


if __name__=='__main__':
    unittest.main()
