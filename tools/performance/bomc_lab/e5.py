from load import *
import sys, collections
for name in sys.argv[1:]:
    g,meshes=load(name)
    print("==",name)
    # normals exact = round9(newell) + nano residual
    have=[(m,f) for m in meshes for f in m['faces'] if f['normal'] is not None]
    if have:
        res=[]
        for m,f in have:
            v=newell(m['pos'],f['outer']); l=np.linalg.norm(v); d=v/l if l>0 else np.zeros(3)
            res.append(np.round(np.array(f['normal'])*1e9).astype(np.int64)-np.round(d*1e9).astype(np.int64))
        res=np.array(res); 
        print(f"  normal residual (nano units) max|r|={np.abs(res).max()} zero-rows={np.mean(np.all(res==0,axis=1))*100:.1f}%")
        b=bytearray()
        for ax in range(3): b+=zigzag(res[:,ax])
        print("  EXACT normals derived+residual:",sizes(bytes(b)))
    # UV map table: per face map index (varuint, first-seen order) + map table float64 + nano residuals
    uvf=[(m,f) for m in meshes for f in m['faces'] if f['uv']]
    if uvf:
        maps={}; idx=[]; resid=[]; table=[]
        for m,f in uvf:
            P=m['pos'][f['outer']]; U=np.array(f['uv']['front_outer'])
            A=np.hstack([P,np.ones((len(P),1))]); X=np.linalg.lstsq(A,U,rcond=None)[0]
            key=tuple(np.round(X.ravel(),7))
            if key not in maps: maps[key]=len(maps); table.append(np.array(key))
            Xk=np.array(key).reshape(4,2)
            pred=A@Xk
            resid+=list((np.round(U*1e9)-np.round(pred*1e9)).astype(np.int64).ravel())
            idx.append(maps[key])
        dl=[];prev=0
        for i in idx: dl.append(i-prev); prev=i
        tb=np.array(table).astype('<f8').tobytes()
        r=np.array(resid)
        print(f"  UV maps={len(maps)} residual nano max={np.abs(r).max()} zero={np.mean(r==0)*100:.1f}%  (rounded-7 map)")
        print("  UV map-index+table (visual, no residual):",sizes(zigzag(dl)+tb))
        print("  UV + nano residual (exact)              :",sizes(zigzag(dl)+tb+zigzag(r)))
    # exact triangle sequence patterns for quads
    pat=collections.Counter(); qn=0
    for m in meshes:
        for f in m['faces']:
            o=f['outer']
            if f['holes'] or len(o)!=4: continue
            qn+=1
            pi={v:i for i,v in enumerate(o)}
            loc=tuple(pi.get(v,-1) for v in f['tri'])
            pat[loc]+=1
    print(f"  quads={qn} distinct exact local tri sequences={len(pat)} top5={pat.most_common(5)}")
