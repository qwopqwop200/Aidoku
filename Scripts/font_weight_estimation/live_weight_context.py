"""Bind actual live host observations to the accepted source-weight consumer."""
import hashlib
import numpy as np

from font_context_adapter import infer_context
from source_font_context import SourceFontObservations


def infer_live_page(weight_bundle, font_bundle, measured, packets, segmented, *, page_size, source_identity):
    from optimized_runtime import infer_packets
    if not (len(measured) == len(packets) == len(segmented)):
        raise ValueError('Live source weight peer count differs')
    observations, normalized = [], []
    for index, (font_packet, packet, (_, _, trace)) in enumerate(zip(measured, packets, segmented)):
        rgb = np.asarray(packet['rgb']); h, w = rgb.shape[:2]
        x, y = packet['cropOrigin']; bounds = [x, y, x+w, y+h]
        valid = np.asarray(trace['observationValid'])
        if valid.shape != (h, w) or valid.dtype != bool or not valid.any():
            raise ValueError('Live source weight observation coverage is missing')
        common = dict(sourceSHA256=source_identity, GTMaskUsed=False, cropBounds=bounds, rgb=rgb,
                      sourceRGBSHA256=hashlib.sha256(rgb.tobytes()).hexdigest(), valid=valid)
        glyph = dict(common, primary=trace['primary'], boundary=trace['boundary'], native=trace['rawNative'])
        rf = dict(common, rf=packet['rf'], rfModelWeightsSHA256=packet['rfModelWeightsSHA256'])
        words = []
        # Only the producer's original recognized records; no paragraph splitting.
        if 'wordMembers' not in packet:
            raise ValueError('Original live word records must be supplied (empty is valid)')
        for record in packet['wordMembers']:
            if not record.get('text'):
                continue
            b = np.asarray(record['bbox'], float)
            if b.shape != (4,) or not np.isfinite(b).all() or min(b[2:]) <= 0:
                raise ValueError('Invalid live original word bbox')
            if min(b[:2]) < 0 or b[0]+b[2] > w+1 or b[1]+b[3] > h+1:
                continue
            words.append(dict(record, sourceSHA256=source_identity, coordinateSpace='crop', cropBounds=bounds))
        observations.append(SourceFontObservations(original_word_members=words, glyph_arrays=glyph, rf_arrays=rf))
        # Renderer font geometry remains unchanged. This independently measured
        # source-only normalization context uses the verified bbox font contract.
        normalized.append(dict(font_packet, memberPolygons=[], cropOrigin=[x,y], cropBounds=bounds,
                               sourceRegionID=str(index), sourceOrder=index))
    ems, context = infer_packets(font_bundle, normalized, groups=[source_identity]*len(normalized),
                                return_context=True, source_observations=observations)
    items = []
    for index, (p, em) in enumerate(zip(packets, ems)):
        x, y = p['cropOrigin']; bx, by, bw, bh = p['bbox']
        items.append(dict(id=str(index), frame=[x+bx,y+by,bw,bh], fontReference=float(em)))
    return infer_context(weight_bundle, context, items, source_identity)
