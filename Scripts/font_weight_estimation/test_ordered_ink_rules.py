import unittest

from features import render_policy
from ordered_ink_rules import apply, outline_witness


class OrderedInkRulesTests(unittest.TestCase):
    def setUp(self):
        self.policy = dict(minimumExistingScore=.1, minimumWordFit=.8, minimumWordMargin=.1,
            minimumIndependentGlyphs=2, minimumGlyphFit=.75, minimumKnownSupport=.95,
            minimumMeanGlyphMargin=.025, requireWitnessedOutline=True,
            minimumOutlineProbability=.9, minimumPaintSeparation=35.)
        glyph = dict(templateFit=.8, heavyMargin=.04, referenceKnownSupport=1.)
        self.word = dict(templateFit=.85, normalTemplateMargin=.15, matchedWeight=800,
                         orderedGlyphs=dict(glyphs=[glyph, dict(glyph)]))
        self.observation = dict(words=[self.word], expectedGlyphCounts=[2], outlineWitnessed=True)

    def test_background_paint_cannot_count_as_an_independent_outline(self):
        style = dict(outline=dict(present=True, probability=.999, rgb=[255, 255, 255]),
                     background=dict(rgb=[255, 255, 255]), fill=dict(rgb=[0, 0, 0]))
        self.assertFalse(outline_witness(style, self.policy))
        style['background']['rgb'] = [100, 100, 100]
        self.assertTrue(outline_witness(style, self.policy))
        style['outline']['probability'] = float('nan')
        self.assertFalse(outline_witness(style, self.policy))

    def test_all_glyphs_and_independent_outline_must_agree(self):
        prior = dict(render_policy('regular'), polarityRescueScore=.15)
        self.assertTrue(apply(self.observation, prior, self.policy)['renderBold'])
        self.assertFalse(apply(dict(self.observation, outlineWitnessed=False), prior, self.policy)['renderBold'])
        self.word['orderedGlyphs']['glyphs'][1]['heavyMargin'] = -.01
        self.assertFalse(apply(self.observation, prior, self.policy)['renderBold'])

    def test_mixed_translation_stays_regular(self):
        prior = dict(render_policy('mixed'), polarityRescueScore=.9)
        self.assertFalse(apply(self.observation, prior, self.policy)['renderBold'])


if __name__ == '__main__':
    unittest.main()
