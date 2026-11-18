"""Shared image-evidence rules over corresponding source/reference strokes."""
import math

from features import render_policy


def word_passes(word, policy):
    checks = (
        ('matchedReferenceWeight', 700., None),
        ('templateFit', policy['minimumFit'], None),
        ('normalTemplateMargin', policy['minimumNormalMargin'], None),
        ('weightFraction', policy['minimumStrokeFraction'], None),
        ('fractionSpread', None, policy['maximumFractionSpread']),
    )
    for field, lower, upper in checks:
        value = float(word.get(field, float('nan')))
        if not math.isfinite(value) or (lower is not None and value < lower) or (upper is not None and value > upper):
            return False
    minimum = policy.get('minimumRegisteredFraction')
    if minimum is not None:
        evidence = word.get('registeredStrokeProfile', {})
        if not evidence.get('usable'):
            return False
        fraction = float(evidence.get('medianWeightFraction', float('nan')))
        support = float(evidence.get('correspondingSourceSupport', float('nan')))
        if (not math.isfinite(fraction) or not math.isfinite(support) or fraction < minimum
                or support < policy['minimumRegisteredSupport']):
            return False
    return True


def apply(observation, prediction, policy):
    words = observation.get('words', [])
    agrees = sum(word_passes(word, policy) for word in words)
    promote = (prediction['sourceWeight'] == 'regular' and bool(words)
               and agrees/len(words) >= policy['minimumWordAgreement'])
    field = policy.get('existingScoreField', 'none')
    if field != 'none':
        promote &= prediction.get(field, 0.) >= policy['minimumExistingScore']
    result = dict(prediction, registeredInkRescueApplied=bool(promote))
    if promote:
        result.update(render_policy('bold'))
    return result
