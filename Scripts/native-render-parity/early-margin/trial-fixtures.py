import copy,json,sys
fs=[]
def add(name,change=lambda f:None):
 w=40;h=32;f=dict(id=name,w=w,h=h,frame=[0,0,w,h],bounds=[.25,.25,.5,.5],plate=[7,5,26,22],ink=[12,10,16,12],font=8,safe=[1]*(w*h),luminance=[130]*(w*h),rgba=[220,220,220,255]*(w*h),verified=True,glyphsVerified=True,remaining=0,corePixels=320,partial=False,artworkBudget=1048576,eligible=True,residual=False,fits=dict(normal=True,incomplete=False,partial=False));change(f);fs.append(f)
def hole(f,x,y):f['safe'][y*f['w']+x]=0
add('full-normal-first')
add('full-incomplete-second',lambda f:f.update(fits=dict(normal=False,incomplete=True,partial=False)))
add('full-partial-third',lambda f:f.update(fits=dict(normal=False,incomplete=False,partial=True)))
add('full-all-fit-refused',lambda f:f.update(fits=dict(normal=False,incomplete=False,partial=False)))
add('strict-partial-mainbody',lambda f:(hole(f,8,8),hole(f,8,9),f.update(verified=False)))
add('partial-preserved-art-second-pass',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False)))
add('partial-residual-third-pass',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False,glyphsVerified=False,remaining=2)))
add('partial-residual-threshold-veto',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False,glyphsVerified=False,remaining=97,eligible=False)))
add('partial-fit-failed-policy-rollback',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False,partial=False,fits=dict(normal=False,incomplete=False,partial=False))))
add('partial-original-flag-restored',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False,partial=True,fits=dict(normal=False,incomplete=False,partial=False))))
add('remaining-residual-incomplete-commit',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False,remaining=97,glyphsVerified=False,eligible=False,residual=True,fits=dict(normal=False,incomplete=True,partial=False))))
add('remaining-residual-incomplete-undo',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False,remaining=97,glyphsVerified=False,eligible=False,residual=True,fits=dict(normal=False,incomplete=False,partial=False))))
add('remaining-residual-refused',lambda f:(hole(f,12,10),hole(f,12,11),f.update(verified=False,remaining=97,glyphsVerified=False,eligible=False,residual=False,fits=dict(normal=False,incomplete=False,partial=False))))
json.dump(fs,open(sys.argv[1],'w'))
