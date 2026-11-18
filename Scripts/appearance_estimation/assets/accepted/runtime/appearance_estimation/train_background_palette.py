"""Learn valid background palettes; GT text union is supervision/evaluation only."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import pickle
import shutil
import time
import numpy as np
import cv2
from PIL import Image
from optimize_appearance import read,save,split,assign_splits,digest
from source_appearance import lab
from background_palette import source_features,select,describe,VERSION
from sklearn.ensemble import HistGradientBoostingClassifier


def union_mask(row,neighbors,kind):
    x,y,right,bottom=row['cropBounds'];result=np.zeros((bottom-y,right-x),bool)
    for n in neighbors:
        a,b,c,d=n['cropBounds'];left=max(x,a);top=max(y,b);r=min(right,c);end=min(bottom,d)
        if left>=r or top>=end:continue
        mask=np.asarray(Image.open(n[kind]))>0
        result[top-y:end-y,left-x:r-x]|=mask[top-b:end-b,left-a:r-a]
    return result


def collect(payload):
    row,neighbors,feature_path,prediction,folder=payload
    path=Path(folder)/(row['itemID']+'.json')
    packet=read(feature_path)['packet']
    source_identity=read(feature_path)['identity']
    if digest(row['crop'])!=(source_identity.get('cropSHA256') or source_identity.get('sourceRGBSHA256')):
        raise ValueError('Source RGB changed since palette feature extraction')
    target_hashes=[digest(r['ownershipMask']) for r in neighbors]
    if any(h!=r['ownershipMaskSHA256'] for h,r in zip(target_hashes,neighbors)):
        raise ValueError('GT text mask changed without corresponding manifest update')
    identity=dict(version=VERSION,sourceFeatureSHA256=digest(feature_path),
        sourceInputs=[(r['cropBounds'],digest(r['predictedMask'])) for r in neighbors],
        targetInputs=[(r['cropBounds'],h) for r,h in zip(neighbors,target_hashes)],
        fillIndex=prediction['fillIndex'],outlineIndex=prediction['outlineIndex'])
    if path.exists():
        old=read(path)
        if old['identity']==identity:return old
    rgb=np.asarray(Image.open(row['crop']).convert('RGB'))
    own=np.asarray(Image.open(row['predictedMask']))>0
    source_union=union_mask(row,neighbors,'predictedMask')
    x,mass=source_features(rgb,own,source_union,packet,prediction)
    # Targets are constructed only AFTER all source features have been fixed.
    target_union=union_mask(row,neighbors,'ownershipMask')
    target_background=~target_union
    pixels=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    codes=np.zeros(own.shape,np.uint32);positive=[]
    for i,color in enumerate(lab(packet['colors'])):
        close=((pixels-color)**2).sum(2)<=100
        codes[close]|=np.uint32(1<<i)
        positive.append(int((close&target_background).sum())>=max(8,int(target_background.sum()*.002)))
    codes,counts=np.unique(codes[target_background],return_counts=True)
    output=dict(itemID=row['itemID'],identity=identity,x=x.tolist(),sourceMass=mass.tolist(),valid=positive,
        backgroundCodes=codes.tolist(),backgroundCounts=counts.tolist(),targetBackgroundPixels=int(target_background.sum()))
    save(path,output);return output


def evaluate(rows,packets,predictions,data,scores,threshold,max_colors,baseline=False):
    groups={}
    for group in ['train','dev','test','all']:
        correct=selected=0;coverage=[];weighted_total=weighted_covered=0;style=[];numbers=[]
        for r,p,q,d,s in zip(rows,packets,predictions,data,scores):
            if group!='all' and split(r)!=group:continue
            chosen=[q['backgroundIndex']] if baseline else select(p,q,np.array(d['sourceMass']),s,threshold,max_colors)
            selected+=len(chosen);correct+=sum(d['valid'][i] for i in chosen);numbers.append(len(chosen))
            bit=sum(1<<i for i in chosen);codes=np.array(d['backgroundCodes'],np.uint32);counts=np.array(d['backgroundCounts'])
            total=int(counts.sum());covered=int(counts[(codes&bit)>0].sum())
            if total:coverage.append(covered/total)
            weighted_total+=total;weighted_covered+=covered
            expected=r['background'].get('colors') or [r['background']['rgb']]
            error=np.linalg.norm(lab(expected)[:,None,:]-lab([p['colors'][i] for i in chosen])[None,:,:],axis=2).min(1)
            style.extend((error<=10).tolist())
        groups[group]=dict(selectedColourValidity=correct/max(1,selected),meanBackgroundPixelCoverage=float(np.mean(coverage)),
            microBackgroundPixelCoverage=weighted_covered/max(1,weighted_total),styleGTPaletteRecallWithin10=float(np.mean(style)),
            meanColours=float(np.mean(numbers)),selectedColours=selected)
    return groups


def main():
    parser=argparse.ArgumentParser()
    for k in ['gt','estimator','features','masks','out']:parser.add_argument('--'+k,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=8)
    parser.add_argument('--apply-to',type=Path)
    parser.add_argument('--search-offset',type=int,default=0)
    parser.add_argument('--min-colour-validity',type=float,default=.98)
    args=parser.parse_args();args.out.mkdir(exist_ok=True,parents=True);cache=args.out/'features';cache.mkdir(exist_ok=True)
    start=time.monotonic();rows=read(args.gt)['items'];assign_splits(rows)
    predictions=read(args.estimator/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in predictions]:raise ValueError('Estimator item correspondence mismatch')
    for r in rows:r['predictedMask']=str(args.masks/(r['itemID']+'.png'))
    by_page={}
    for r in rows:by_page.setdefault(r['page'],[]).append(r)
    allowed=['itemID','crop','cropBounds','ownershipMask','ownershipMaskSHA256','predictedMask']
    jobs=[]
    for r,q in zip(rows,predictions):
        x,y,a,b=r['cropBounds']
        neighbors=[{k:n[k] for k in allowed} for n in by_page[r['page']] if n['cropBounds'][0]<a and n['cropBounds'][2]>x and n['cropBounds'][1]<b and n['cropBounds'][3]>y]
        jobs.append(({k:r[k] for k in allowed},neighbors,str(args.features/(r['itemID']+'.json')),q,str(cache)))
    data=[]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for n,d in enumerate(pool.map(collect,jobs,chunksize=4),1):
            data.append(d)
            if n%500==0:print('background-palette-features',n,flush=True)
    packets=[read(args.features/(r['itemID']+'.json'))['packet'] for r in rows]
    train=[i for i,r in enumerate(rows) if split(r)=='train']
    x=np.concatenate([np.array(data[i]['x'],np.float32) for i in train]);y=np.concatenate([np.array(data[i]['valid'],int) for i in train])
    history=[];best=None;best_score=(-1,-1);best_statistics=None
    baseline=evaluate(rows,packets,predictions,data,[None]*len(rows),0,1,baseline=True)
    settings=[(7,100,10),(15,100,10),(23,100,10),(11,150,10),(23,150,5),(31,200,10),(7,200,20),(15,200,5),(31,100,20)]
    for offset in range(3):
        index=args.search_offset+offset;leaves,iterations,regularization=settings[index%len(settings)]
        classifier=HistGradientBoostingClassifier(max_leaf_nodes=leaves,max_iter=iterations,l2_regularization=regularization,
            early_stopping=False,random_state=71+index//len(settings))
        classifier.fit(x,y)
        bounds=np.r_[0,np.cumsum([len(d['x']) for d in data])]
        raw=classifier.predict_proba(np.concatenate([np.array(d['x'],np.float32) for d in data]))[:,1]
        scores=[raw[bounds[i]:bounds[i+1]] for i in range(len(rows))]
        for threshold in [.3,.5,.7,.85,.95]:
            for size in [3,5,8]:
                metrics=evaluate(rows,packets,predictions,data,scores,threshold,size)
                valid=metrics['dev']['selectedColourValidity']>=args.min_colour_validity
                score=(metrics['dev']['meanBackgroundPixelCoverage'],-metrics['dev']['meanColours'])
                history.append(dict(leaves=leaves,iterations=iterations,regularization=regularization,threshold=threshold,maxColors=size,metrics=metrics,valid=valid))
                if valid and score>best_score:
                    best_score=score;best=dict(classifier=classifier,threshold=threshold,maxColors=size,version=VERSION,
                        sourceFeatureVersion=packets[0]['version'],contextMask='union of available predicted text masks')
                    best_statistics=metrics
        print('background-palette-model',leaves,'best dev',best_score,flush=True)
    if best is None:raise ValueError('No palette meets DEV colour-validity requirement')
    with (args.out/'background-palette.pkl').open('wb') as f:pickle.dump(best,f)
    save(args.out/'RESULTS.json',dict(baseline=baseline,selected=best_statistics,history=history,seconds=time.monotonic()-start,
        originalPrimaryRGBChanged=False,GTAtInference=False,GTTextUnionUsedForSupervisionOnly=True,
        sparseStyleGTUnchanged=True,selection='DEV background-pixel coverage subject to observed-colour validity constraint',
        minimumDevColourValidity=args.min_colour_validity,
        metricScope='Surrounding non-text pixels; not clean background underneath removed glyphs',GTSHA256=digest(args.gt)))
    if args.apply_to:
        if args.apply_to.resolve()!=args.estimator.resolve():raise ValueError('Apply to the estimator used for source predictions')
        source=read(args.estimator/'predictions-with-width.json')
        if [p['itemID'] for p in source['items']]!=[r['itemID'] for r in rows]:raise ValueError('Width prediction correspondence mismatch')
        for p,packet,d,q in zip(source['items'],packets,data,predictions):
            if any(p[k]['rgb']!=q[k]['rgb'] for k in ['fill','outline','background']):raise ValueError('Estimator changed during palette calibration')
            p['background'].update(describe(packet,q,np.array(d['x'],np.float32),np.array(d['sourceMass']),best))
            p['background']['contextExclusionPolicy']='predicted-neighbor-text-union'
        save(args.apply_to/'predictions-with-width.json',source)
        temporary=args.apply_to/'background-palette.pkl.copying'
        shutil.copyfile(args.out/'background-palette.pkl',temporary);temporary.replace(args.apply_to/'background-palette.pkl')
        save(args.apply_to/'BACKGROUND-PALETTE-RESULTS.json',read(args.out/'RESULTS.json'))
    print('background-palette-result',best_statistics['test'],flush=True)


if __name__=='__main__':main()
