"""Native finite-white-shell geometry. Runtime functions perform no file I/O.

Ownership certifies the origin, not the colour role of its exterior. Only finite
observed white runs can vote; unbounded white is explicitly right-censored.
No IDs, pages, labels, or nominal GT widths enter this module.
"""
from collections import Counter, defaultdict
import cv2
import numpy as np

POLICY = dict(version='owned-finite-white-shell-v2', maxRays=900,
              whiteMinimumL=90, whiteMaximumChroma=10,
              primarySearchPx=4, maximumAAPx=2, minimumExteriorPx=2,
              minimumOuterDeltaE=12, depth='max(10,min(40,round(font*.4)))',
              sample='nearest native pixel, duplicate coordinates removed',
              inferenceGT=False, contextExpanded=False)


def scan(rgb, core, primary, font):
    from source_bright_ring import family_mask
    image = cv2.cvtColor(rgb.astype(np.float32)/255, cv2.COLOR_RGB2LAB)
    white = (image[:,:,0]>=90)&(np.linalg.norm(image[:,:,1:],axis=2)<=10)
    dark = family_mask(image, primary)&~white
    inside = cv2.distanceTransform(core.astype(np.uint8),cv2.DIST_L2,5)
    outside = cv2.distanceTransform((~core).astype(np.uint8),cv2.DIST_L2,5)
    gy,gx = np.gradient(cv2.GaussianBlur(inside-outside,(0,0),1))
    edge = core&~cv2.erode(core.astype(np.uint8),np.ones((3,3),np.uint8)).astype(bool)
    yy,xx = np.where(edge)
    if len(xx)>POLICY['maxRays']:
        take=np.linspace(0,len(xx)-1,POLICY['maxRays']).astype(int);xx,yy=xx[take],yy[take]
    _,cc=cv2.connectedComponents(core.astype(np.uint8),8)
    depth=max(10,min(40,round(font*.4)));h,w=core.shape
    records=[];counts=Counter();seen=set()
    for x,y in zip(xx,yy):
        normal=-np.array([gx[y,x],gy[y,x]],float);norm=np.linalg.norm(normal)
        if norm<.2:continue
        normal/=norm
        steps=np.arange(0,depth+.25,.5)
        coords=np.rint(np.array([x,y])+steps[:,None]*normal).astype(int)
        keep=np.r_[True,np.any(coords[1:]!=coords[:-1],axis=1)]
        coords=coords[keep];tt=steps[keep]
        valid=(coords[:,0]>=0)&(coords[:,1]>=0)&(coords[:,0]<w)&(coords[:,1]<h)
        stop=next((i for i,v in enumerate(valid) if not v),len(valid))
        coords=coords[:stop];tt=tt[:stop]
        if len(coords)<5:counts['crop-censored']+=1;continue
        xs,ys=coords.T
        exits=np.flatnonzero(~core[ys,xs])
        if not len(exits):continue
        start=int(exits[0]);counts['rays']+=1
        band=next((i for i in range(start,len(tt)) if tt[i]-tt[start]<=4 and dark[ys[i],xs[i]]),None)
        if band is None:counts['no-attached-primary']+=1;continue
        end=band
        while end<len(tt) and dark[ys[end],xs[end]]:end+=1
        if end>=len(tt):counts['primary-censored']+=1;continue
        bright=next((i for i in range(end,len(tt)) if tt[i]-tt[end]<=2 and white[ys[i],xs[i]]),None)
        if bright is None:counts['no-white-after-primary']+=1;continue
        signature=tuple(coords[band])
        if signature in seen:continue
        seen.add(signature);counts['eligible']+=1
        finish=bright
        while finish<len(tt) and white[ys[finish],xs[finish]]:finish+=1
        if finish>=len(tt):counts['white-right-censored']+=1;continue
        # All visible subsequent coordinates through >=2px must remain exterior,
        # and must neither return to a glyph body nor to primary/white paint.
        tail=np.flatnonzero((tt>=tt[finish])&(tt<=tt[finish]+2))
        if not len(tail) or tt[-1]<tt[finish]+2:counts['exterior-censored']+=1;continue
        if core[ys[bright:tail[-1]+1],xs[bright:tail[-1]+1]].any():counts['glyph-reentry']+=1;continue
        if (white[ys[tail],xs[tail]]|dark[ys[tail],xs[tail]]).any():counts['unstable-exterior']+=1;continue
        white_lab=np.median(image[ys[bright:finish],xs[bright:finish]],axis=0)
        exterior=image[ys[tail],xs[tail]]
        delta=float(np.min(np.linalg.norm(exterior-white_lab,axis=1)))
        if delta<12:counts['weak-outer-edge']+=1;continue
        # Transition midpoints give source-composite thickness, not intrinsic stroke width.
        first=.5*(tt[max(0,band-1)]+tt[band]);middle=.5*(tt[end-1]+tt[bright])
        last=.5*(tt[finish-1]+tt[finish])
        widths=[float(middle-first),float(last-middle)]
        colours=rgb[ys[bright:finish],xs[bright:finish]]
        med=np.median(colours.astype(float),axis=0)
        medoid=int(np.argmin(np.linalg.norm(colours-med,axis=1)))
        observed=colours[medoid].astype(int).tolist()
        sector=int((np.arctan2(normal[1],normal[0])+np.pi)/(np.pi/2))%4
        records.append(dict(origin=[int(x),int(y)],primaryXY=coords[band].tolist(),
            outerXY=coords[finish].tolist(),component=int(cc[y,x]),sector=sector,
            widthsPx=widths,outerDeltaE=delta,whiteRGB=observed,
            whiteXY=coords[bright+medoid].astype(int).tolist()))
    return dict(counts=dict(counts),records=records)


