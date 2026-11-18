"""Fit existing ordered references within source-font quantization uncertainty.

The accepted font graph rounds source ems to pixel bins. Registration compares
all five equally spaced em hypotheses within two pixels (at most 5 percent).
Selection uses only word/glyph image fit, never the candidate weight decision.
The accepted shape/outline/support gates remain unchanged; display em is intact.
"""
import math

from ordered_ink_rules import apply, expected_counts
from ordered_ink_source import eligible
from soft_ink_source import observe


def fit_quality(observation, counts):
    words = observation.get('words', [])
    if not words or len(words) != len(counts):
        return None
    fits, word_fits = [], []
    for word, count in zip(words, counts):
        glyphs = word.get('orderedGlyphs', {}).get('glyphs', [])
        if count < 1 or len(glyphs) != count:
            return None
        word_fits.append(word.get('templateFit', float('nan')))
        fits.extend(glyph.get('templateFit', float('nan')) for glyph in glyphs)
    if not all(math.isfinite(value) for value in word_fits+fits):
        return None
    return min(word_fits), sum(fits)/len(fits)


def refine_page(bundle, packets, ems, predictions):
    policy = bundle.get('orderedInkPolicy')
    if policy is None:
        return predictions
    if not (len(packets) == len(ems) == len(predictions)):
        raise ValueError('Source font uncertainty peer count differs')
    results = []
    for packet, em, prior in zip(packets, ems, predictions):
        if not eligible(prior, packet['style'], policy):
            results.append(prior)
            continue
        if not math.isfinite(em) or em <= 0:
            raise ValueError('Invalid source-font uncertainty em')
        counts = expected_counts(packet.get('wordMembers', []))
        radius = min(2., .05*em)
        selected = None
        # Equal observation/registration budget for all font/weight endpoints.
        for factor in (0., -.5, .5, -1., 1.):
            candidate = em+factor*radius
            observation = observe(packet, candidate, bundle['referenceInkPairs'], include_ordered=True)
            quality = fit_quality(observation, counts)
            if quality is None:
                continue
            rank = (*quality, -abs(candidate-em))
            if selected is None or rank > selected[0]:
                selected = rank, candidate, observation
        if selected is None:
            results.append(dict(prior, sourceFontScaleFitMeasured=True, sourceFontScaleFitApplied=False))
            continue
        _, measured_em, observation = selected
        observation.update(expectedGlyphCounts=counts, outlineWitnessed=True)
        updated = apply(observation, prior, policy)
        updated.update(sourceFontScaleFitMeasured=True,
                       sourceFontScaleFitApplied=bool(updated['sourceWeight'] != prior['sourceWeight']),
                       sourceWeightMeasurementEM=float(measured_em),
                       sourceFontScaleUncertaintyPx=float(radius),
                       sourceFontScaleHypotheses=5)
        results.append(updated)
    return results
