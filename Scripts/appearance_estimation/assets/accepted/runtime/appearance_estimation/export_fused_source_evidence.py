"""Export a source-only runtime payload from authenticated existing RF/OCR/pixel observations."""
import argparse
import json
from pathlib import Path
import sys
import numpy as np
from optimize_appearance import read,digest
from source_confidence_evidence import raster

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'segmentation'))
from source_boundary_votes import SourceBoundaryVotes
from prepare_full_rf import load_case_features


def main():
    ap=argparse.ArgumentParser()
    for key in ['source-root','source-packet','ocr-evidence','out']:ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args();packet=read(args.source_packet)
    source={k:packet['observation'][k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']}
    geometry={k:packet['geometry'][k] for k in ['polygons','mergedPolygon','fontPixels']}
    root=args.source_root;case=read(root/'boundary-lean/rf-full/crops'/(source['id']+'.json'))
    if case['sourceSHA256']!=packet['sourceImageSHA256'] or case['cropBounds']!=packet['cropBounds'] or case['pageSize']!=packet['pageSize']:
        raise ValueError('Source RF/original crop geometry mismatch')
    votes=SourceBoundaryVotes(root/'boundary-lean',root/'deep-classifier-observations',root/'edge-context60-native',root/'edge-context60-observations')
    primary,boundary,_=votes.load(source);rf=load_case_features(source,root/'boundary-lean')
    ocr=raster(args.ocr_evidence,packet['sourceImageSHA256'],packet['pageSize'],packet['cropBounds'])
    args.out.parent.mkdir(parents=True,exist_ok=True)
    np.savez_compressed(args.out,rf=rf.astype(np.float16),segPrimary=primary,segBoundary=boundary,ocr=ocr,
        sourceRGBSHA256=np.array(digest(packet['image'])),predictedMaskSHA256=np.array(digest(packet['mask'])),
        rfModelWeightsSHA256=np.array(case['modelWeightsSHA256']),geometryJSON=np.array(json.dumps(geometry,sort_keys=True)))
    print('Source evidence exported',rf.shape,'GT fields consumed: none',flush=True)


if __name__=='__main__':main()
