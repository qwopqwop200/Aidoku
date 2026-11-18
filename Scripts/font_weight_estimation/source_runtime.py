"""Fresh bounded-crop frontend for the experimental source-weight classifier.

Packets are the source-font graph's pixel packets, never annotation rows.
The caller must supply every peer region from ONE page, preserving the model's
same-page context contract. This module neither loads GT nor activates a model.
"""
import cv2
import numpy as np

from features import measure
from pixel_rules import observe
from physical_templates import measure as paired_measure
from line_weights import qualified_analyze
from runtime import predict_page, predict_complementary_page, predict_band_page
from fill_body import measure as measure_fill
from optimized_measurements import _font_paths
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.geometry import geometry_style_features
from optimized_features.templates import (
    fill_templates, pose_angle, prepare_alpha, style_residuals,
)

DIRECT_KEYS = (
    'quality', 'glyphCount', 'bodyThickness', 'thinStroke',
    'broadStroke', 'hollowFraction', 'occupancy',
)
PAIRED_SCALES = (.85, .95, 1., 1.05, 1.15)


def _validate(packet, final_em):
    rgb = np.asarray(packet['rgb'])
    bbox = np.asarray(packet['bbox'], float)
    prior = float(packet['prior'])
    own = np.asarray(packet['ownership'])
    if rgb.ndim != 3 or rgb.shape[2] != 3 or rgb.dtype != np.uint8:
        raise ValueError('Expected source RGB uint8 crop')
    if (bbox.shape != (4,) or not np.isfinite(bbox).all()
            or min(bbox[2:]) <= 0 or not np.isfinite([prior, final_em]).all()
            or min(prior, final_em) <= 0):
        raise ValueError('Invalid source font geometry')
    if (own.shape != rgb.shape[:2] or not np.isfinite(own).all()
            or not isinstance(packet.get('style'), dict)):
        raise ValueError('Predicted ownership and source style are required')
    x, y, w, h = bbox
    # Integer crop rounding may expose up to one additional pixel per side.
    margins = (x, y, rgb.shape[1] - x - w, rgb.shape[0] - y - h)
    if (min(margins) < -1e-6
            or any(m > .15 * size + 1.000001
                   for m, size in zip(margins, (w, h, w, h)))):
        raise ValueError('Source crop exceeds 15% context or clips target')
    return rgb, bbox, prior, own.astype(bool)


def _legacy_residual(packet, rgb, bbox, prior, own, fonts, native_fonts):
    polygons = packet.get('memberPolygons')
    if not polygons:
        x, y, w, h = bbox
        polygons = [[[x, y], [x+w, y], [x+w, y+h], [x, y+h]]]
    _, physical = geometry_style_features(polygons, packet['style'], prior)
    oriented = float(physical[3])
    if not np.isfinite(oriented) or oriented <= 0:
        raise ValueError('Invalid oriented source geometry')
    requested = prior / oriented >= 1.1 and bool(packet.get('memberPolygons'))
    polygon = max(polygons, key=lambda p: np.max(cv2.minAreaRect(np.asarray(p, np.float32))[1]))
    angle = pose_angle(polygon) if requested else 0.
    alpha = predicted_fill_alpha(rgb, bbox, own, packet['style'])
    complete, unit, _ = prepare_alpha(alpha, bbox, oriented, angle=angle, complete=True)
    native = fill_templates(complete, unit, prior, oriented, packet['text'], native_fonts, fonts[0])
    return style_residuals(alpha, bbox, angle, packet['text'], fonts[0], native_fonts, native, prior)


def _source_angle(packet):
    polygons=packet.get('memberPolygons')
    if not polygons:return 0.
    _,physical=geometry_style_features(polygons,packet['style'],packet['prior'])
    oriented=float(physical[3])
    if not np.isfinite(oriented) or oriented<=0:raise ValueError('Invalid source pose geometry')
    if packet['prior']/oriented<1.1:return 0.
    polygon=max(polygons,key=lambda p:np.max(cv2.minAreaRect(np.asarray(p,np.float32))[1]))
    return pose_angle(polygon)


