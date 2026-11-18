"""Explicit shared cutoffs for antialiased corresponding source stroke radii."""
import math

from features import render_policy


def word_passes(word, policy):
    if not word.get('usable'):
        return False
    for name, minimum in (
            ('matchedWeight', 700.), ('templateFit', policy['minimumFit']),
            ('normalTemplateMargin', policy['minimumNormalMargin']),
            ('medianWeightFraction', policy['minimumSoftFraction']),
            ('correspondingSourceSupport', policy['minimumSourceSupport'])):
        value = float(word.get(name, float('nan')))
        if not math.isfinite(value) or value < minimum:
            return False
    return True


def proposes(observation, confidence, policy):
    words = observation.get('words', [])
    if (not words or not math.isfinite(confidence) or confidence < policy['minimumExistingScore']
            or len(words) != observation['expectedWordCount']):
        return False
    return all(word_passes(word, policy) for word in words)


def apply(observation, prior, policy):
    promote = prior['sourceWeight'] == 'regular' and proposes(
        observation, prior.get('polarityRescueScore', 0.), policy)
    result = dict(prior, softInkRescueApplied=bool(promote))
    if promote:
        result.update(render_policy('bold'))
    return result
