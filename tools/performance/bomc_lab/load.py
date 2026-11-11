import json, numpy as np, zlib, lzma, struct, math
import zstandard, brotli
import os
P=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','..','skps')+os.sep
FIX={'rumahY':P+'model-eval-exports/RUMAH Y_model-eval.json','pres20c':P+'presentation20_canonical.json',
     'sboost2':P+'model-eval-exports/PROJECT SBOOST 2_model-eval.json','sboost1':P+'model-eval-exports/PROJECT SBOOST 1_model-eval.json',
     'house2':P+'model-eval-exports/house2_model-eval.json','testc':P+'test_canonical.json'}
def load(name):
    g=json.load(open(FIX[name]))
    meshes=[]
    if g['format'].get('identifier')=='model_eval_json_v1':
        for m in g['meshes']:
            q=m['quantization']; mn=np.array(q['minimum_m']); sc=np.array(q['scale_m'])
            pos=np.array(m['positions'],dtype=np.float64).reshape(-1,3)*sc+mn
            L=m['loops']; T=m['triangles']; faces=[]
            for r in m['faces']:
                outer=L[r[2]:r[2]+r[3]]; holes=[L[a:a+b] for a,b in r[4]]; tri=T[r[5]:r[5]+r[6]]
                faces.append(dict(outer=outer,holes=holes,tri=tri,normal=None,uv=None))
            meshes.append(dict(pos=pos,faces=faces))
    else:
        for m in g['meshes']:
            pos=np.array(m['positions_m'],dtype=np.float64).reshape(-1,3)
            faces=[dict(outer=f['outer'],holes=f['holes'],tri=f['triangles'],normal=f.get('normal'),uv=f.get('uv')) for f in m['faces']]
            meshes.append(dict(pos=pos,faces=faces))
    return g,meshes
def varuint(vals):
    out=bytearray()
    for v in vals:
        v=int(v)
        while True:
            b=v&0x7f; v>>=7
            if v: out.append(b|0x80)
            else: out.append(b); break
    return bytes(out)
def zz(v): v=int(v); return (v<<1) if v>=0 else ((-v)<<1)-1
def zigzag(vals): return varuint([zz(v) for v in vals])
Z=zstandard.ZstdCompressor(level=19)
def sizes(b):
    return dict(raw=len(b),deflate=len(zlib.compress(b,9)),zstd=len(Z.compress(b)),brotli=len(brotli.compress(b,quality=11,lgwin=24)),xz=len(lzma.compress(b,preset=9|lzma.PRESET_EXTREME)))
def newell(pos,idx):
    p=pos[idx]; q=np.roll(p,-1,axis=0)
    return np.array([np.sum((p[:,1]-q[:,1])*(p[:,2]+q[:,2])),np.sum((p[:,2]-q[:,2])*(p[:,0]+q[:,0])),np.sum((p[:,0]-q[:,0])*(p[:,1]+q[:,1]))])
