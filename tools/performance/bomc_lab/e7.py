from load import *
from e3_pos import mesh_loops, gate
import sys
for name in sys.argv[1:]:
    g,meshes=load(name); exc=0; tot=0; worst=0
    for m in meshes:
        pos=m['pos']
        if len(pos)==0: continue
        idx,off=mesh_loops(m)
        for k in range(1,16):
            s=0.001/(2**k); dec=np.round(pos/s)*s
            if gate(pos,dec,idx,off): break
        for f in m['faces']:
            o=f['outer']; tot+=1
            if f['normal'] is not None: src=np.array(f['normal'])
            else:
                p0,p1,p2=pos[o[0]],pos[o[1]],pos[o[2]]; src=np.cross(p1-p0,p2-p0)
            v=newell(dec,o); l=np.linalg.norm(v); ls=np.linalg.norm(src)
            if l==0 or ls==0: exc+=1; continue
            a=math.degrees(math.acos(min(1,max(-1,np.dot(v,src)/(l*ls)))))
            worst=max(worst,a)
            if a>0.1: exc+=1
    print(f"{name}: faces={tot} normal exceptions (>0.1deg after grid quantization, or degenerate)={exc} ({exc/tot*100:.2f}%) worst={worst:.2f}deg")
