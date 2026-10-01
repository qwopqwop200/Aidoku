import json,sys
f=[]
for i in range(48):
 v=i%8
 x=dict(id='early-clear-'+str(i),font=9+(i//8),prior=0,minimum=5,source=[40,40],original=[40,40],sourceWidth=22,baseWidth=26,glyph=14,offset=False,aux=False,provisional=False,word=2,maximum=40,minWidth=0,target=[40,40],radius=40,cleanWidth=0,grid=[80,80],obstacles=[[24,24,32,32]])
 if v==1:x['target']=[40,10];x['radius']=3
 if v==2:x['target']=[40,40];x['radius']=1
 if v==3:x['maximum']=8
 if v==4:x['cleanWidth']=38
 if v==5:x['glyph']=50
 if v==6:x['obstacles']=[[0,0,80,80]]
 if v==7:x['grid']=[12,12]
 f.append(x)
json.dump(f,open(sys.argv[1],'w'))
