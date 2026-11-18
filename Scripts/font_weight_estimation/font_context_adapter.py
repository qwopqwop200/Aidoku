"""Bind same-call font packets to authenticated original model observations.

No cache discovery, GT fields, paragraph splitting, or new model execution.
Array records carry page-space cropBounds and SHA256 of their RGB bytes.
Original word records explicitly declare page or crop coordinates and source hash.
"""
import hashlib

import numpy as np

from existing_glyph_evidence import align_array


def _bounds(value):
    bounds = np.asarray(value, float)
    if (bounds.shape != (4,) or not np.isfinite(bounds).all()
            or not np.equal(bounds, np.floor(bounds)).all()
            or min(bounds[:2]) < 0 or min(bounds[2:] - bounds[:2]) <= 0):
        raise ValueError('Invalid model observation crop bounds')
    return tuple(map(int, bounds))


def _record(record, packet, target_bounds, names):
    if record is None:
        raise ValueError('Original glyph/RF observations are required')
    if record.get('sourceSHA256') != packet['sourceHash'] or record.get('GTMaskUsed') is not False:
        raise ValueError('Model observation source identity differs or is not source-only')
    bounds = _bounds(record['cropBounds'])
    rgb = np.asarray(record['rgb'])
    shape = (bounds[3]-bounds[1], bounds[2]-bounds[0])
    if rgb.dtype != np.uint8 or rgb.shape != (*shape, 3):
        raise ValueError('Model observation RGB geometry differs')
    if hashlib.sha256(rgb.tobytes()).hexdigest() != record['sourceRGBSHA256']:
        raise ValueError('Model observation RGB identity differs')
    aligned_rgb, valid = align_array(rgb, bounds, target_bounds)
    if not valid.any() or not np.array_equal(aligned_rgb[valid], packet['rgb'][valid]):
        raise ValueError('Model observation/source crop pixels differ')
    original_valid = np.asarray(record['valid'])
    if original_valid.shape != shape or original_valid.dtype != bool:
        raise ValueError('Model observation valid map differs')
    result = {}
    for name in names:
        value = np.asarray(record[name])
        expected = (*shape, 27) if name == 'rf' else shape
        if value.shape != expected or not np.isfinite(value).all():
            raise ValueError('Model observation tensor differs: '+name)
        if name in ('primary', 'boundary') and ((value < 0).any() or (value > 1).any()):
            raise ValueError('Glyph probability range differs')
        if name == 'native' and not np.isin(value, (0, 1, 255)).all():
            raise ValueError('Native glyph mask range differs')
        result[name], _ = align_array(value, bounds, target_bounds)
    return result, valid & align_array(original_valid, bounds, target_bounds)[0]


def _words(members, packet, bounds):
    result = []
    height, width = packet['rgb'].shape[:2]
    for member in members:
        if member.get('sourceSHA256') != packet['sourceHash']:
            raise ValueError('Original word source identity differs')
        text, index = member.get('text'), member.get('sourceIndex')
        if not isinstance(text, str) or not text or not isinstance(index, int) or index < 0:
            raise ValueError('Original word recognition association is missing')
        polygon = np.asarray(member['polygon'], float)
        bbox = np.asarray(member['bbox'], float)
        if (polygon.ndim != 2 or polygon.shape[1:] != (2,) or len(polygon) < 3
                or bbox.shape != (4,) or not np.isfinite(polygon).all()
                or not np.isfinite(bbox).all() or min(bbox[2:]) <= 0):
            raise ValueError('Invalid original word geometry')
        lo, hi = polygon.min(0), polygon.max(0)
        if not np.allclose(bbox, np.r_[lo, hi-lo], atol=1., rtol=0):
            raise ValueError('Original word bbox/polygon association differs')
        space = member.get('coordinateSpace')
        if space == 'page':
            origin = np.asarray(bounds[:2])
        elif space == 'crop':
            member_bounds = _bounds(member['cropBounds'])
            origin = np.asarray(bounds[:2]) - np.asarray(member_bounds[:2])
        else:
            raise ValueError('Original word coordinate space is missing')
        polygon = polygon - origin
        lo, hi = polygon.min(0), polygon.max(0)
        if min(lo) < 0 or hi[0] > width+1 or hi[1] > height+1:
            raise ValueError('Original word is outside source crop')
        result.append(dict(text=text, sourceIndex=index, polygon=polygon.tolist(),
                           bbox=np.r_[lo, hi-lo].tolist()))
    return result


