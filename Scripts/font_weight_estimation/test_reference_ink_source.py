import unittest

from features import render_policy
from reference_ink_source import infer_page


class ReferenceInkSourceTests(unittest.TestCase):
    def test_confidence_gate_and_mixed_guard_do_not_request_unneeded_glyph_maps(self):
        policy = dict(implementationSHA256={}, existingScoreField='polarityRescueScore',
                      minimumExistingScore=.05, minimumWordAgreement=1.)
        rows = [dict(render_policy(label), polarityRescueScore=score)
                for label, score in [('regular', .01), ('mixed', .9), ('bold', .9)]]
        result = infer_page([None]*3, [30.]*3, rows, [], policy)
        self.assertEqual([r['sourceWeight'] for r in result], ['regular', 'mixed', 'bold'])
        self.assertFalse(any(r['referenceSourceMeasured'] for r in result))
        self.assertFalse(result[1]['renderBold'])

    def test_eligible_case_cannot_silently_fallback_without_existing_model_evidence(self):
        policy = dict(implementationSHA256={}, existingScoreField='none')
        with self.assertRaisesRegex(ValueError, 'requires existing glyph/RF'):
            infer_page([None], [30.], [render_policy('regular')], [], policy)

    def test_stale_measurement_rule_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'implementation changed'):
            infer_page([], [], [], [], dict(implementationSHA256={'reference_ink_weight.py': 'obsolete'}))


if __name__ == '__main__':
    unittest.main()
