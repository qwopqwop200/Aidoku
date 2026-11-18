"""Source-only palette rejection using independently certified native interiors."""
import numpy as np
import cv2
from scipy import ndimage
from source_bright_ring import family_mask
from source_outer_shell import confirmed_bodies
from source_appearance import lab
from certified_bright_palette import propose
VERSION='native-certified-contour-component-palette-pruning-v7'
POLICY=dict(minimumSourceBodySupport=.95,minimumBodies=3,colourDeltaE=10.,primaryAlwaysRetained=True,certifiedContourCoverageRequired=True,maximumNativeAAPx=2.,independentSameColourComponentsRetained=True,sourceOnly=True,GTAtInference=False)

def infer(rgb,mask,arrays,geometry,prediction,diagnostic,minimum_pixels):
 import copy
 if minimum_pixels not in (1,3):raise ValueError('Unsupported native support policy')
 if diagnostic.get('mechanism')!='bounded-bright-interiors' or diagnostic.get('semantic',{}).get('accepted') is not True:return None,dict(eligible=False,reason='No freshly certified bright interiors')
 if prediction['fill'].get('representation')!='source-fusion-observed-palette':return None,dict(eligible=False,reason='No emitted source palette')
 p=copy.deepcopy(prediction);p['outline']['rgb']=diagnostic['sourceObservation']['rgb']
 observation=propose(rgb,mask,arrays,geometry,p);bodies=[b for b in observation['bodies'] if b['sourceSupportFraction']>=.95]
 if len(bodies)<3:return None,dict(eligible=False,reason='Fewer than three source-supported finite bodies')
 colours=prediction['fill']['colors'];primary=prediction['fill']['rgb']
 if not colours or colours[0]!=primary:raise ValueError('Invalid emitted primary palette contract')
 ll=np.concatenate([b['lab'] for b in bodies]);pixels=np.concatenate([b['pixels'] for b in bodies]);xy=np.concatenate([b['xy'] for b in bodies]);support=np.concatenate([b['support'] for b in bodies]);ids=np.concatenate([np.full(len(b['lab']),i) for i,b in enumerate(bodies)])
 source=diagnostic['sourceObservation'];semantic=diagnostic['semantic']
 image_lab=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
 native=family_mask(image_lab,source['candidateRGB'])
 closed=cv2.morphologyEx(native.astype(np.uint8),cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))>0
 _,components=cv2.connectedComponents(closed.astype(np.uint8),8)
 certified=sorted({h['component'] for h,v in zip(source['holes'],semantic['holes']) if v['confirmed']})
 core,_=confirmed_bodies(rgb,diagnostic)
 contour=native&np.isin(components,certified)
 to_contour=ndimage.distance_transform_edt(~contour);to_core=ndimage.distance_transform_edt(~core)
 by,bx=np.where(contour);boundary_lab=image_lab[by,bx]
 rf=arrays['rf'].astype(float);owner=np.maximum(rf[:,:,15]*rf[:,:,16],rf[:,:,17]*rf[:,:,18])
 possible=mask&(np.maximum(arrays['segPrimary'],arrays['segBoundary'])>=.5)&(owner>=.001)&(arrays['ocr'][:,:,0]>0)
 sy,sx=np.where(possible);possible_lab=image_lab[sy,sx]
 retained=[];reports=[]
 for index,colour in enumerate(colours):
  cl=lab([colour])[0];d=np.linalg.norm(ll-cl,axis=1);hits=np.flatnonzero(support&(d<=10))
  crop_distance=np.linalg.norm(image_lab-cl,axis=2);nearest=int(crop_distance.argmin());cy,cx=np.unravel_index(nearest,mask.shape);crop_min=float(crop_distance[cy,cx])
  positions=np.flatnonzero(np.linalg.norm(possible_lab-cl,axis=1)<=10);py,px=sy[positions],sx[positions]
  unmatched=positions[to_contour[py,px]>2]
  boundary_delta=np.linalg.norm(boundary_lab-cl,axis=1);j=int(boundary_delta.argmin());native_boundary_witness=dict(xy=[int(bx[j]),int(by[j])],rgb=rgb[by[j],bx[j]].astype(int).tolist(),deltaE=float(boundary_delta[j]),component=int(components[by[j],bx[j]]));role=bool(boundary_delta[j]<=10)
  boundary_exclusive=role and len(positions)>0 and len(unmatched)==0
  keep=colour==primary or len(hits)>=minimum_pixels or (crop_min<=10 and not boundary_exclusive)
  unrelated_witness=None
  if len(unmatched):
   j=int(unmatched[0]);y,x=int(sy[j]),int(sx[j]);unrelated_witness=dict(xy=[x,y],rgb=rgb[y,x].astype(int).tolist(),distanceToContourPx=float(to_contour[y,x]),distanceToCorePx=float(to_core[y,x]))
  if keep:retained.append(colour)
  votes=[]
  for body in range(len(bodies)):
   hh=hits[ids[hits]==body]
   if not len(hh):continue
   j=int(hh[np.argmin(d[hh])]);votes.append(dict(body=body,supportedPixels=len(hh),xy=xy[j].tolist(),rgb=pixels[j].astype(int).tolist(),deltaE=float(d[j])))
  reports.append(dict(nativeCropWitness=dict(xy=[int(cx),int(cy)],rgb=rgb[cy,cx].astype(int).tolist(),deltaE=crop_min),minimumNativeCropDeltaE=crop_min,possibleTextPixels=len(positions),unexplainedTextPixels=len(unmatched),unexplainedTextWitness=unrelated_witness,nativeBoundaryWitness=native_boundary_witness,boundaryExclusive=boundary_exclusive,index=index,rgb=colour,kept=keep,primary=colour==primary,supportedNativePixels=len(hits),minimumNativeDeltaE=float(d[support].min()),bodyWitnesses=votes))
 return retained,dict(certifiedContourComponents=certified,sourceContourPixels=int(contour.sum()),confirmedSourceCorePixels=int(core.sum()),version=VERSION,eligible=True,minimumPixels=minimum_pixels,bodies=len(bodies),sourceBodySupportFractions=[b['sourceSupportFraction'] for b in bodies],sourceDiagnostic=copy.deepcopy(diagnostic),sourceOnly=True,GTAtInference=False,nativeInteriorPixels=len(ll),supportedInteriorPixels=int(support.sum()),colours=reports)

