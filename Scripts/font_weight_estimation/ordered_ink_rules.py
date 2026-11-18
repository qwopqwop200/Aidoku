"""Whole-word and ordered whole-glyph font-shape agreement, no ID features."""
import math
import unicodedata

from features import render_policy


def expected_counts(members):
    return [sum(unicodedata.category(c)[0] in 'LN' for c in unicodedata.normalize('NFC', m['text']))
            for m in members[:6]]


def outline_witness(style, policy):
    outline = style.get('outline', {})
    probability = outline.get('probability', 0.)
    if not outline.get('present') or not math.isfinite(probability) or probability < policy['minimumOutlineProbability']:
        return False
    colors = [outline.get('rgb'), style.get('background', {}).get('rgb'), style.get('fill', {}).get('rgb')]
    if any(c is None or len(c) != 3 or not all(math.isfinite(v) for v in c) for c in colors):
        return False
    return all(math.sqrt(sum((a-b)**2 for a, b in zip(colors[0], other))) >= policy['minimumPaintSeparation']
               for other in colors[1:])


def proposes(observation, confidence, policy):
    words = observation.get('words', [])
    expected = observation.get('expectedGlyphCounts', [])
    if (not words or len(words) != len(expected) or not math.isfinite(confidence)
            or confidence < policy['minimumExistingScore']):
        return False
    if policy.get('requireWitnessedOutline') and not observation.get('outlineWitnessed'):
        return False
    for word, count in zip(words, expected):
        for name, threshold in (('templateFit', policy['minimumWordFit']),
                                ('normalTemplateMargin', policy['minimumWordMargin']), ('matchedWeight', 700.)):
            if not math.isfinite(word.get(name, float('nan'))) or word[name] < threshold:
                return False
        glyphs = word.get('orderedGlyphs', {}).get('glyphs', [])
        if len(glyphs) != count or count < policy['minimumIndependentGlyphs']:
            return False
        margins = []
        for glyph in glyphs:
            for name, threshold in (('templateFit', policy['minimumGlyphFit']),
                                    ('referenceKnownSupport', policy['minimumKnownSupport'])):
                if not math.isfinite(glyph.get(name, float('nan'))) or glyph[name] < threshold:
                    return False
            margin = glyph.get('heavyMargin', float('nan'))
            if not math.isfinite(margin) or margin <= 0:
                return False
            margins.append(margin)
        if sum(margins)/len(margins) < policy['minimumMeanGlyphMargin']:
            return False
    return True


def apply(observation, prior, policy):
    promote = prior['sourceWeight'] == 'regular' and proposes(
        observation, prior.get('polarityRescueScore', 0.), policy)
    result = dict(prior, orderedInkRescueApplied=bool(promote))
    if promote:
        result.update(render_policy('bold'))
    return result
