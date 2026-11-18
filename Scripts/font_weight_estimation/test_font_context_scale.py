import unittest
from unittest.mock import patch

from font_context_scale import refine_page


class RegistrationUncertaintyTests(unittest.TestCase):
    def policy(self):
        return dict(minimumExistingScore=.1,minimumOutlineProbability=.9,minimumPaintSeparation=35,
            minimumWordFit=.8,minimumWordMargin=.1,minimumIndependentGlyphs=2,
            minimumGlyphFit=.75,minimumKnownSupport=.95,minimumMeanGlyphMargin=.025,
            requireWitnessedOutline=True)

    def packet(self):
        return dict(style=dict(fill=dict(rgb=[30,30,30]),background=dict(rgb=[180,80,120]),
            outline=dict(present=True,rgb=[255,255,255],probability=.99)),
            wordMembers=[dict(text='あい')])

    def observation(self,fit,passes):
        glyph=dict(templateFit=fit,referenceKnownSupport=1.,heavyMargin=.05)
        return dict(words=[dict(templateFit=.9,normalTemplateMargin=.12 if passes else .08,
            matchedWeight=800.,orderedGlyphs=dict(glyphs=[glyph,glyph]))])

    def test_selects_image_fit_not_positive_weight_and_keeps_source_em(self):
        bundle=dict(orderedInkPolicy=self.policy(),referenceInkPairs=[])
        prior=dict(sourceWeight='regular',renderBold=False,polarityRescueScore=.2)
        ems=[74.]
        def observe(packet,em,pairs,include_ordered):
            return self.observation(.85 if em==74 else .8,em!=74)
        with patch('font_context_scale.observe',side_effect=observe) as measurement:
            result=refine_page(bundle,[self.packet()],ems,[prior])
        self.assertEqual(result[0]['sourceWeight'],'regular')
        self.assertEqual(result[0]['sourceWeightMeasurementEM'],74.)
        self.assertEqual(measurement.call_count,5)
        self.assertEqual(ems,[74.])

    def test_better_whole_glyph_fit_can_resolve_quantized_scale(self):
        bundle=dict(orderedInkPolicy=self.policy(),referenceInkPairs=[])
        prior=dict(sourceWeight='regular',renderBold=False,polarityRescueScore=.2)
        def observe(packet,em,pairs,include_ordered):
            return self.observation(.85 if em==73 else .8,em==73)
        with patch('font_context_scale.observe',side_effect=observe):
            result=refine_page(bundle,[self.packet()],[74.],[prior])
        self.assertEqual(result[0]['sourceWeight'],'bold')
        self.assertEqual(result[0]['sourceWeightMeasurementEM'],73.)
        self.assertTrue(result[0]['sourceFontScaleFitApplied'])

    def test_mixed_never_gets_alternative_weight_search(self):
        prior=dict(sourceWeight='mixed',renderBold=False,polarityRescueScore=.9)
        with patch('font_context_scale.observe',side_effect=AssertionError('mixed must stay regular')):
            result=refine_page(dict(orderedInkPolicy=self.policy()),[self.packet()],[74.],[prior])
        self.assertIs(result[0],prior)


if __name__=='__main__':unittest.main()