TAG='interiorPalettePruning'
MINIMUM_PIXELS=1
POLICY={**POLICY,'absenceFromNativeCropSufficient':True}

def validate(evidence,previous,retained,primary,rgb=None):
 if not isinstance(evidence,dict) or evidence.get('version')!=VERSION or evidence.get('eligible') is not True or evidence.get('minimumPixels')!=1:raise ValueError('Invalid component palette certificate')
 diagnostic=evidence.get('sourceDiagnostic',{});semantic=diagnostic.get('semantic',{});source=diagnostic.get('sourceObservation',{})
 if diagnostic.get('mechanism')!='bounded-bright-interiors' or semantic.get('accepted') is not True or sum(v.get('confirmed') is True for v in semantic.get('holes',[]))<3:raise ValueError('Missing source contour certificate')
 n=evidence.get('bodies',0);fractions=evidence.get('sourceBodySupportFractions',[])
 if type(n) is not int or n<3 or len(fractions)!=n or any(not np.isfinite(v) or not .95<=v<=1 for v in fractions):raise ValueError('Invalid native body support')
 if not 0<evidence.get('supportedInteriorPixels',0)<=evidence.get('nativeInteriorPixels',0):raise ValueError('Invalid native support count')
 certified=sorted({h['component'] for h,v in zip(source.get('holes',[]),semantic.get('holes',[])) if v.get('confirmed')})
 if not certified or evidence.get('certifiedContourComponents')!=certified or evidence.get('sourceContourPixels',0)<=0 or evidence.get('confirmedSourceCorePixels',0)<=0:raise ValueError('Invalid native contour component identity')
 labels=None;native=None
 if rgb is not None:
  image=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB);native=family_mask(image,source['candidateRGB'])
  closed=cv2.morphologyEx(native.astype(np.uint8),cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))>0
  _,labels=cv2.connectedComponents(closed.astype(np.uint8),8);core,_=confirmed_bodies(rgb,diagnostic)
  if int((native&np.isin(labels,certified)).sum())!=evidence['sourceContourPixels'] or int(core.sum())!=evidence['confirmedSourceCorePixels']:raise ValueError('Native contour source geometry changed')
 rows=evidence.get('colours',[])
 if len(rows)!=len(previous) or [v.get('index') for v in rows]!=list(range(len(rows))) or [v.get('rgb') for v in rows]!=previous or [v['rgb'] for v in rows if v.get('kept')]!=retained:raise ValueError('Palette decision/report mismatch')
 if not retained or previous[0]!=primary or retained[0]!=primary:raise ValueError('Primary cannot be pruned')
 def colour(c):return isinstance(c,list) and len(c)==3 and all(type(v) is int and 0<=v<=255 for v in c)
 def witness(v,c,maximum=None):
  if not isinstance(v,dict):raise ValueError('Missing native witness')
  xy=v.get('xy');native_rgb=v.get('rgb');d=v.get('deltaE',float('nan'))
  if not isinstance(xy,list) or len(xy)!=2 or any(type(x) is not int or x<0 for x in xy) or not colour(native_rgb) or not np.isfinite(d) or d<0 or (maximum is not None and d>maximum):raise ValueError('Invalid native palette witness')
  if abs(float(np.linalg.norm(lab([c])[0]-lab([native_rgb])[0]))-d)>1e-4:raise ValueError('Palette witness distance differs')
  if rgb is not None:
   x,y=xy
   if y>=rgb.shape[0] or x>=rgb.shape[1] or rgb[y,x].tolist()!=native_rgb:raise ValueError('Palette witness differs from RGB')
  return xy
 for row in rows:
  c=row['rgb'];hits=row.get('supportedNativePixels');minimum=row.get('minimumNativeDeltaE',float('nan'));votes=row.get('bodyWitnesses',[])
  possible=row.get('possibleTextPixels');unexplained=row.get('unexplainedTextPixels')
  if not colour(c) or type(hits) is not int or not 0<=hits<=evidence['supportedInteriorPixels'] or not np.isfinite(minimum) or minimum<0 or type(possible) is not int or type(unexplained) is not int or not 0<=unexplained<=possible:raise ValueError('Invalid colour support counts')
  crop=row.get('nativeCropWitness');witness(crop,c);crop_min=row.get('minimumNativeCropDeltaE',float('nan'))
  if crop_min!=crop['deltaE']:raise ValueError('Native crop support mismatch')
  band=row.get('nativeBoundaryWitness');xy=witness(band,c)
  if band.get('component') not in certified:raise ValueError('Uncertified boundary colour witness')
  if rgb is not None:
   x,y=xy
   if not native[y,x] or int(labels[y,x])!=band['component']:raise ValueError('Boundary witness not in certified contour')
  exclusive=bool(band['deltaE']<=10 and possible>0 and unexplained==0)
  keep=c==primary or hits>=1 or (crop_min<=10 and not exclusive)
  if row.get('primary')!=(c==primary) or type(row.get('kept')) is not bool or row['kept']!=keep or row.get('boundaryExclusive')!=exclusive:raise ValueError('Unsupported component palette decision')
  if unexplained:
   u=row.get('unexplainedTextWitness');xy=witness({**(u or {}),'deltaE':float(np.linalg.norm(lab([c])[0]-lab([(u or {}).get('rgb',[0,0,0])])[0]))},c,10)
   if not np.isfinite(u.get('distanceToContourPx',float('nan'))) or u['distanceToContourPx']<=2:raise ValueError('Invalid independent colour component proof')
  elif row.get('unexplainedTextWitness') is not None:raise ValueError('Unexpected independent component witness')
  if (not hits and (minimum<=10 or votes)) or (hits and (minimum>10 or not votes)):raise ValueError('Invalid body support proof')
  ids=[v.get('body') for v in votes]
  if len(set(ids))!=len(ids) or any(type(v) is not int or not 0<=v<n for v in ids) or sum(v.get('supportedPixels',0) for v in votes)!=hits:raise ValueError('Invalid body witness count')
  for v in votes:
   if v.get('supportedPixels',0)<1:raise ValueError('Empty body witness')
   witness(v,c,10)

