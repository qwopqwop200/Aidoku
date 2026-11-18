import unittest

from features import render_policy
from soft_ink_rules import apply


class SoftInkRuleTests(unittest.TestCase):
    def setUp(self):
        self.policy = dict(minimumExistingScore=.15, minimumFit=.8, minimumNormalMargin=.025,
                           minimumSoftFraction=.15, minimumSourceSupport=.95)
        self.word = dict(usable=True, matchedWeight=700, templateFit=.85, normalTemplateMargin=.05,
                         medianWeightFraction=.2, correspondingSourceSupport=.96)

    def test_supported_soft_strokes_rescue_only_regular_complete_words(self):
        obs = dict(words=[self.word], expectedWordCount=1)
        for label in ('regular', 'mixed'):
            prior = dict(render_policy(label), polarityRescueScore=.16)
            result = apply(obs, prior, self.policy)
            self.assertEqual(result['sourceWeight'], 'bold' if label == 'regular' else 'mixed')
            if label == 'mixed':
                self.assertFalse(result['renderBold'])

    def test_missing_word_and_nonfinite_confidence_cannot_promote(self):
        prior = dict(render_policy('regular'), polarityRescueScore=.16)
        self.assertFalse(apply(dict(words=[self.word], expectedWordCount=2), prior, self.policy)['renderBold'])
        prior['polarityRescueScore'] = float('nan')
        self.assertFalse(apply(dict(words=[self.word], expectedWordCount=1), prior, self.policy)['renderBold'])


if __name__ == '__main__':
    unittest.main()
