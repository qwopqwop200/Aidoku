import json,copy
from pathlib import Path

def make(name,kind='gradient'):
 w,h=180,140; pix=[]
 for y in range(h):
  for x in range(w):
   color=[140+x//4,110+y//4,170] if kind=='gradient' else [135,160,190]
   if kind=='edge': color=[90,135,185] if y<72 else [220,180,90]
   if kind.startswith('curve'): color=[90,135,185] if y<round(55+(x-90)**2/float(kind.split('-')[1] if '-' in kind else 200)) else [220,180,90]
   if kind=='texture': color=[120,160,190] if (x+y)%2 else [210,190,155]
   ink=False;outline=False
   for ox in (65,90,115):
    def isin(px,py): return ox<=px<ox+5 and 48<=py<91 or ox<=px<ox+16 and (48<=py<53 or 66<=py<71 or 86<=py<91)
    ink|=isin(x,y)
    outline|=any(isin(x+dx,y+dy) for dx in range(-2,3) for dy in range(-2,3))
   if outline:color=[250,250,250]
   if ink:color=[20,20,20]
   pix+=color+[255]
 return dict(id=name,width=w,height=h,rgba=pix,bounds=[60/w,44/h,78/w,52/h],frame=[0,0,w,h],glyph=40,record=dict(core=[20,20,20],outline=[250,250,250],surface=[170,140,170,0],width=.05),sampled=[20,20,20],plate=dict(rect=[56,40,88,60],size=[88,60],origin=[56,40]))
fixtures=[make('smooth-gradient'),make('sharp-edge','edge'),make('curve-edge','curve'),make('texture-veto','texture'),make('smooth-flat','flat')]
for key,value,field in [('no-pair',None,'record'),('long-text','ABCDEFGHIJKLMNOPQ','text'),('display-group',True,'displayGroup'),('hidden-opacity',.5,'opacity'),('plate-shadow',{'boxShadow':'1px 1px black'},'style')]:
 f=copy.deepcopy(fixtures[0]);f['id']=key;f[field]=value;fixtures.append(f)
f=copy.deepcopy(fixtures[0]);f['id']='flat-veto';f['record']['surface'][3]=1;fixtures.append(f)
f=copy.deepcopy(fixtures[0]);f['id']='pair-disagrees';f['sampled']=[110,110,110];fixtures.append(f)
f=copy.deepcopy(fixtures[0]);f['id']='clipped-positive';f['coverage']=[[56,40,88,60]];fixtures.append(f)
f=copy.deepcopy(fixtures[0]);f['id']='rotated-positive';f['mode']='rotated-panel';f['matrix']={'a':.98,'b':.1,'c':-.1,'d':.98};fixtures.append(f)
for divisor in [30,40,50,60,80,100]:fixtures.append(make('curved-fit-'+str(divisor),'curve-'+str(divisor)))
# Record crop dimensions even on rejection after image acquisition.
for f in fixtures:
 p=f['plate']; m=f.get('matrix',dict(a=1,b=0,c=0,d=1)); corners=[(p['origin'][0]+m['a']*x+m['c']*y,p['origin'][1]+m['b']*x+m['d']*y) for x,y in ((0,0),(88,0),(88,60),(0,60))]
 import math
 x0=max(0,math.floor(min(x for x,y in corners)-16));y0=max(0,math.floor(min(y for x,y in corners)-16));x1=min(f['width'],math.ceil(max(x for x,y in corners)+16));y1=min(f['height'],math.ceil(max(y for x,y in corners)+16));f['cropPixels']=(x1-x0)*(y1-y0)
if __name__=='__main__':
 import sys;Path(sys.argv[1]).write_text(json.dumps(fixtures))
