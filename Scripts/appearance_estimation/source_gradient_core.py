"""Finite native colour continuity and cross-component gradient support; no GT input."""
import cv2
import numpy as np
from source_appearance import lab

VERSION='native-interior-component-gradient-paint-v2'


def propose(rgb,predicted_mask,prediction,polygons,font):
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    colours=prediction['fill'].get('colors') or [prediction['fill']['rgb']]
    competing=list(prediction['background'].get('colors') or [prediction['background']['rgb']])
    if prediction['outline']['present']:competing.append(prediction['outline']['rgb'])
    owned=np.ones(predicted_mask.shape,np.uint8)
    if polygons:
        owned[:]=0;cv2.fillPoly(owned,[np.rint(p).astype(np.int32) for p in polygons],1)
    seedmask=predicted_mask.astype(bool)&owned.astype(bool)
    seed=np.zeros(predicted_mask.shape,bool)
    for c in colours:
        cl=lab([c])[0]
        if np.linalg.norm(lab(competing)-cl,axis=1).min()<15:continue
        seed|=(np.linalg.norm(il-cl,axis=2)<=5)&seedmask
    count,labels,stats,_=cv2.connectedComponentsWithStats(seed.astype(np.uint8),8)
    minimum=max(6,int(font*font*.001));trials=[];seen=np.zeros(seed.shape,np.uint8)
    # Source components, not target rectangles, determine finite observed growth.
    for identity in np.argsort(-stats[1:,cv2.CC_STAT_AREA])[:32]+1:
        if stats[identity,cv2.CC_STAT_AREA]<minimum:continue
        yy,xx=np.where(labels==identity);s=int(len(xx)//2);x,y=int(xx[s]),int(yy[s])
        if seen[y,x]:continue
        ffmask=np.zeros((seed.shape[0]+2,seed.shape[1]+2),np.uint8)
        image=il.copy();_,_,ffmask,rect=cv2.floodFill(image,ffmask,(x,y),0,loDiff=(4.,4.,4.),upDiff=(4.,4.,4.),flags=8|cv2.FLOODFILL_MASK_ONLY|(1<<8))
        grown=ffmask[1:-1,1:-1]>0;seen[grown]=1
        touches=bool(grown[0].any() or grown[-1].any() or grown[:,0].any() or grown[:,-1].any())
        if touches:continue
        seeded=int((grown&seed).sum());n=int(grown.sum())
        if seeded<minimum or n<minimum*2:continue
        # Each finite component logs its source palette rather than inventing a colour.
        interior=cv2.distanceTransform(grown.astype(np.uint8),cv2.DIST_L2,5)>1.5
        if interior.sum()<max(12,minimum):continue
        pixels=rgb[interior];ll=il[interior];n=int(interior.sum());center=ll.mean(0);cov=np.einsum('ni,nj->ij',ll-center,ll-center)/max(1,n);_,axes=np.linalg.eigh(cov);axis=axes[:,-1];projection=np.einsum('ij,j->i',ll-center,axis);span=float(np.quantile(projection,.9)-np.quantile(projection,.1))
        if span<8:continue
        ys,xs=np.where(interior)
        coords=np.column_stack([np.ones(n),xs/max(1,font),ys/max(1,font)])
        fit=np.linalg.lstsq(coords,ll,rcond=None)[0];residual=np.linalg.norm(ll-np.einsum('ij,jk->ik',coords,fit),axis=1)
        coherence=float(np.quantile(residual,.75))
        energy=float(np.mean(np.sum((ll-center)**2,axis=1)));r2=1-float(np.mean(residual**2))/max(1e-6,energy)
        hold=(xs+ys)%2==0
        if hold.sum()<4 or (~hold).sum()<4:continue
        validation_fit=np.linalg.lstsq(coords[hold],ll[hold],rcond=None)[0]
        validation_error=ll[~hold]-np.einsum('ij,jk->ik',coords[~hold],validation_fit)
        validation_r2=1-float(np.mean(np.sum(validation_error**2,axis=1)))/max(1e-6,energy)
        candidates=[];candidate_coordinates=[]
        for q in [.1,.5,.9]:
            light=np.quantile(projection,q);select=np.abs(projection-light)<=1.5
            if not select.any():select[int(np.argmin(np.abs(projection-light)))]=True
            pp=pixels[select];median=np.median(pp,axis=0);medoid=int(np.argmin(((pp.astype(float)-median)**2).sum(1)));colour=pp[medoid].astype(int).tolist()
            position=np.flatnonzero(select)[medoid];candidate_coordinates.append([int(xs[position]),int(ys[position])])
            candidates.append(colour)
        trials.append(dict(nativePixels=n,nativeBodyPixels=int(grown.sum()),interiorMarginPx=1.5,seedPixels=seeded,colourPCSpan=span,colourPCAxis=axis.tolist(),planeResidualQ75=coherence,
            explainedColourVariance=r2,validationExplainedVariance=validation_r2,seedRGB=rgb[y,x].astype(int).tolist(),seedXY=[x,y],colourSlopePerFont=fit[1:].tolist(),colours=candidates,colourCoordinates=candidate_coordinates,rect=list(map(int,rect))))
    return trials


def select_components(components):
    accepted=[c for c in components if c['explainedColourVariance']>=.6 and c['validationExplainedVariance']>=.6]
    groups=[]
    for component in accepted:
        slope=np.asarray(component['colourSlopePerFont'],float).ravel()
        slope=slope/max(1e-9,np.linalg.norm(slope))
        group=next((g for g in groups if np.linalg.norm(lab([g[0]['seedRGB']])[0]-lab([component['seedRGB']])[0])<=15
            and all(float(np.dot(slope,np.asarray(c['colourSlopePerFont']).ravel()/max(1e-9,np.linalg.norm(c['colourSlopePerFont']))))>=.8 for c in g)),None)
        if group is None:groups.append([component])
        else:group.append(component)
    return [g for g in groups if len(g)>=3]

