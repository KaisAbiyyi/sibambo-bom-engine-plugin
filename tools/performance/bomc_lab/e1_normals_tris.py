from load import *
import sys, collections
for name in sys.argv[1:]:
    g,meshes=load(name)
    nf=sum(len(m['faces']) for m in meshes)
    # E1: normal derivable?
    maxang=0; bad=0; have=0; flipped=0
    for m in meshes:
        for f in m['faces']:
            if f['normal'] is None: continue
            have+=1
            n=np.array(f['normal']); v=newell(m['pos'],f['outer']); l=np.linalg.norm(v)
            if l==0 or np.linalg.norm(n)==0: bad+=1; continue
            c=np.clip(np.dot(n,v/l)/np.linalg.norm(n),-1,1); a=math.degrees(math.acos(c))
            if a>90: flipped+=1
            if a>0.1: bad+=1
            maxang=max(maxang,a if a<90 else 180-a)
    print(f"{name}: faces={nf} with_stored_normal={have} newell-vs-stored >0.1deg: {bad} flipped:{flipped} max(unflipped)={maxang:.5f}deg")
    # E2: triangle structure
    kinds=collections.Counter(); total_tri_idx=0
    cur_tri=[]; local_tri=[]; cur_loop=[]
    fan_ok=0; tri_faces=0; earcut_needed=0
    for m in meshes:
        for f in m['faces']:
            loopv=list(f['outer'])+[v for h in f['holes'] for v in h]
            cur_loop+=loopv; cur_tri+=f['tri']; total_tri_idx+=len(f['tri'])
            pos_in={}
            for i,v in enumerate(loopv): pos_in.setdefault(v,i)
            try: loc=[pos_in[v] for v in f['tri']]
            except KeyError: kinds['tri_uses_nonloop_vertex']+=1; loc=None
            n=len(f['outer'])
            if loc is None: local_tri+=[0]*len(f['tri']); continue
            local_tri+=loc
            ts=set(frozenset(loc[i:i+3]) for i in range(0,len(loc),3))
            if not f['holes'] and n==3: kinds['triangle']+=1
            elif not f['holes']:
                # any fan from some corner k?
                ok=False
                for k in range(n):
                    fan=set(frozenset(((k),(k+i)%n,(k+i+1)%n)) for i in range(1,n-1))
                    if fan==ts: ok=True;break
                kinds['fan_convexlike' if ok else 'nonfan_simple']+=1
            else: kinds['with_holes']+=1
    print("  face kinds:",dict(kinds))
    def delta(vals):
        prev=0; out=[]
        for v in vals: out.append(v-prev); prev=v
        return zigzag(out)
    print("  current loop stream  :",sizes(delta(cur_loop)))
    print("  current tri stream   :",sizes(delta(cur_tri)))
    print("  tri loop-local u8    :",sizes(bytes(min(x,255) for x in local_tri)))
    # triangles only for faces that are not triangle/fan: explicit local indices + fan corner byte per quad+
    fanbytes=bytearray(); expl=bytearray()
    for m in meshes:
        for f in m['faces']:
            n=len(f['outer'])
            if not f['holes'] and n==3: continue
            loopv=list(f['outer'])+[v for h in f['holes'] for v in h]
            pos_in={}
            for i,v in enumerate(loopv): pos_in.setdefault(v,i)
            loc=[pos_in.get(v,0) for v in f['tri']]
            ts=set(frozenset(loc[i:i+3]) for i in range(0,len(loc),3)); k_ok=None
            if not f['holes']:
                for k in range(n):
                    if set(frozenset(((k),(k+i)%n,(k+i+1)%n)) for i in range(1,n-1))==ts: k_ok=k;break
            if k_ok is not None: fanbytes.append(k_ok if k_ok<255 else 254)
            else: fanbytes.append(255); expl+=varuint(loc)
    print("  tri exact-as-set: fan-corner byte/face + explicit local for rest:",sizes(bytes(fanbytes)+bytes(expl)))
