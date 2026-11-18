"""Operational source constructor: fresh masks -> appearance -> same-page font.

The native host supplies raw source crops and actual live RF/OCR arrays. There
are no corpus keys, localization manifests, stored observations or predictions.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

import numpy as np

from operational_appearance import OperationalAppearance


class SourceStyleRuntime:
    def __init__(self, *, mask_producer, appearance, font_bundle=None, weight_bundle=None, weight_identity=None):
        if (weight_bundle is None)!=(weight_identity is None) or (weight_bundle is not None and font_bundle is None):
            raise ValueError('Live weight inference requires authenticated weights and source-font inference')
        self.mask_producer = mask_producer
        self.appearance = appearance
        self.font_bundle = font_bundle
        self.weight_bundle = weight_bundle
        self.weight_identity = weight_identity

    @classmethod
    def from_workspace(cls, workspace, *, font_model=None, native_host=None):
        workspace = Path(workspace)
        scripts = workspace/'Aidoku/Scripts'
        sys.path.insert(0, str(scripts/'segmentation'))
        sys.path.insert(0, str(scripts/'font_size_estimation'))
        sys.path.insert(0, str(scripts/'font_weight_estimation'))
        from source_mask_runtime import SourceMaskProducer, SourceMaskRuntime
        final = SourceMaskRuntime(native_command=[native_host,'--segmentation-final-jsonl'] if native_host else None)
        producer = SourceMaskProducer(final_runtime=final)
        from estimator import load_model
        if font_model is None:
            font_model = os.environ.get('AIDOKU_SOURCE_FONT_MODEL')
        if font_model is None:
            from active_model import resolve_default_model
            font_model = resolve_default_model()
        bundle = load_model(Path(font_model))
        if not bundle.get('optimizedGraph'):
            raise ValueError('Operational source style requires the accepted optimized font graph; activate it or set AIDOKU_SOURCE_FONT_MODEL')
        weight_bundle=weight_identity=None
        if (scripts/'font_weight_estimation/ACTIVE-ESTIMATOR.json').exists():
            from active_weight_model import load_accepted_model
            weight_bundle,weight_identity=load_accepted_model()
        return cls(mask_producer=producer, appearance=OperationalAppearance(), font_bundle=bundle,
                   weight_bundle=weight_bundle, weight_identity=weight_identity)

    def construct_page(self, packets, *, page_size, source_identity, capture=None):
        """Packets contain source RGB/RF/OCR, member polygons and source prior.

        All owners are segmented before background context and styles are
        computed. Font clustering receives every packet under one source group.
        Returned sourceFontSize is an original-page pixel measurement.
        """
        if len(packets) > 4096 or sum(p['rgb'].shape[0]*p['rgb'].shape[1] for p in packets) > 32_000_000:
            raise ValueError('Source page constructor budget exceeded')
        segmented = []
        for p in packets:
            geometry = p['geometry']
            mask, audit, trace = self.mask_producer.predict(rgb=p['rgb'], polygons=geometry['polygons'],
                font=geometry['fontPixels'], coarse_rf=p['coarseRF'], full_rf=p['rf'], affinity=p['affinity'],
                rf_model_weights_sha256=p['rfModelWeightsSHA256'])
            segmented.append((mask, audit, trace))
        results, measured = [], []
        for index, (p, (mask, mask_audit, trace)) in enumerate(zip(packets, segmented)):
            x, y = p['cropOrigin'];h, w = mask.shape
            context = mask.copy()
            for peer, (other, _, _) in zip(packets, segmented):
                ox, oy = peer['cropOrigin'];oh, ow = other.shape
                left, top, right, bottom = max(x, ox), max(y, oy), min(x+w, ox+ow), min(y+h, oy+oh)
                if left < right and top < bottom:
                    np.maximum(context[top-y:bottom-y, left-x:right-x],
                               other[top-oy:bottom-oy, left-ox:right-ox],
                               out=context[top-y:bottom-y, left-x:right-x])
            result = self.appearance.estimate(rgb=p['rgb'], mask=mask, context_mask=context,
                rf=p['rf'], primary=trace['primary'], boundary=trace['boundary'], ocr=p['ocr'],
                geometry=p['geometry'], rf_model_weights_sha256=p['rfModelWeightsSHA256'])
            result['sourceMaskAudit'] = mask_audit
            result['sourceMemberPolygonsCrop'] = p['geometry']['polygons']
            result['sourceMemberPolygons'] = [[[px+x,py+y] for px,py in polygon] for polygon in p['geometry']['polygons']]
            result['sourcePredictedStyle'] = result['prediction']
            if capture is not None:
                arrays=dict(mask=(mask>0).astype(np.uint8), context=(context>0).astype(np.uint8),
                            segPrimary=trace['primary'], segBoundary=trace['boundary'], ocr=p['ocr'])
                if self.weight_bundle is not None:
                    arrays.update(segNative=trace['rawNative'], segValid=trace['observationValid'].astype(np.uint8))
                capture(index, arrays)
            if self.font_bundle is not None:
                from optimized_runtime import measure_packet
                bbox = p['bbox']
                measured.append(measure_packet(self.font_bundle, p['rgb'], bbox, p['geometry']['fontPixels'],
                    p['sourceText'], mask > 0, page_size,
                    [(x+bbox[0]+bbox[2]/2)/page_size[0], (y+bbox[1]+bbox[3]/2)/page_size[1]],
                    source_identity, p.get('confidence'), p.get('role'), style=result['prediction'],
                    member_polygons=p['geometry']['polygons']))
            results.append(result)
        if measured:
            from optimized_runtime import infer_packets
            values = infer_packets(self.font_bundle, measured, groups=[source_identity]*len(measured))
            for result, value in zip(results, values):
                if not np.isfinite(value) or value <= 0:
                    raise ValueError('Source font graph emitted invalid source em')
                result['sourceFontSize'] = float(value)
                result['sourceFontAuthority'] = 'fresh-source-optimized-graph;original-page-pixels;same-page-group'
        if self.weight_bundle is not None:
            if self.font_bundle is None or len(measured)!=len(packets):
                raise ValueError('Live source weight requires complete fresh font packets')
            from live_weight_context import infer_live_page
            weights=infer_live_page(self.weight_bundle,self.font_bundle,measured,packets,segmented,
                                   page_size=page_size,source_identity=source_identity)
            for result,p,(_,_,trace),weight in zip(results,packets,segmented,weights):
                label=weight['sourceWeight']
                if label not in ('regular','bold','mixed') or weight['renderBold']!=(label=='bold'):
                    raise ValueError('Invalid live source weight render policy')
                result.update(sourceFontWeight=label,renderBold=weight['renderBold'],sourceWeightEvidence=weight)
                def digest(value):return hashlib.sha256(np.asarray(value).tobytes()).hexdigest()
                result['sourceWeightBinding']=dict(sourceIdentity=source_identity,rgbSHA256=digest(p['rgb']),
                    rfSHA256=digest(p['rf']),segPrimarySHA256=digest(trace['primary']),segBoundarySHA256=digest(trace['boundary']),
                    segNativeSHA256=digest(trace['rawNative']),segValidSHA256=digest(trace['observationValid'].astype(np.uint8)),
                    modelSHA256=self.weight_identity['storedSHA256'])
        return results


def live_ocr_maps(evidence, *, page_size, crop_origin, shape):
    """Raster only current source OCR observations, with explicit availability."""
    import cv2
    h, w = shape;x, y = crop_origin
    output = np.zeros((h, w, 8), np.float32)
    for key, rows_key, normalized, kind in [('originalOCR', 'regions', True, 'rec'),
                                          ('originalDetector', 'boxes', False, 'det')]:
        rows = evidence.get(key, {}).get(rows_key, [])
        for row in rows:
            polygon = np.asarray(row.get('polygon', []), np.float64)
            if polygon.ndim != 2 or polygon.shape[1] != 2 or len(polygon) < 3:
                continue
            if normalized:
                polygon = polygon * np.asarray(page_size)
            support = np.zeros((h,w), np.uint8)
            cv2.fillPoly(support, [np.rint(polygon-[x,y]).astype(np.int32)], 1)
            values = np.zeros(8, np.float32);values[0] = 1
            confidence = row.get('confidence')
            if confidence is not None:
                if not np.isfinite(confidence) or not 0 <= confidence <= 1:
                    raise ValueError('Invalid live OCR confidence')
                values[1 if kind == 'det' else 3] = 1
                values[2 if kind == 'det' else 4] = confidence
            token = row.get('recTokensAvailable', False)
            if token:
                values[5:] = [1, row['recMinTokenConfidence'], row['recMeanTokenConfidence']]
            np.maximum(output, support[:,:,None]*values, out=output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        raise ValueError('Live constructor output must be new')
    request = json.loads(args.request.read_text())
    if request['schema'] != 'aidoku-live-source-page-v1':
        raise ValueError('Unknown live source constructor schema')
    runtime = SourceStyleRuntime.from_workspace(args.workspace, native_host=request['nativeHost'])
    packets=[]
    for row in request['items']:
        h,w=row['height'],row['width']
        packet=dict(row)
        packet['rgb']=np.fromfile(row['rgb'], np.uint8).reshape(h,w,3)
        packet['rf']=np.fromfile(row['rf'], np.float32).reshape(h,w,27)
        packet['coarseRF']=np.fromfile(row['coarseRF'], np.float32).reshape(h,w,4)
        packet['ocr']=live_ocr_maps(request['sourceEvidence'], page_size=request['pageSize'],
                                  crop_origin=row['cropOrigin'], shape=(h,w))
        packets.append(packet)
    def capture(index, arrays):
        for name, array in arrays.items():
            np.asarray(array).tofile(args.out.parent / (str(index)+'-'+name+'.raw'))
        from operational_appearance import canonical
        (args.out.parent/(str(index)+'-geometry.json')).write_bytes(canonical(packets[index]['geometry']))
    results=runtime.construct_page(packets, page_size=request['pageSize'], source_identity=request['sourceIdentity'], capture=capture)
    with args.out.open('x') as handle:
        json.dump(dict(schema='aidoku-live-source-page-result-v1', items=results), handle, allow_nan=False)


if __name__=='__main__':
    main()