def measure_page(packets, final_source_ems, measurement_spec, *, fresh_font_signals=None):
    """Return raw866, paired48, styles, mixed flags; no file/ID lookup.

    Reuse style187 only from the SAME fresh font-graph call and packet order.
    Otherwise the exact legacy residual is remeasured from the source pixels.
    OCR prior normalizes raw597/direct7; final estimated em normalizes paired48.
    """
    packets = list(packets)
    ems = np.asarray(final_source_ems, float)
    if ems.shape != (len(packets),):
        raise ValueError('Source em batch differs')
    if len({p.get('sourceHash') for p in packets}) > 1:
        raise ValueError('Weight peer context requires one source page')
    legacy = None
    if fresh_font_signals is not None:
        legacy = np.asarray(fresh_font_signals['style187'], float)
        if legacy.shape != (len(packets), 262) or not np.isfinite(legacy).all():
            raise ValueError('Fresh style187 contract differs')
    fonts = native_fonts = None
    if packets and legacy is None:
        fonts = _font_paths(measurement_spec, 'fonts', 4)
        native_fonts = _font_paths(measurement_spec, 'nativeFonts', 4)
    raw, paired, styles, mixed = [], [], [], []
    for i, (packet, em) in enumerate(zip(packets, ems)):
        rgb, bbox, prior, own = _validate(packet, em)
        text = packet['text']
        residual = (legacy[i] if legacy is not None else
                    _legacy_residual(packet, rgb, bbox, prior, own, fonts, native_fonts))
        direct = observe(rgb, bbox, prior)
        raw.append(np.r_[measure(rgb, bbox, prior, text),
                         [direct[k] for k in DIRECT_KEYS], residual])
        paired.append(paired_measure(rgb, bbox, em, text, scales=PAIRED_SCALES))
        styles.append(packet['style'])
        mixed.append(qualified_analyze(rgb, bbox, em, packet['style'])['sourceWeight'] == 'mixed')
    raw = np.asarray(raw, float).reshape(-1, 866)
    paired = np.asarray(paired, float).reshape(-1, 48)
    if not np.isfinite(raw).all() or not np.isfinite(paired).all():
        raise ValueError('Non-finite source weight measurements')
    return raw, paired, styles, np.asarray(mixed, bool)


def infer_page(bundle, packets, final_source_ems, measurement_spec, *, fresh_font_signals=None,
               measurement_observer=None):
    packets=list(packets)
    legacy=bands=None
    raw, paired, styles, mixed = measure_page(
        packets, final_source_ems, measurement_spec, fresh_font_signals=fresh_font_signals)
    if bundle.get('sourceComplementaryHeads') or bundle.get('sourceBandHeads'):
        legacy=np.array([measure_fill(p['rgb'],p['bbox'],em,p['ownership'],p['style'],version=1)
                         for p,em in zip(packets,final_source_ems)]).reshape(-1,71)
        if bundle.get('sourceBandHeads'):
            from weight_bands import measure as measure_bands
            angles=(fresh_font_signals or {}).get('angles131')
            if angles is None:angles=[_source_angle(p) for p in packets]
            angles=np.asarray(angles,float)
            if angles.shape!=(len(packets),) or not np.isfinite(angles).all():raise ValueError('Invalid source angle batch')
            bands=np.array([measure_bands(p['rgb'],p['bbox'],em,p['text'],p['ownership'],
                                         p['style'],bundle['referencePairs'],angle)
                            for p,em,angle in zip(packets,final_source_ems,angles)]).reshape(-1,bundle['bandFeatureCount'])
            result = predict_band_page(bundle,raw,legacy,styles,paired,bands,mixed)
        else:
            result = predict_complementary_page(bundle,raw,legacy,styles,paired,mixed)
    else:
        result = predict_page(bundle, raw, styles, paired, mixed)
    policy = bundle.get('directionalInkPolicy')
    if policy is not None:
        from directional_ink_rules import measure_source_page, apply_page
        observed = measure_source_page(packets, final_source_ems, policy)
        result = apply_page(observed, result, policy)
    reference_policy = bundle.get('referenceInkPolicy')
    if reference_policy is not None:
        from reference_ink_source import infer_page as reference_infer_page
        result = reference_infer_page(packets, final_source_ems, result,
                                      bundle['referenceInkPairs'], reference_policy)
    for extra_policy in bundle.get('referenceInkAdditionalPolicies', []):
        from reference_ink_source import infer_page as reference_infer_page
        result = reference_infer_page(packets, final_source_ems, result,
                                      bundle['referenceInkPairs'], extra_policy)
    soft_policy = bundle.get('softInkPolicy')
    if soft_policy is not None:
        from soft_ink_source import infer_page as soft_infer_page
        result = soft_infer_page(packets, final_source_ems, result, bundle['referenceInkPairs'], soft_policy)
    ordered_policy = bundle.get('orderedInkPolicy')
    if ordered_policy is not None:
        from ordered_ink_source import infer_page as ordered_infer_page
        result = ordered_infer_page(packets, final_source_ems, result, bundle['referenceInkPairs'], ordered_policy)
    # Same-call, read-only handoff after all decisions. No archived features or
    # measurements from a different geometry/normalization can enter this path.
    if measurement_observer is not None:
        measurement_observer(dict(raw=raw,paired=paired,styles=styles,mixed=mixed,
                                  fill71=legacy,bands=bands))
    return result
