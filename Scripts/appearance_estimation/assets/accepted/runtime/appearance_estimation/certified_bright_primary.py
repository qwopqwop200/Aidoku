"""Primary source composite from freshly certified repeated finite interiors."""
import numpy as np
from source_appearance import lab
from certified_bright_palette import propose
VERSION='repeated-certified-bright-interior-primary-medoid-v1'
POLICY=dict(minimumBodySupport=.95,minimumBodies=3,maximumOldPrimaryCoverage=.1,
 maximumBodyMedianDistance=10.,minimumNewPrimaryCoverage=.2,minimumSupportedPixelsPerBody=3,
 coverageDeltaE=10.,sourceOnly=True,GTAtInference=False)

def infer(rgb,mask,arrays,geometry,prediction,diagnostic):
 import copy
 if diagnostic.get('mechanism')!='bounded-bright-interiors' or diagnostic.get('semantic',{}).get('accepted') is not True:return None,dict(eligible=False,reason='No fresh bright interiors')
 p=copy.deepcopy(prediction);p['outline']['rgb']=list(diagnostic['sourceObservation']['rgb'])
 observed=propose(rgb,mask,arrays,geometry,p)
 bodies=[b for b in observed['bodies'] if b['sourceSupportFraction']>=.95]
 if len(bodies)<3:return None,dict(eligible=False,reason='Insufficient source bodies')
 ll=np.concatenate([b['lab'] for b in bodies]);pixels=np.concatenate([b['pixels'] for b in bodies]);xy=np.concatenate([b['xy'] for b in bodies]);support=np.concatenate([b['support'] for b in bodies]);ids=np.concatenate([np.full(len(b['lab']),i) for i,b in enumerate(bodies)])
 old=lab([prediction['fill']['rgb']])[0];coverage=float((np.linalg.norm(ll-old,axis=1)<=10).mean())
 if coverage>=.1:return None,dict(eligible=False,reason='Old primary still explains source',oldPrimaryCoverage=coverage)
 medians=np.array([np.median(b['lab'],axis=0) for b in bodies]);center=np.median(medians,axis=0)
 candidates=np.flatnonzero(support);nearest=int(candidates[np.argmin(np.linalg.norm(ll[candidates]-center,axis=1))]);c=pixels[nearest].astype(int).tolist();cl=ll[nearest]
 if np.max(np.linalg.norm(medians-cl,axis=1))>10:return None,dict(eligible=False,reason='Body medians disagree')
 d=np.linalg.norm(ll-cl,axis=1);new=float((d<=10).mean());witnesses=[]
 for i,b in enumerate(bodies):
  hits=np.flatnonzero((ids==i)&support&(d<=10))
  if len(hits)<3:return None,dict(eligible=False,reason='Uncorroborated body median')
  j=int(hits[np.argmin(d[hits])]);witnesses.append(dict(body=i,xy=xy[j].tolist(),rgb=pixels[j].astype(int).tolist(),deltaE=float(d[j]),supportedPixels=len(hits)))
 if new<.2:return None,dict(eligible=False,reason='New primary lacks native coverage')
 return c,dict(sourceDiagnostic=copy.deepcopy(diagnostic),sourceBodySupportFractions=[b['sourceSupportFraction'] for b in bodies],version=VERSION,eligible=True,sourceOnly=True,GTAtInference=False,bodies=len(bodies),oldPrimaryCoverage=coverage,newPrimaryCoverage=new,bodyMedianLab=medians.tolist(),nativeInteriorPixels=len(ll),witnesses=witnesses,exactNativeRGB=c,exactNativeXY=xy[nearest].tolist(),exactNativeBody=int(ids[nearest]))

TAG='brightPrimaryCorrection'

