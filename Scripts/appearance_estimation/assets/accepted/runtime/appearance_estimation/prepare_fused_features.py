"""Build compact fused source features; RF/pixel arrays are never cached or copied per experiment."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import sys
import time
import numpy as np
from PIL import Image
from optimize_appearance import read,save,digest,assign_splits
from fused_source_appearance import extract,VERSION
from source_confidence_evidence import raster as ocr_raster

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'segmentation'))
from prepare_full_rf import load_case_features
from source_boundary_votes import SourceBoundaryVotes

VOTES=None


def initialize(root):
    global VOTES
    root=Path(root)
    VOTES=SourceBoundaryVotes(root/'boundary-lean',root/'deep-classifier-observations',root/'edge-context60-native',root/'edge-context60-observations')


def worker(job):
    geometry,source,root,base_features,masks,folder,ocr_folder=job
    root=Path(root);casepath=root/'boundary-lean/rf-full/crops'/(source['id']+'.json');case=read(casepath)
    if case['sourceSHA256']!=geometry['sourceImageSHA256'] or case['cropBounds']!=geometry['cropBounds'] or case['pageSize']!=geometry['pageSize']:
        raise ValueError('RF and original RGB geometry/source mismatch')
    native=(casepath.parent/case['nativeGrids']).resolve();path=Path(folder)/(geometry['itemID']+'.json')
    maskpath=Path(masks)/(geometry['itemID']+'.png');basepath=Path(base_features)/(geometry['itemID']+'.json')
    ocr_path=Path(ocr_folder)/(geometry['page']+'.json.gz')
    identity=dict(version=VERSION,implementationSHA256=digest(Path(__file__).with_name('fused_source_appearance.py')),
        sourceRGBSHA256=digest(geometry['crop']),OCRSourceSHA256=digest(ocr_path),
        polygons=geometry['individualPolygonsCrop'],mergedPolygon=geometry['mergedPolygonCrop'],fontPixels=geometry['fontPixels'],predictedMaskSHA256=digest(maskpath),basePacketSHA256=digest(basepath),
        RFCaseSHA256=digest(casepath),RFNativeSHA256=digest(native),RFModelWeightsSHA256=case['modelWeightsSHA256'],
        primaryClassifierSHA256=VOTES.primary_identity,boundaryClassifierSHA256=VOTES.boundary_identity)
    if identity['sourceRGBSHA256']!=geometry['cropSHA256']:raise ValueError('Original RGB changed')
    if path.exists():
        old=read(path)
        if old['identity']==identity:return old
    rgb=np.asarray(Image.open(geometry['crop']).convert('RGB'));mask=np.asarray(Image.open(maskpath))>0
    p,q,_=VOTES.load(source);rf=load_case_features(source,root/'boundary-lean')
    ocr=ocr_raster(ocr_path,geometry['sourceImageSHA256'],geometry['pageSize'],geometry['cropBounds'])
    packet=extract(rgb,mask,rf,p,q,geometry['individualPolygonsCrop'],geometry['fontPixels'],
        merged_polygon=geometry['mergedPolygonCrop'],ocr_maps=ocr)
    output=dict(itemID=geometry['itemID'],identity=identity,packet=packet);save(path,output);return output


def main():
    ap=argparse.ArgumentParser()
    for key in ['gt','source-root','base-features','masks','out','ocr-evidence']:ap.add_argument('--'+key,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args();folder=args.out/'features';folder.mkdir(exist_ok=True,parents=True)
    rows=read(args.gt)['items'];groups=assign_splits(rows);manifest=read(args.source_root/'boundary-lean/evaluation-manifest.json')
    allowed=['id','rgb','rf','width','height','polygons','fontPixels']
    sources={r['id']:{k:r[k] for k in allowed} for r in manifest['items']}
    fields=['itemID','page','mergedPolygonCrop','crop','cropSHA256','sourceImageSHA256','cropBounds','pageSize','individualPolygonsCrop','fontPixels']
    jobs=[({k:r[k] for k in fields},sources[r['itemID']],str(args.source_root),str(args.base_features),str(args.masks),str(folder),str(args.ocr_evidence)) for r in rows]
    start=time.monotonic();feature_count=None
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(str(args.source_root),)) as pool:
        for n,result in enumerate(pool.map(worker,jobs,chunksize=4),1):
            feature_count=len(result['packet']['features'][0])
            if n%250==0:print('fused RF/seg/bbox features',n,'/',len(rows),flush=True)
    save(args.out/'FUSION-SOURCE-POLICY.json',dict(version=VERSION,itemCount=len(rows),candidateFeatureCount=feature_count,
        groupedSplits=groups,sourceRFChannels=27,softSegmentationChannels=2,sourceOCRConfidenceChannels=8,exactMergedBBox=True,GTAtInference=False,
        GTColourUsedOnlyForLaterTrainingAndEvaluation=True,bboxHardClip=False,sourceContextMaxEachSide=.15,
        RFAndSoftPixelEvidenceDirectlyConsumed=True,wholePagesVisuallyOpened=False,
        featureArraysCached=False,sourceManifestSHA256=digest(args.source_root/'boundary-lean/evaluation-manifest.json'),seconds=time.monotonic()-start))
    print('Fusion source features complete',len(rows),feature_count,flush=True)


if __name__=='__main__':main()
