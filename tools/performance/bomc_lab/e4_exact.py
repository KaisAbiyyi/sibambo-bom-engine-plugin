from load import *
import sys, collections
for name in sys.argv[1:]:
    g,meshes=load(name)
    # 1) nanometer grid exactness of positions (canonical rounds to 9 decimals)
    allpos=np.concatenate([m['pos'] for m in meshes]).ravel()
    n=np.round(allpos*1e9); back=n/1e9
    exact=np.mean(back==allpos)
    print(f"== {name}: positions on 1e-9 grid bit-exact (n/1e9==x): {exact*100:.3f}%")
    # exact size: float64 vs nm-int delta per mesh SoA
    f64=b''.join(m['pos'].astype('<f8').tobytes() for m in meshes)
    nm=bytearray()
    for m in meshes:
        q=np.round(m['pos']*1e9).astype(np.int64)
        d=np.diff(q,axis=0,prepend=np.zeros((1,3),dtype=np.int64))
        for ax in range(3): nm+=zigzag(d[:,ax])
    print("  EXACT pos float64 AoS     :",sizes(f64))
    print("  EXACT pos nm-int SoA delta:",sizes(bytes(nm)))
    # model-eval: positions = min + q*scale exactly
    if g['format'].get('identifier')=='model_eval_json_v1':
        ok=0;tot=0;qb=bytearray()
        for gm in g['meshes']:
            q=np.array(gm['positions'],dtype=np.float64).reshape(-1,3); qq=gm['quantization']
            p=q*np.array(qq['scale_m'])+np.array(qq['minimum_m'])
            tot+=1
            qi=np.array(gm['positions'],dtype=np.int64).reshape(-1,3); d=np.diff(qi,axis=0,prepend=np.zeros((1,3),dtype=np.int64))
            for ax in range(3): qb+=zigzag(d[:,ax])
        print("  EXACT pos source-grid (uint16 q + min/scale) SoA delta:",sizes(bytes(qb)))
    # 2) normals: derivable?
    have=[(m,f) for m in meshes for f in m['faces'] if f['normal'] is not None]
    if have:
        match9=0; within01=0; axis=0
        for m,f in have:
            v=newell(m['pos'],f['outer']); l=np.linalg.norm(v)
            d=np.round(v/l,9) if l>0 else np.zeros(3)
            s=np.array(f['normal'])
            if np.array_equal(d,s): match9+=1
            if l>0 and math.degrees(math.acos(min(1,abs(float(np.dot(d,s)))/max(np.linalg.norm(s),1e-30))))<=0.1: within01+=1
            if np.count_nonzero(np.abs(s)==1.0)==1: axis+=1
        print(f"  normals: stored={len(have)} newell->round9 bit-exact={match9} ({match9/len(have)*100:.1f}%) within0.1deg={within01} axis-aligned={axis}")
        f64n=np.array([f['normal'] for m,f in have]).astype('<f8').tobytes()
        print("  EXACT normals float64     :",sizes(f64n))
        nmn=bytearray()
        arr=np.round(np.array([f['normal'] for m,f in have])*1e9).astype(np.int64)
        for ax in range(3): nmn+=zigzag(arr[:,ax])
        print("  EXACT normals nano-int    :",sizes(bytes(nmn)))
    # 3) UV affine-ness (canonical)
    uvf=[(m,f) for m in meshes for f in m['faces'] if f['uv']]
    if uvf:
        aff=0; maps=collections.Counter(); corners=0; resid_max=0
        for m,f in uvf:
            P=m['pos'][f['outer']]; U=np.array(f['uv']['front_outer'])
            corners+=len(P)
            if len(P)<3: continue
            A=np.hstack([P,np.ones((len(P),1))])
            X,res,rk,sv=np.linalg.lstsq(A,U,rcond=None)
            r=np.max(np.abs(A@X-U)); resid_max=max(resid_max,r) if r<1e-6 else resid_max
            if r<1e-7: aff+=1; maps[tuple(np.round(X.ravel(),6))]+=1
        print(f"  UV: faces={len(uvf)} corners={corners} front-UV exactly affine in position (1e-7): {aff} ({aff/len(uvf)*100:.1f}%) distinct affine maps: {len(maps)}")
        raw=np.array([c for m,f in uvf for c in f['uv']['front_outer']]).astype('<f4').tobytes()
        print("  UV per-corner float32     :",sizes(raw))
