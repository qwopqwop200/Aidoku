import unittest

from features import render_policy
from reference_ink_rules import apply


class ReferenceInkRuleTests(unittest.TestCase):
    def setUp(self):
        self.policy = dict(minimumFit=.8, minimumNormalMargin=.025,
            minimumStrokeFraction=.25, maximumFractionSpread=1., minimumWordAgreement=1.,
            minimumRegisteredFraction=.2, minimumRegisteredSupport=.95,
            existingScoreField='none')
        self.word = dict(templateFit=.9, matchedReferenceWeight=800,
            normalTemplateMargin=.1, weightFraction=.5, fractionSpread=.2,
            registeredStrokeProfile=dict(usable=True, medianWeightFraction=.4,
                                         correspondingSourceSupport=.97))

    def test_missing_correspondence_cannot_promote_a_good_but_unregistered_template(self):
        word = dict(self.word)
        del word['registeredStrokeProfile']
        result = apply(dict(words=[word]), render_policy('regular'), self.policy)
        self.assertEqual(result['sourceWeight'], 'regular')

    def test_high_correspondence_can_promote_without_classifier_confidence_or_ids(self):
        result = apply(dict(words=[self.word]), render_policy('regular'), self.policy)
        self.assertEqual(result['sourceWeight'], 'bold')
        self.assertTrue(result['registeredInkRescueApplied'])

    def test_mixed_source_stays_regular_for_whole_translation(self):
        result = apply(dict(words=[self.word]), render_policy('mixed'), self.policy)
        self.assertEqual(result['sourceWeight'], 'mixed')
        self.assertFalse(result['renderBold'])

    def test_nan_or_only_one_matching_word_cannot_satisfy_unanimous_agreement(self):
        invalid = dict(self.word, templateFit=float('nan'))
        result = apply(dict(words=[self.word, invalid]), render_policy('regular'), self.policy)
        self.assertEqual(result['sourceWeight'], 'regular')


if __name__ == '__main__':
    unittest.main()
