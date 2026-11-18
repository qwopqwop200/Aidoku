"""Fresh reference comparison from source packets and existing glyph/RF maps."""
import hashlib
from pathlib import Path

import numpy as np

from color_consistent_ink import reconstruct
from reference_ink_weight import measure
from reference_ink_rules import apply
from segmented_ink_geometry import measure as measure_eligibility


def eligible(prediction, policy):
    if prediction['sourceWeight'] != 'regular':
        return False
    field = policy.get('existingScoreField', 'none')
    return field == 'none' or prediction.get(field, 0.) >= policy['minimumExistingScore']


def infer_page(packets, ems, predictions, pairs, policy):
    if not (len(packets) == len(ems) == len(predictions)):
        raise ValueError('Reference source batch differs')
    for name, expected in policy['implementationSHA256'].items():
        actual = hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError('Reference rule measurement implementation changed: '+name)
    if policy.get('minimumInformativeGlyphs'):
        expected = policy['informationImplementationSHA256']
        if hashlib.sha256(Path(__file__).with_name('glyph_information.py').read_bytes()).hexdigest() != expected:
            raise ValueError('Reference contour-information implementation changed')
    result = []
    for packet, em, prior in zip(packets, ems, predictions):
        observation = dict(words=[])
        measured = False
        information = None
        if eligible(prior, policy):
            if packet is None:
                raise ValueError('Reference weight correction requires existing glyph/RF evidence')
            members = packet.get('wordMembers', [])
            if policy.get('minimumInformativeGlyphs'):
                from glyph_information import count
                information = count(members, policy['informationFont'], policy['minimumReferencePerimeterEm'])
                if information < policy['minimumInformativeGlyphs']:
                    result.append(dict(prior, referenceInformativeGlyphs=information,
                                       glyphInformationRescueApplied=False))
                    continue
            if not packet.get('glyphEvidence'):
                raise ValueError('Reference weight correction requires existing glyph/RF evidence')
            if members:
                measured = True
                rgb = np.asarray(packet['rgb'])
                bbox, own, style = packet['bbox'], np.asarray(packet['ownership'], bool), packet['style']
                geometry = measure_eligibility(rgb, bbox, em, own, style, packet['glyphEvidence'])
                if (max(s['pairedQuantiles'][2] for s in geometry['stages']) >= .10
                        and max(s['components'] for s in geometry['stages']) >= 2):
                    alpha, known, _ = reconstruct(rgb, own, style, packet['glyphEvidence'], em=em)
                    observation = measure(rgb, bbox, em, own, style, pairs, members, alpha, known)
                    if (policy.get('requireCompleteWordEvidence')
                            and len(observation['words']) != min(6, len(members))):
                        observation = dict(words=[])
        updated = apply(observation, prior, policy)
        updated['registeredInkRescueApplied'] |= prior.get('registeredInkRescueApplied', False)
        updated['referenceSourceMeasured'] = measured or prior.get('referenceSourceMeasured', False)
        if information is not None:
            updated['referenceInformativeGlyphs'] = information
            updated['glyphInformationRescueApplied'] = updated['sourceWeight'] != prior['sourceWeight']
        result.append(updated)
    return result
