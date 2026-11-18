import unittest

from features import render_policy
from soft_ink_source import infer_page


class SoftInkSourceTests(unittest.TestCase):
    def test_mixed_and_low_confidence_skip_unneeded_source_evidence(self):
        policy = dict(implementationSHA256={}, minimumExistingScore=.15)
        prior = [dict(render_policy(label), polarityRescueScore=score)
                 for label, score in [('mixed', .9), ('regular', .1), ('regular', float('nan'))]]
        actual = infer_page([None]*3, [30.]*3, prior, [], policy)
        self.assertEqual([r['sourceWeight'] for r in actual], ['mixed', 'regular', 'regular'])
        self.assertFalse(any(r['softSourceMeasured'] for r in actual))
        self.assertFalse(actual[0]['renderBold'])

    def test_high_confidence_requires_real_existing_glyph_rf_evidence(self):
        with self.assertRaisesRegex(ValueError, 'requires existing glyph/RF'):
            infer_page([None], [30.], [dict(render_policy('regular'), polarityRescueScore=.2)], [],
                       dict(implementationSHA256={}, minimumExistingScore=.15))


if __name__ == '__main__':
    unittest.main()
