"""Source-only mixed-weight protection before native text shaping.

An explicit same-call source context enables the frozen binary classifier.
Legacy callers retain qualified mixed protection until original evidence exists.
No font-weight GT, item IDs, or old predictions select a mixed result.
"""
import hashlib
from io import BytesIO
import math
from pathlib import Path
import sys

import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'font_weight_estimation'))
from line_weights import source_palette_qualifies,qualified_analyze

def estimate_page(items,source_path,source_sha256, *, source_context=None, weight_bundle=None):
    if (source_context is None) != (weight_bundle is None):
        raise ValueError('Binary source weight requires both same-call context and frozen bundle')
    if source_context is not None:
        from font_context_adapter import infer_context
        raw=Path(source_path).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=source_sha256:
            raise ValueError('Source weight image identity differs')
        with Image.open(BytesIO(raw)) as page:
            for packet,bounds in zip(source_context.packets,source_context.crop_bounds):
                if bounds is None or not np.array_equal(
                        np.asarray(page.crop(bounds).convert('RGB')),packet['rgb']):
                    raise ValueError('Source weight context RGB differs from source')
        predictions=infer_context(weight_bundle,source_context,items,source_sha256)
        if len(predictions)!=len(items):raise ValueError('Source weight prediction peer count differs')
        # Validate the whole batch before publishing any typography changes.
        for result in predictions:
            weight=result['sourceWeight']
            if weight not in ('regular','bold','mixed') or result['renderBold'] != (weight=='bold'):
                raise ValueError('Invalid source weight render policy')
        receipts=[]
        for item,result in zip(items,predictions):
            item['sourceFontWeight']=result['sourceWeight'];item['renderBold']=result['renderBold']
            item.pop('sourceWeightRuns',None)
            receipts.append(dict(result,id=item['id'],binaryBoldModelActivated=True,
                existingGlyphRFUsed=True,sameCallFontSignalsUsed=result.get('sameCallFontSignalsUsed',False),
                mixedRegularRenderingApplied=result['sourceWeight']=='mixed',
                GTWeightLabelsUsed=False,sourceOnlyFreshInference=True))
        return receipts
    qualified=[i for i,item in enumerate(items) if source_palette_qualifies(item.get('sourcePredictedStyle'))]
    if not qualified:return []
    raw=Path(source_path).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=source_sha256:raise ValueError('Source weight image identity differs')
    receipts=[]
    with Image.open(BytesIO(raw)) as page:
        for i in qualified:
            item=items[i];x,y,w,h=item['frame'];em=item['fontReference']
            if not all(math.isfinite(v) for v in [x,y,w,h,em]) or min(w,h,em)<=0:raise ValueError('Invalid source weight geometry')
            left=max(0,math.floor(x-.15*w));top=max(0,math.floor(y-.15*h));right=min(page.width,math.ceil(x+1.15*w));bottom=min(page.height,math.ceil(y+1.15*h))
            rgb=np.asarray(page.crop((left,top,right,bottom)).convert('RGB'))
            result=qualified_analyze(rgb,[x-left,y-top,w,h],em,item['sourcePredictedStyle'])
            mixed=result['sourceWeight']=='mixed'
            if mixed:
                item['sourceFontWeight']='mixed';item['renderBold']=False
                item['sourceWeightRuns']=[dict(lineID=r['lineID'],weight=r['weight'],frame=[r['boxInCrop'][0]+left,r['boxInCrop'][1]+top,*r['boxInCrop'][2:]]) for r in result['styleRuns']]
            receipts.append({'id':item['id'],'sourcePaletteQualified':True,'sourceWeight':result['sourceWeight'],
                             'mixedRegularRenderingApplied':mixed,'GTWeightLabelsUsed':False,'sourceOnlyFreshInference':True})
    return receipts
