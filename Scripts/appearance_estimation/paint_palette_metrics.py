"""All annotated fill colours, including substyles, count in palette evaluation."""
import numpy as np
from source_appearance import lab

def targets(row):
    colours=list(row['fill'].get('colors') or [row['fill']['rgb']])
    for style in row.get('substyles') or []:
        fill=style.get('fill') or {};colours+=fill.get('colors') or ([fill['rgb']] if fill.get('rgb') else [])
    return list(dict.fromkeys(tuple(c) for c in colours if c is not None))


def measure(rows,predictions,palettes):
    matched=total=valid=count=complete=multi_complete=multi_count=0
    for r,p,extra in zip(rows,predictions,palettes):
        gt=targets(r);colours=[p['fill']['rgb']]+[b['rgb'] for b in extra]
        distances=np.linalg.norm(lab(gt)[:,None,:]-lab(colours)[None,:,:],axis=2)
        hits=distances.min(1)<=10;matched+=int(hits.sum());total+=len(gt)
        valid+=int((distances.min(0)<=10).sum());count+=len(colours);complete+=bool(hits.all())
        if len(gt)>1:multi_count+=1;multi_complete+=bool(hits.all())
    return dict(regions=len(rows),targetColours=total,coveredColours=matched,colourRecall=matched/max(1,total),
        emittedColours=count,validColours=valid,annotatedColourPrecision=valid/max(1,count),
        allColoursCoveredRegions=complete,multicolourRegions=multi_count,allColoursCoveredMulticolour=multi_complete)



def predicted_colours(prediction):
    fill=prediction['fill']
    if fill.get('representation')=='source-fusion-observed-palette':
        return [dict(rgb=c) for c in fill['colors'][1:]]
    return prediction.get('pixelRoleEvidence',{}).get('roles',{}).get('fill',{}).get('observedColours',[])