def restore_baseline(prediction):
 import copy
 from source_native_primary_quality import restore_baseline as restore_native_quality
 out=restore_native_quality(prediction);fill=out['fill'];prior=fill.get(TAG)
 if prior is None:return out
 if not isinstance(prior,dict) or prior.get('version')!=VERSION or prior.get('primaryRGB')!=fill['rgb'] or prior.get('retainedColors')!=fill.get('colors'):raise ValueError('Invalid warm component palette provenance')
 validate(prior.get('sourceEvidence'),prior.get('previousColors',[]),prior['retainedColors'],fill['rgb'])
 fill['colors']=copy.deepcopy(prior['previousColors']);del fill[TAG]
 return out

def attach(rgb,mask,arrays,geometry,prediction,diagnostic):
 import copy
 out=restore_baseline(prediction);colours,evidence=infer(rgb,mask,arrays,geometry,out,diagnostic,1)
 if colours is None or colours==out['fill']['colors']:return out,evidence
 fill=out['fill'];previous=copy.deepcopy(fill['colors']);validate(evidence,previous,colours,fill['rgb'],rgb)
 fill['colors']=copy.deepcopy(colours);fill[TAG]=dict(version=VERSION,primaryRGB=copy.deepcopy(fill['rgb']),previousColors=previous,retainedColors=copy.deepcopy(colours),sourceEvidence=evidence)
 return out,evidence
