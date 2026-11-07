#!/usr/bin/env python3
# AV1 luma-table generator adapted from Niklas Haas / libplacebo, MIT license.
# See Sources/FrameScrubCore/Resources/GrainTemplates/AV1-LICENSE.txt.
# Particle generator is independent. No external program/source code is executed.
from pathlib import Path
import numpy as np,re,json,hashlib,time
import argparse
parser=argparse.ArgumentParser(description="Rebuild neutral grain template banks (requires NumPy).")
parser.add_argument("--av1-source",required=True,type=Path,help="Local libplacebo film_grain_av1.c; see resource README for URL/hash")
parser.add_argument("--output",type=Path,default=Path(__file__).resolve().parents[1]/"Sources/FrameScrubCore/Resources/GrainTemplates")
args=parser.parse_args();r=args.output;r.mkdir(parents=True,exist_ok=True);rng=np.random.default_rng(345678);t=time.monotonic()
source=args.av1_source.read_bytes()
assert hashlib.sha256(source).hexdigest()=="d0acee2090ad38777e12f2472bc3e970339b3aeb7eb20ac919cd12575dde3b69", "Unexpected AV1 source revision"
a=source.decode()
def table(s,name):
 x=re.search(r'\b'+name+r'\s*(?:\[[^\]]*\])+\s*=\s*\{(.*?)\};',s,re.S).group(1);x=re.sub(r'//[^\n]*|/\*.*?\*/','',x,flags=re.S);return np.array([int(v,0) for v in re.findall(r'-?0x[0-9a-fA-F]+|-?\d+',x)],dtype=np.int64)
g=table(a,'gaussian_sequence');assert len(g)==2048
# Partial adaptation of libplacebo luma table generation. Upstream source/license retained.
def av1(seed):
 b=np.zeros((73,82),dtype=np.int64)
 for y in range(73):
  for x in range(82):
   bit=((seed>>0)^(seed>>1)^(seed>>3)^(seed>>12))&1;seed=(seed>>1)|(bit<<15);b[y,x]=(int(g[(seed>>5)&2047])+8)>>4
 for y in range(3,73):
  for x in range(3,79):
   v=8*b[y-1,x-1]+28*b[y-1,x]+8*b[y-1,x+1]+28*b[y,x-1]
   b[y,x]=np.clip(b[y,x]+((v+64)>>7),-128,127)
 return b[9:73,9:73].astype(float)
# Independent Boolean-disc flat-field template, inspired by stochastic film-grain models.
# This is not a port of IPOL code or full intensity-dependent physical image reconstruction.
def physical():
 side=64;ss=8;big=side*ss;coverage=np.zeros((big,big),dtype=bool);mu=.55;spread=.30
 er2=mu*mu*np.exp(2*spread*spread);lam=-np.log(.5)/(np.pi*er2);n=int(rng.poisson(lam*side*side))
 for cx,cy,rad in zip(rng.uniform(0,big,n),rng.uniform(0,big,n),rng.lognormal(np.log(mu),spread,n)*ss):
  x=np.arange(int(np.floor(cx-rad)),int(np.ceil(cx+rad))+1);y=np.arange(int(np.floor(cy-rad)),int(np.ceil(cy+rad))+1);disk=(x[None,:]-cx)**2+(y[:,None]-cy)**2<=rad*rad
  coverage[np.ix_(y%big,x%big)]|=disk
 # Optical blur and pixel-area integration, periodic boundaries.
 ky=np.fft.fftfreq(big)[:,None];kx=np.fft.rfftfreq(big)[None,:];blur=np.exp(-2*np.pi**2*(.25*ss)**2*(kx*kx+ky*ky));v=np.fft.irfft2(np.fft.rfft2(coverage)*blur,s=(big,big));return v.reshape(side,ss,side,ss).mean((1,3))
def normalize(v):
 v=v-v.mean();v/=np.sqrt(np.mean(v*v));return v
# Smooth periodic boundary only in offline bank generation; not standard-conformant synthesis.
def periodic(v):
 n=v.shape[0];edge=4;w=np.ones(n);w[:edge]=np.sin((np.arange(edge)+.5)/edge*np.pi/2);w[-edge:]=w[:edge][::-1]
 v=v*w[:,None]*w[None,:]+np.roll(v,n//2,axis=0)*(1-w[:,None])*w[None,:]+np.roll(v,n//2,axis=1)*(1-w[None,:])*w[:,None]+np.roll(v,(n//2,n//2),(0,1))*(1-w[:,None])*(1-w[None,:]);return normalize(v)
rows=[]
for name in ['av1','particles']:
 bank=[]
 for k in range(16):
  if name=='av1':v=av1(12345+k*1741)
  else:v=physical()
  bank.append(periodic(v))
 bank=np.asarray(bank,dtype='<f2');assert np.isfinite(bank).all();p=r/(name+'.r16f');p.write_bytes(bank.tobytes());f=bank.astype(float);rows.append({'name':name,'shape':list(bank.shape),'mean':float(f.mean()),'rms':float(np.sqrt(np.mean(f*f))),'neighbor_corr_x':float(np.mean(f*np.roll(f,1,2))),'neighbor_corr_y':float(np.mean(f*np.roll(f,1,1))),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()});print(name,'generated',flush=True)
(r/'generated-banks.json').write_text(json.dumps({'rows':rows,'seconds':time.monotonic()-t,'note':'Template adaptations; not full conformant AV1 or full physical image reconstruction.'},indent=2))