def packets_from_context(context, items, source_hash):
    """Keep every same-page peer and original prior; final em stays separate."""
    count = len(items)
    if (len(context.packets) != count or context.packet_order != tuple(range(count))
            or len(context.crop_bounds) != count or len(context.source_observations) != count
            or np.shape(context.original_priors) != (count,)
            or np.shape(context.final_source_ems) != (count,)):
        raise ValueError('Source weight context peer order differs')
    packets = []
    for i, (packet, item, observation, crop) in enumerate(zip(
            context.packets, items, context.source_observations, context.crop_bounds)):
        if (packet.get('sourceHash') != source_hash or packet.get('sourceRegionID') != item['id']
                or packet.get('sourceOrder') != i):
            raise ValueError('Source weight context item identity differs')
        bounds = _bounds(crop)
        x, y, w, h = packet['bbox']
        if (not np.allclose(item['frame'], [x+bounds[0], y+bounds[1], w, h], atol=1e-6, rtol=0)
                or packet['prior'] != context.original_priors[i]
                or not np.isclose(item['fontReference'], context.final_source_ems[i], rtol=0, atol=1e-6)):
            raise ValueError('Source weight context geometry or em differs')
        if observation is None or observation.original_word_members is None:
            raise ValueError('Original word observations must be supplied (empty is valid)')
        glyph, valid = _record(observation.glyph_arrays, packet, bounds, ('primary', 'boundary', 'native'))
        rf, rf_valid = _record(observation.rf_arrays, packet, bounds, ('rf',))
        rf_hash = observation.rf_arrays.get('rfModelWeightsSHA256')
        if not isinstance(rf_hash, str) or len(rf_hash) != 64:
            raise ValueError('RF model identity is missing')
        evidence = dict(glyph, **rf, valid=valid & rf_valid, sourceSHA256=source_hash,
                        GTMaskUsed=False, donor='same-call', rfModelWeightsSHA256=rf_hash)
        words = _words(observation.original_word_members, packet, bounds)
        # The accepted weight residual uses original recognized-word geometry.
        # Keep it separate from the font estimator's caller-supplied geometry.
        packets.append(dict(packet, wordMembers=words, glyphEvidence=evidence,
                            memberPolygons=[word['polygon'] for word in words]))
    return packets


def weight_signals(context, packets):
    from source_runtime import _legacy_residual, _source_angle, _font_paths
    residual=np.asarray(context.fresh_font_signals['style187'],float).copy()
    angles=np.asarray(context.fresh_font_signals['angles131'],float).copy()
    if residual.shape!=(len(packets),262) or angles.shape!=(len(packets),):
        raise ValueError('Fresh source font residual shape differs')
    reused=[];fonts=native_fonts=None
    for i,(original,weight) in enumerate(zip(context.packets,packets)):
        old=original.get('memberPolygons') or []
        new=weight['memberPolygons']
        matches=len(old)==len(new) and all(np.shape(a)==np.shape(b) and
            np.allclose(a,b,atol=1e-6,rtol=0) for a,b in zip(old,new))
        reused.append(matches)
        if matches:continue
        if fonts is None:
            fonts=_font_paths(context.measurement_spec,'fonts',4)
            native_fonts=_font_paths(context.measurement_spec,'nativeFonts',4)
        residual[i]=_legacy_residual(weight,weight['rgb'],weight['bbox'],weight['prior'],
            np.asarray(weight['ownership'],bool),fonts,native_fonts)
        angles[i]=_source_angle(weight)
    return (context.fresh_font_signals if all(reused) else
            dict(style187=residual,angles131=angles)),reused


def infer_context(bundle, context, items, source_hash):
    from source_runtime import infer_page
    from font_context_scale import refine_page
    from font_context_bounds import refine_page as refine_bounds
    from font_context_soft import refine_page as refine_soft
    packets = packets_from_context(context, items, source_hash)
    # Empty pages have no measured signal arrays; do not fabricate style187 or
    # ask the nonempty classifier measurement API to consume an empty context.
    if not packets:
        return []
    signals,reused=weight_signals(context,packets)
    observations={}
    predictions = infer_page(bundle, packets, context.final_source_ems, context.measurement_spec,
                             fresh_font_signals=signals,measurement_observer=observations.update)
    predictions=refine_soft(bundle,packets,context.final_source_ems,predictions)
    predictions=refine_bounds(bundle,packets,context.final_source_ems,signals,observations,predictions)
    predictions=refine_page(bundle, packets, context.final_source_ems, predictions)
    return [dict(result,sameCallFontSignalsUsed=bool(reuse),
                 sourceWeightResidualRemeasured=not reuse) for result,reuse in zip(predictions,reused)]
