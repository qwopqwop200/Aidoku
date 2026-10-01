import json,sys,copy
cases=[]
for i in range(40):
 own=dict(id='A',rect=[10,10,50,45],opaque=True,clipped=False,visible=True,opacity=1,erasure=False,coverage=None)
 peer=dict(id='B',sources=[[70,65,10,10]],ink=[75,70,5,5],inpainted=False,verified=False,provisional=False,partial=False,complete=False,connected=False,size=[0,0])
 other=dict(id='B',rect=[20,20,40,40],opaque=True,clipped=False,visible=True,opacity=1,erasure=False,coverage=None)
 panels=[own]
 variant=i%10
 if variant==1:peer['sources']=[[30,25,10,10]]
 if variant==2:peer.update(sources=[[30,25,10,10]],verified=True,complete=True,connected=True,size=[20,20])
 if variant==3:peer.update(sources=[[30,25,10,10]],verified=True,complete=True,connected=True,provisional=True,size=[20,20])
 if variant==4:peer.update(sources=[[30,25,10,10]]);panels.append(other)
 if variant==5:peer.update(ink=[30,25,10,10]);panels.append(other)
 if variant==6:peer.update(ink=[30,25,10,10]);other['clipped']=True;panels.append(other)
 if variant==7:peer.update(ink=[30,25,10,10],inpainted=True)
 if variant==8:peer.update(ink=[30,25,10,10]);other['coverage']=[[35,30,4,4]];panels.append(other)
 if variant==9:peer.update(sources=[[30,25,10,10]],verified=True,complete=True,connected=True,partial=True,size=[20,20])
 if i>=20 and len(panels)>1:panels[1]['opacity']=.5 if i%2 else 1
 cases.append(dict(id='ownership-'+str(i),legible=i%2==0,panels=panels,captions=[dict(id='A',sources=[[10,10,20,20]],ink=[10,10,20,20],inpainted=False,verified=False,provisional=False,partial=False,complete=False,connected=False,size=[0,0]),peer]))
json.dump(cases,open(sys.argv[1],'w'))