def summarize(scan, allowed=None):
    rows=[r for r in scan['records'] if allowed is None or r['component'] in allowed]
    by=defaultdict(set)
    for r in rows:by[r['component']].add(r['sector'])
    if not rows:return dict(profiles=0,components=0,opposing=0,sectors=0,support=0,
                            widthPx=None,widthMAD=None,coherence=0,raySupport=0,examples=[])
    widths=np.array([r['widthsPx'] for r in rows]);median=np.median(widths,axis=0)
    mad=np.quantile(np.abs(widths-median),.75,axis=0)
    support=len(rows)/max(1,scan['counts'].get('eligible',0))
    ray_support=len(rows)/max(1,scan['counts'].get('rays',0))
    colours=np.asarray([r['whiteRGB'] for r in rows]);centre=np.median(colours,axis=0)
    medoid=int(np.argmin(np.linalg.norm(colours-centre,axis=1)))
    observed=colours[medoid].tolist()
    return dict(profiles=len(rows),components=len(by),opposing=sum(({0,2}<=s or {1,3}<=s) for s in by.values()),
        sectors=len({r['sector'] for r in rows}),support=support,
        widthPx=median.tolist(),widthMAD=mad.tolist(),
        raySupport=ray_support,
        coherence=float(ray_support/(1+mad[1]/max(.5,median[1]))),
        whiteRGB=observed,
        whiteRGBWitnessXY=rows[medoid]['whiteXY'],
        examples=rows[:8])


def structural_gate(s, font):
    """Fixed before native inference: strong recurrence; no absolute colour role claim."""
    if s['profiles']<12 or s['components']<3 or s['opposing']<2 or s['sectors']<3:return False
    width=np.array(s['widthPx']);spread=np.array(s['widthMAD'])
    return bool(np.all(width>=.5) and width[1]<=max(3,font*.15)
                and np.all(spread<=np.maximum(.75,width*.5)))


def shifted(core, dx, dy):
    """Translate without wraparound or synthetic ownership at crop edges."""
    out=np.zeros_like(core);h,w=core.shape
    x0,x1=max(0,-dx),min(w,w-dx);y0,y1=max(0,-dy),min(h,h-dy)
    if x1>x0 and y1>y0:out[y0+dy:y1+dy,x0+dx:x1+dx]=core[y0:y1,x0:x1]
    return out
