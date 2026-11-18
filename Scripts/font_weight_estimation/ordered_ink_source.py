"""Source-only outlined-font shape consensus using existing glyph/RF/style."""
import hashlib
import math
from pathlib import Path

from ordered_ink_rules import outline_witness, expected_counts, apply
from soft_ink_source import observe


def eligible(prior, style, policy):
    score = prior.get('polarityRescueScore', 0.)
    return (prior['sourceWeight'] == 'regular' and math.isfinite(score)
            and score >= policy['minimumExistingScore'] and outline_witness(style, policy))


def infer_page(packets, ems, predictions, pairs, policy):
    if not (len(packets) == len(ems) == len(predictions)):
        raise ValueError('Ordered source peer count differs')
    for name, expected in policy['implementationSHA256'].items():
        if hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() != expected:
            raise ValueError('Ordered source implementation changed: '+name)
    result = []
    for packet, em, prior in zip(packets, ems, predictions):
        if not eligible(prior, (packet or {}).get('style', {}), policy):
            result.append(dict(prior, orderedInkRescueApplied=False, orderedSourceMeasured=False))
            continue
        observation = observe(packet, em, pairs, include_ordered=True)
        observation['expectedGlyphCounts'] = expected_counts(packet.get('wordMembers', []))
        observation['outlineWitnessed'] = True
        result.append(dict(apply(observation, prior, policy), orderedSourceMeasured=True))
    return result
