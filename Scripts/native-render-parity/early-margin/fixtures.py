import copy,json,sys
fs=[]
def canvas(id='A',w=24,h=24):return dict(id=id,w=w,h=h,rgba=[240,240,240,0]*(w*h),safe=[0]*(w*h),luminance=[33]*(w*h),frame=[0,0,w,h],imageSize=[w,h],origin=[0,0],scale=[1,1],complete=True,verified=True,connected=True,rootOwned=True,provisional=False,revision=7)
def addgroup(id,change=lambda c,ds:None):
 c=canvas();d=canvas('D');d['rgba']=sum(([x*3+50,y*4+40,180,255] for y in range(24) for x in range(24)),[]);d['safe']=[1]*576;change(c,[d]);fs.append(dict(id=id,op='group',canvas=c,donors=[c,d],budget=524288))
addgroup('opaque-owned-bilinear')
addgroup('fractional-shift-bilinear',lambda c,ds:ds[0].update(origin=[-.2,.3]))
addgroup('different-density',lambda c,ds:ds[0].update(scale=[.8,.7]))
addgroup('clipped-overlap',lambda c,ds:ds[0].update(origin=[6,7]))
addgroup('unsafe-donor-island',lambda c,ds:ds[0]['safe'].__setitem__(12*24+12,0))
addgroup('translucent-donor-edge',lambda c,ds:ds[0]['rgba'].__setitem__((12*24+12)*4+3,128))
addgroup('original-safe-cell-retained',lambda c,ds:c['safe'].__setitem__(12*24+12,1))
addgroup('disconnected-donor',lambda c,ds:ds[0].update(connected=False))
addgroup('provisional-donor',lambda c,ds:ds[0].update(provisional=True))
addgroup('unowned-donor',lambda c,ds:ds[0].update(rootOwned=False))
addgroup('uncertified-donor',lambda c,ds:ds[0].update(complete=False))
addgroup('insufficient-budget');fs[-1]['budget']=100
addgroup('cached-donor-repeat');fs[-1]['repeat']=True
for name,last in [('later-invalidates',True),('own-canvas-later-invalidates',False)]:
 addgroup(name);f=fs[-1]
 if last:
  d=copy.deepcopy(f['donors'][1]);d['id']='BAD';d['complete']=False;f['donors'].append(d)
 else:
  f['canvas']['rgba']=[20,20,20,128]*576;f['donors']=[f['donors'][1],f['canvas']]
def addext(id,change=lambda c,core:None):
 c=canvas(w=40,h=32);c['safe']=[1]*1280
 for y in range(32):c['safe'][y*40+12]=0
 for y in [12,13]:c['safe'][y*40+15]=0
 core=[[5,10,4,8]];change(c,core);fs.append(dict(id=id,op='exterior',canvas=c,core=core,glyph=8,budget=262144))
addext('disconnected-ruby-outside-barrier')
addext('residual-inside-core',lambda c,core:c['safe'].__setitem__(12*40+6,0))
addext('barrier-opening-reaches-ruby',lambda c,core:c['safe'].__setitem__(12*40+12,1))
addext('no-edge-barrier',lambda c,core:c['safe'].__setitem__(12,1))
addext('uncertified-source',lambda c,core:c.update(verified=False))
addext('incomplete-erasure',lambda c,core:c.update(complete=False))
addext('no-residual',lambda c,core:[c['safe'].__setitem__(y*40+15,1) for y in [12,13]])
addext('auxiliary-owned-outside',lambda c,core:core.append([15,12,2,2]))
addext('exterior-budget-exhaustion');fs[-1]['budget']=20
addext('exterior-zero-budget');fs[-1]['budget']=0
for k in range(12):
 addext('barrier-residual-spacing-'+str(k));f=fs[-1]
 for y in [12,13]:f['canvas']['safe'][y*40+15]=1;f['canvas']['safe'][y*40+13+k]=0
json.dump(fs,open(sys.argv[1],'w'))