def validate(evidence,rgb=None):
 if not isinstance(evidence,dict) or evidence.get('version')!=VERSION or evidence.get('eligible') is not True:raise ValueError('Invalid bright primary certificate')
 if not 0<=evidence.get('oldPrimaryCoverage',1)<.1 or not .2<=evidence.get('newPrimaryCoverage',0)<=1:raise ValueError('Invalid native primary coverage')
 diagnostic=evidence.get('sourceDiagnostic',{})
 if diagnostic.get('mechanism')!='bounded-bright-interiors' or diagnostic.get('semantic',{}).get('accepted') is not True or sum(v.get('confirmed') is True for v in diagnostic.get('semantic',{}).get('holes',[]))<3:raise ValueError('Missing fresh bright source certificate')
 n=evidence.get('bodies',0);witnesses=evidence.get('witnesses',[])
 fractions=evidence.get('sourceBodySupportFractions',[])
 if len(fractions)!=n or any(not np.isfinite(v) or not .95<=v<=1 for v in fractions):raise ValueError('Invalid direct native body support')
 if type(n) is not int or n<3 or len(witnesses)!=n or {v.get('body') for v in witnesses}!=set(range(n)):raise ValueError('Invalid repeated primary body support')
 def witness(xy,colour):
  if not isinstance(xy,list) or len(xy)!=2 or any(type(v) is not int or v<0 for v in xy):raise ValueError('Invalid primary coordinate')
  if not isinstance(colour,list) or len(colour)!=3 or any(type(v) is not int or not 0<=v<=255 for v in colour):raise ValueError('Invalid primary RGB')
  if rgb is not None:
   x,y=xy
   if y>=rgb.shape[0] or x>=rgb.shape[1] or rgb[y,x].tolist()!=colour:raise ValueError('Native primary witness differs from RGB')
 witness(evidence.get('exactNativeXY'),evidence.get('exactNativeRGB'))
 if evidence.get('exactNativeBody') not in range(n):raise ValueError('Invalid native primary body')
 med=np.asarray(evidence.get('bodyMedianLab'),float);cl=lab([evidence['exactNativeRGB']])[0]
 if med.shape!=(n,3) or not np.isfinite(med).all() or np.any(np.linalg.norm(med-cl,axis=1)>10):raise ValueError('Disagreeing primary body medians')
 for v in witnesses:
  if v.get('supportedPixels',0)<3 or not np.isfinite(v.get('deltaE',np.nan)) or v['deltaE']>10:raise ValueError('Invalid primary supported pixels')
  witness(v.get('xy'),v.get('rgb'))

def restore_baseline(prediction):
 import copy
 from certified_interior_palette import restore_baseline as restore_palette
 out=restore_palette(prediction);fill=out['fill'];prior=fill.get(TAG)
 if prior is None:return out
 if (not isinstance(prior,dict) or prior.get('version')!=VERSION or fill.get('rgb')!=prior.get('newRGB')
     or fill.get('colors')!=[prior.get('newRGB')]+[c for c in prior.get('previousColors',[]) if c!=prior.get('newRGB')] or len(prior.get('previousRGB',[]))!=3):raise ValueError('Invalid warm bright primary provenance')
 validate(prior.get('sourceEvidence'))
 if prior['newRGB']!=prior['sourceEvidence']['exactNativeRGB']:raise ValueError('Primary colour/evidence mismatch')
 fill['rgb']=copy.deepcopy(prior['previousRGB']);fill['colors']=copy.deepcopy(prior['previousColors']);del fill[TAG]
 return out

def attach(rgb,mask,arrays,geometry,prediction,diagnostic):
 import copy
 out=restore_baseline(prediction);colour,evidence=infer(rgb,mask,arrays,geometry,out,diagnostic)
 if colour is None:return out,evidence
 validate(evidence,rgb)
 fill=out['fill'];previous=copy.deepcopy(fill['colors']);prior_rgb=list(fill['rgb'])
 fill['rgb']=colour;fill['colors']=[colour]+[c for c in previous if c!=colour]
 fill[TAG]=dict(version=VERSION,previousRGB=prior_rgb,previousColors=previous,newRGB=colour,sourceEvidence=evidence)
 return out,evidence
