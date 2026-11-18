"""Reject a whole-word soft rescue contradicted by its independent glyphs.

Use the existing source segmentation/RF reconstruction and ordered reference
matcher. Only complete, reliable glyph observations can veto; absence of a
match is not regular evidence. Frozen policy floors supply the fit/support
requirements. No learned weights, lexical rules or display-em changes.
"""
import math

from features import render_policy
from ordered_ink_rules import expected_counts
from soft_ink_source import observe


def regular_glyph_agreement(observation, counts, policy):
    words = observation.get('words', [])
    if not words or len(words) != len(counts):
        return False
    for word, count in zip(words, counts):
        glyphs = word.get('orderedGlyphs', {}).get('glyphs', [])
        if count < policy['minimumIndependentGlyphs'] or len(glyphs) != count:
            return False
        for glyph in glyphs:
            for key, floor in (('templateFit', policy['minimumGlyphFit']),
                               ('referenceKnownSupport', policy['minimumKnownSupport'])):
                value = glyph.get(key, float('nan'))
                if not math.isfinite(value) or value < floor:
                    return False
            margin = glyph.get('heavyMargin', float('nan'))
            if not math.isfinite(margin) or margin >= 0:
                return False
    return True


def refine_page(bundle, packets, ems, predictions):
    policy = bundle.get('orderedInkPolicy')
    if policy is None:
        return predictions
    if not (len(packets) == len(ems) == len(predictions)):
        raise ValueError('Soft glyph confirmation peer count differs')
    result = []
    for packet, em, prior in zip(packets, ems, predictions):
        if not prior.get('softInkRescueApplied'):
            result.append(prior)
            continue
        observed = observe(packet, em, bundle['referenceInkPairs'], include_ordered=True)
        counts = expected_counts(packet.get('wordMembers', []))
        veto = regular_glyph_agreement(observed, counts, policy)
        updated = dict(prior, sourceSoftGlyphConfirmationMeasured=True,
                       sourceSoftGlyphConflictVetoApplied=veto)
        if veto:
            updated.update(render_policy('regular'))
            updated['softInkRescueApplied'] = False
        result.append(updated)
    return result
