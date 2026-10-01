import copy,json,sys
base=dict(id='blank-fringe',width=160,height=120,frame=[0,0,160,120],bounds=[50/160,40/120,30/160,25/120],sourceFont=16,font=16,plate=[20,20,100,70],ink=[53,43,25,18],plateRGB=[240,240,240],foreground=[20,20,20],vertical=False,others=[],otherInks=[],sample={},coverage=None,validation={},flags={})
def paint(f,rect,c):
 x,y,w,h=rect
 for yy in range(y,y+h):
  for xx in range(x,x+w):f['rgba'][(yy*f['width']+xx)*4:(yy*f['width']+xx)*4+4]=[*c,255]
fs=[]
def add(name,**kw):
 f=copy.deepcopy(base);f.update(kw);f['id']=name;f['rgba']=[240,240,240,255]*(f['width']*f['height']);fs.append(f);return f
add('blank-fringe')
f=add('colored-nonletter-fringe');paint(f,[50,27,30,10],[210,50,50]);paint(f,[50,67,30,12],[210,50,50])
f=add('lettering-fringe');paint(f,[52,29,23,3],[20,20,20]);paint(f,[54,71,19,3],[130,130,130])
f=add('vertical-colored-fringe',vertical=True);paint(f,[35,40,12,25],[210,50,50]);paint(f,[82,40,12,25],[210,50,50])
f=add('left-new-edge-art-veto');paint(f,[43,25,1,55],[0,0,0])
f=add('top-new-edge-art-veto');paint(f,[40,22,47,1],[0,0,0])
add('foreign-source-pad',others=[dict(id='foreign',bounds=[91/160,51/120,8/160,12/120],font=12,vertical=True)])
add('foreign-caption-ink',otherInks=[[89,72,17,9]])
add('empty-foreign-caption-ink',otherInks=[[20,20,0,0]])
add('visible-restoration',restoration=[40,30,50,45])
add('auxiliary-source',auxiliary=[[90/160,45/120,6/160,9/120]])
add('coverage-pieces',coverage=[[20,20,60,70],[90,20,30,70]])
add('coverage-whole',coverage=[[20,20,100,70]])
add('coverage-empty-intersection',coverage=[[20,20,5,5]])
add('fractional-layout',frame=[.2,.3,160,120],plate=[20.1,20.2,99.9,69.8],ink=[53.4,43.8,25.3,18.4])
add('validation-ink-moved',validation={'shift':.6})
add('validation-overflow',validation={'fits':False})
add('validation-unsupported-clip',coverage=[[20,20,60,70],[90,20,30,70]],validation={'clipSupported':False})
for key in ['hasBacking','otherChildren','hasBackgroundImage','displayCardGrowth','sourceErasure','sourcePreservedCaption','transformed','captionTransformed','clippedWithoutCoverage','hidden']:
 add('gate-'+key,flags={key:True})
add('gate-rotation',rotation=.1)
add('gate-opacity',opacity=.8)
add('budget-insufficient',budget=0)
add('source-read-failed',throwRead=True)
add('no-source-colors',foreground=None)
add('image-not-loaded',imageComplete=False)
add('no-area-savings',ink=[22,22,96,66])
add('frame-offset',frame=[-2,-3,160,120])
add('large-source-density',frame=[0,0,80,60],plate=[10,10,60,45],ink=[27,24,16,10])
add('source-page-border',bounds=[0,40/120,20/160,25/120],plate=[0,20,75,70],ink=[8,44,20,18])
add('colors-from-outlined',foreground=None,outlined={'core':[20,20,20]})
add('colors-from-sample',foreground=None,sample={'displayForeground':[20,20,20]})
json.dump(fs,open(sys.argv[1],'w'))
