from load import *
import sys, collections, time
TOL=0.0005
def mesh_loops(m):
    idx=[];off=[];
    for f in m['faces']:
        for lp in [f['outer']]+f['holes']:
            if len(lp)>=3: off.append(len(idx)); idx+=lp
    return np.array(idx,dtype=np.int64),np.array(off,dtype=np.int64)
def newell_all(pos,idx,off):
    if len(off)==0: return np.zeros((0,3))
    p=pos[idx]; nxt=np.arange(len(idx))+1; ends=np.append(off[1:],len(idx))-1
    nxt[ends]=off; q=p[nxt]
    t=np.stack([(p[:,1]-q[:,1])*(p[:,2]+q[:,2]),(p[:,2]-q[:,2])*(p[:,0]+q[:,0]),(p[:,0]-q[:,0])*(p[:,1]+q[:,1])],axis=1)
    return np.add.reduceat(t,off,axis=0)
def gate(pos,dec,idx,off,tol=TOL):
    if len(pos)==0: return True
    if np.max(np.linalg.norm(pos-dec,axis=1))>tol+1e-12: return False
    a=newell_all(pos,idx,off); b=newell_all(dec,idx,off)
    sa=np.linalg.norm(a,axis=1)*0.5; sb=np.linalg.norm(b,axis=1)*0.5
    err=np.abs(sa-sb); tolv=np.maximum(1e-6,sa*0.001)
    if np.any(err>tolv+1e-12): return False
    if np.any((sa>1e-6)&(np.sum(a*b,axis=1)<=0)): return False
    return True
def first_use_order(m):
    order=[];seen={}
    for f in m['faces']:
        for lp in [f['outer']]+f['holes']:
            for v in lp:
                if v not in seen: seen[v]=len(order); order.append(v)
        for v in f['tri']:
            if v not in seen: seen[v]=len(order); order.append(v)
    for v in range(len(m['pos'])):
        if v not in seen: seen[v]=len(order); order.append(v)
    return order,seen
if __name__=="__main__":
 for name in sys.argv[1:]:
     g,meshes=load(name)
     t0=time.time()
     cur_blocks=[]  # current: per-mesh int16 bbox AoS (if passes) else f32
     A=[bytearray(),bytearray(),bytearray()]   # int16 bbox quant, SoA per-axis delta, first-use order
     B=[bytearray(),bytearray(),bytearray()]   # pow2-mm grid adaptive, SoA delta
     C=[bytearray(),bytearray(),bytearray()]   # B + in-face prediction (prev loop vertex / parallelogram)
     hw=[]   # high-watermark loop symbols
     curloops=[]
     stepcount=collections.Counter(); nverts=0; bits_cur=0
     hdrB=bytearray()
     for m in meshes:
         pos=m['pos']; n=len(pos); nverts+=n
         if n==0: continue
         idx,off=mesh_loops(m)
         mn=pos.min(0); mx=pos.max(0); ctr=(mn+mx)/2
         # current int16
         sc=(mx-mn)/65534.0; scs=np.where(sc==0,1,sc)
         q16=np.where(sc==0,0,np.round((pos-ctr)/scs)).astype(np.int64)
         dec16=ctr+q16*sc
         ok16=gate(pos,dec16,idx,off)
         if ok16: cur_blocks.append(q16.astype('<i2').tobytes())
         else: cur_blocks.append((pos-mn).astype('<f4').tobytes())
         order,seen=first_use_order(m)
         perm=np.array(order)
         # A
         qa=q16[perm] if ok16 else np.round((pos[perm]-mn)/1e-6).astype(np.int64)
         d=np.diff(qa,axis=0,prepend=np.zeros((1,3),dtype=np.int64))
         for ax in range(3): A[ax]+=zigzag(d[:,ax])
         # B: adaptive pow2 mm grid
         step=None
         for k in range(1,16):
             s=0.001/(2**k)   # 0.5mm,0.25mm,...
             qb=np.round(pos/s).astype(np.int64); decb=qb*s
             if gate(pos,decb,idx,off): step=s;break
         if step is None:
             s=1e-9; qb=np.round(pos/s).astype(np.int64); k=99
         stepcount[k]+=1
         qbp=qb[perm]
         origin=qbp.min(0)
         hdrB+=varuint([k])+zigzag(origin)
         qbp=qbp-origin
         d=np.diff(qbp,axis=0,prepend=np.zeros((1,3),dtype=np.int64))
         for ax in range(3): B[ax]+=zigzag(d[:,ax])
         # C: in-face prediction, walk loops in order; new vertices get predicted
         newpos=qb-origin  # indexed by original vertex id
         known=set(); last=np.zeros(3,dtype=np.int64); res=[]
         nxt=0
         for f in m['faces']:
             for li,lp in enumerate([f['outer']]+f['holes']):
                 L=len(lp)
                 for j,v in enumerate(lp):
                     curloops.append(v)
                     nv=seen[v]
                     if nv==nxt:
                         hw.append(0); nxt+=1
                         if j==3 and L==4: pred=newpos[lp[0]]+newpos[lp[2]]-newpos[lp[1]]
                         elif j>=1: pred=newpos[lp[j-1]]
                         else: pred=last
                         res.append(newpos[v]-pred); last=newpos[v]
                     else:
                         hw.append(nxt-nv)
             for v in f['tri']:
                 nv=seen[v]
                 if nv==nxt: nxt+=1; res.append(newpos[v]-last); last=newpos[v]
         for v in order[nxt:]:
             res.append(newpos[v]-last); last=newpos[v]
         res=np.array(res,dtype=np.int64).reshape(-1,3)
         for ax in range(3): C[ax]+=zigzag(res[:,ax])
     cur=b''.join(cur_blocks)
     print(f"== {name}: verts={nverts} meshes={len(meshes)} ({time.time()-t0:.0f}s)  pow2-mm step exponents k (step=1mm/2^k): {sorted(stepcount.items())}")
     print("  POS current int16 AoS per-mesh  :",sizes(cur))
     print("  POS A int16 SoA per-axis delta  :",sizes(bytes(A[0]+A[1]+A[2])))
     print("  POS B grid 2^-k mm SoA delta    :",sizes(bytes(hdrB+B[0]+B[1]+B[2])))
     print("  POS C B + in-face/parallelogram :",sizes(bytes(hdrB+C[0]+C[1]+C[2])))
     prev=0; dl=[]
     for v in curloops: dl.append(v-prev); prev=v
     print("  LOOP current delta-zigzag       :",sizes(zigzag(dl)))
     print("  LOOP high-watermark varuint     :",sizes(varuint(hw)))
