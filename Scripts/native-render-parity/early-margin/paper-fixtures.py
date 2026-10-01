import copy,json,sys
cases=[]
for i in range(32):
 iw=100+(i%4)*40;ih=90+(i%3)*30;bounds=[.33,.3,.15,.2];bx=max(0,int(bounds[0]*iw)//1-96);by=max(0,int(bounds[1]*ih)//1-96)
 import math
 w=min(iw,math.ceil((bounds[0]+bounds[2])*iw)+96)-bx;h=min(ih,math.ceil((bounds[1]+bounds[3])*ih)+96)-by;n=w*h
 rgba=[];paint=[]
 for k in range(n):
  rgba.extend([(k*3+i)%256,(k//w*9+30+i)%256,(k%w*7+60)%256,255])
  paint.extend([200+(k%13),90+(k%7),60+(k%19),[0,128,255][k%3]])
 f=dict(id='paper-'+str(i),iw=iw,ih=ih,frame=[17,23,iw/2,ih/2],bounds=bounds,auxiliary=[],excluded=[],sourceFont=12,font=9,vertical=False,single=True,budget=2097152,readFails=False,original=rgba,repair=dict(rgba=paint,safe=[1]*n,verified=True))
 if i%8==1:f['readFails']=True
 if i%8==2:f['repair']=None
 if i%8==3:f['repair']['verified']=False
 if i%8==4:f['auxiliary']=[[.6,.55,.05,.1]];f['excluded']=[[.8,.7,.1,.1],[.1,.2,.05,.07]]
 if i%8==5:f['budget']=1024
 if i%8==6:
  f['repair']['verified']=False
  for y in range(h//3,h//3+8):
   for x in range(w//3,w//3+8):f['repair']['safe'][y*w+x]=0
 if i%8==7:f['sourceFont']=0;f['vertical']=True;f['single']=False
 cases.append(f)
json.dump(cases,open(sys.argv[1],'w'))
