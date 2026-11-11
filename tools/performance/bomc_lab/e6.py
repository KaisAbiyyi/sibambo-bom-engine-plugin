from load import *
import sys
for name in sys.argv[1:]:
    g,meshes=load(name)
    seen_total=0; corners=0; uniq=bytearray(); refs=bytearray(); flags=bytearray(); vals=[]
    for m in meshes:
        table={}  # (vertex, uv) -> id
        pervert={}
        for f in m['faces']:
            if not f['uv']: continue
            loops=[f['outer']]+f['holes']; uvl=[f['uv']['front_outer']]+f['uv'].get('front_holes',[])
            for lp,ul in zip(loops,uvl):
                for v,uv in zip(lp,ul):
                    corners+=1; key=(v,uv[0],uv[1])
                    cands=pervert.setdefault(v,[])
                    if key in table:
                        seen_total+=1; flags.append(1+cands.index(key) if cands.index(key)<254 else 255)
                    else:
                        table[key]=len(table); cands.append(key); flags.append(0); vals.append(uv)
    v=np.round(np.array(vals)*1e9).astype(np.int64)
    b=bytearray()
    for ax in range(2):
        d=np.diff(v[:,ax],prepend=0); b+=zigzag(d)
    print(f"{name}: UV corners={corners} reuse of (vertex,uv) seen before={seen_total} ({seen_total/corners*100:.1f}%)")
    print("  welded UV exact (ref byte + nano delta new values):",sizes(bytes(flags)+bytes(b)))
    raw=np.array([c for m in meshes for f in m['faces'] if f['uv'] for c in f['uv']['front_outer']]).astype('<f8').tobytes()
    print("  current exact float64 per-corner                :",sizes(raw))
