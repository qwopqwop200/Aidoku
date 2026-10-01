import json,sys
f=[]
for i in range(54):
 v=i%9
 x=dict(id='early-search-'+str(i),font=12+(i//9),prior=0,minimum=5,source=[50,50],original=[45,55],sourceWidth=30,baseWidth=40,glyph=16,offset=i%2==1,aux=False,provisional=False,word=4,maximum=40,minWidth=0,target=[50,50],radius=30,cleanWidth=0)
 if v==1:x['maximum']=9
 if v==2:x['maximum']=7
 if v==3:x['maximum']=6
 if v==4:x['cleanWidth']=46
 if v==5:x['target']=[44,50];x['radius']=1
 if v==6:x['aux']=True;x['maximum']=7
 if v==7:x['prior']=22;x['maximum']=9
 if v==8:x['minWidth']=65
 f.append(x)
json.dump(f,open(sys.argv[1],'w'))
