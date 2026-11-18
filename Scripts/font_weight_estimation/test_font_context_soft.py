import unittest

from font_context_soft import regular_glyph_agreement


class SoftGlyphContradictionTests(unittest.TestCase):
    policy = dict(minimumIndependentGlyphs=2, minimumGlyphFit=.75, minimumKnownSupport=.95)

    def observed(self, margins):
        return dict(words=[dict(orderedGlyphs=dict(glyphs=[
            dict(templateFit=.9, referenceKnownSupport=1., heavyMargin=m) for m in margins]))])

    def test_complete_independent_regular_agreement_vetoes(self):
        self.assertTrue(regular_glyph_agreement(self.observed([-.1, -.02]), [2], self.policy))

    def test_any_heavy_match_preserves_soft_rescue(self):
        self.assertFalse(regular_glyph_agreement(self.observed([-.1, .02]), [2], self.policy))

    def test_incomplete_or_unreliable_evidence_cannot_veto(self):
        self.assertFalse(regular_glyph_agreement(self.observed([-.1]), [2], self.policy))
        self.assertFalse(regular_glyph_agreement(self.observed([-.1]), [1], self.policy))
        value = self.observed([-.1, -.02])
        value['words'][0]['orderedGlyphs']['glyphs'][0]['referenceKnownSupport'] = .5
        self.assertFalse(regular_glyph_agreement(value, [2], self.policy))

    def test_ties_and_nonfinite_margins_are_not_regular_proof(self):
        for margin in (0., float('nan'), float('inf')):
            self.assertFalse(regular_glyph_agreement(self.observed([-.1, margin]), [2], self.policy))


if __name__ == '__main__':
    unittest.main()
