"""Fresh antialiased stroke comparison using existing source glyph/RF outputs."""
import hashlib
import math
from pathlib import Path
import unicodedata

import cv2
import numpy as np

from color_consistent_ink import reconstruct
from ink_weight_geometry import clean_fill_style
from masked_word_pairs import locate
from optimized_features.templates import pose_angle, rotate
from palette_word_pairs import prepare_palette
from reference_grid import masks
from reference_ink_weight import fair_face_fits, reference_pairs
from soft_stroke_profile import profile
from soft_ink_rules import apply


def observe(packet, em, pairs, include_ordered=False):
    if packet is None or not packet.get('glyphEvidence'):
        raise ValueError('Soft source correction requires existing glyph/RF evidence')
    if not np.isfinite(em) or em <= 0:
        raise ValueError('Invalid soft source em')
    rgb = np.asarray(packet['rgb'])
    own = np.asarray(packet['ownership'], bool)
    style = packet['style']
    alpha, known, _ = reconstruct(rgb, own, style, packet['glyphEvidence'], em=em)
    families = {p['name']: p for p in reference_pairs(pairs)}
    clean = clean_fill_style(style)
    members = packet.get('wordMembers', [])[:6]
    words = []
    if clean is None:
        return dict(words=[], expectedWordCount=len(members))
    for member in members:
        x, y, w, h = member['bbox']
        if (not np.isfinite([x, y, w, h]).all() or min(w, h) <= 0
                or min(x, y) < 0 or x+w > rgb.shape[1]+1 or y+h > rgb.shape[0]+1):
            continue
        l, t = max(0, math.floor(x-.1*w)), max(0, math.floor(y-.1*h))
        r, b = min(rgb.shape[1], math.ceil(x+1.1*w)), min(rgb.shape[0], math.ceil(y+1.1*h))
        local = [x-l, y-t, w, h]
        angle = pose_angle(member['polygon']) if member.get('polygon') else 0.
        p = prepare_palette(rgb[t:b, l:r], local, em, member['text'], own[t:b, l:r], clean, angle)
        if p is None:
            continue
        source, valid = alpha[t:b, l:r], known[t:b, l:r]
        if abs(angle) > .1:
            source, _ = rotate(source, local, angle)
            valid, _ = rotate(valid.astype(np.uint8), local, angle, nearest=True)
        if source.shape != p['alpha'].shape:
            source = cv2.resize(source, (p['alpha'].shape[1], p['alpha'].shape[0]), interpolation=cv2.INTER_AREA)
            valid = cv2.resize(valid.astype(np.float32), (source.shape[1], source.shape[0]), interpolation=cv2.INTER_AREA) > .99
        yy, xx = np.nonzero((source > .5) & valid)
        if len(xx) < 5:
            continue
        spans = (yy.max()-yy.min()+1, xx.max()-xx.min()+1)
        p['long'], p['cross'] = spans if p['vertical'] else spans[::-1]
        p['alpha'], p['observed'] = source.astype(np.float32), valid.astype(bool)
        fits = fair_face_fits(p, pairs)
        if not fits:
            continue
        pose, winner, weight = max(fits, key=lambda v: v[0][18])
        text = p['text']
        if pose[26] < .999:
            while text and unicodedata.category(text[0])[0] in 'PS':
                text = text[1:]
            while text and unicodedata.category(text[-1])[0] in 'PS':
                text = text[:-1]
        images = masks(families[winner['name']], text, p['vertical'], pose[24])
        if images is None:
            continue
        a, heavy = transform_pair(images, pose, p)
        match = locate(source, valid, a, heavy)
        if match is None:
            continue
        _, _, _, mx, my = match
        sy, sx = slice(my, my+a.shape[0]), slice(mx, mx+a.shape[1])
        result = profile(source[sy, sx], a, heavy, valid[sy, sx], p['unit'])
        if include_ordered:
            from ordered_glyph_ink import measure as measure_ordered
            result['orderedGlyphs'] = measure_ordered(source, valid, p['text'], p['vertical'],
                                                       families[winner['name']], p['unit'], profile_fn=profile)
        words.append(dict(result, matchedWeight=weight, templateFit=float(pose[18]),
            normalTemplateMargin=float(pose[18])-max((float(v[0][18]) for v in fits if v[2] <= 400), default=0.),
            referenceFamily=winner['name']))
    return dict(words=words, expectedWordCount=len(members))


def transform_pair(images, pose, prepared):
    from word_pairs import transform
    return transform(*images, pose[22]*prepared['unit']/128, pose[23], pose[25]*4, prepared['vertical'])


def infer_page(packets, ems, predictions, pairs, policy):
    if not (len(packets) == len(ems) == len(predictions)):
        raise ValueError('Soft source peer count differs')
    for name, expected in policy['implementationSHA256'].items():
        if hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() != expected:
            raise ValueError('Soft measurement implementation changed: '+name)
    result = []
    for packet, em, prior in zip(packets, ems, predictions):
        score = prior.get('polarityRescueScore', 0.)
        if prior['sourceWeight'] != 'regular' or not math.isfinite(score) or score < policy['minimumExistingScore']:
            result.append(dict(prior, softInkRescueApplied=False, softSourceMeasured=False))
            continue
        result.append(dict(apply(observe(packet, em, pairs), prior, policy), softSourceMeasured=True))
    return result
