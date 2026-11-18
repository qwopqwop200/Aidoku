import unittest
import json
from pathlib import Path

import numpy as np
import cv2

from ordered_glyph_ink import partition, advances, measure
from reference_grid import masks
from reference_ink_weight import reference_pairs


class OrderedGlyphInkTests(unittest.TestCase):
    def test_nonuniform_glyphs_split_in_gaps_without_reordering(self):
        alpha = np.zeros((80, 130), np.float32)
        alpha[20:60, 5:25] = 1
        alpha[20:60, 35:85] = 1
        alpha[20:60, 95:125] = 1
        spans = partition(alpha, np.ones(alpha.shape, bool), [.5, 1., .65], False)
        self.assertEqual(len(spans), 3)
        self.assertEqual(spans[0][0], 5)
        self.assertEqual(spans[-1][1], 125)
        for _, end in spans[:-1]:
            self.assertEqual(float(alpha[:, end].sum()), 0.)
        vertical = partition(alpha.T, np.ones(alpha.T.shape, bool), [.5, 1., .65], True)
        self.assertEqual(spans, vertical)

    def test_small_kana_and_brackets_anchor_order_without_word_identity_rules(self):
        self.assertEqual(advances('「はぁ?」'), [.5, 1., .65, 1., .5])

    def test_unobserved_ink_cannot_supply_a_partition(self):
        alpha = np.ones((80, 80), np.float32)
        self.assertEqual(partition(alpha, np.zeros(alpha.shape, bool), [1., 1.], False), [])

    def test_rendered_normal_and_heavy_keep_opposite_margins_after_ordered_registration(self):
        path = Path(__file__).resolve().parents[3]/'font-weight-estimation-20261111/reference-bank/WORD-PAIRS.json'
        pair = next(p for p in reference_pairs(json.loads(path.read_text())['pairs'])
                    if p['name'] == 'RoundedMplus')
        a, b = masks(pair, 'あいう', False)
        for alpha, heavy in ((a, False), (b, True)):
            alpha = cv2.resize(alpha, None, fx=48/128, fy=48/128, interpolation=cv2.INTER_AREA)
            alpha = np.pad(alpha, 12)
            result = measure(alpha, np.ones(alpha.shape, bool), 'あいう', False, pair, 48)
            self.assertEqual(len(result['glyphs']), 3)
            for glyph in result['glyphs']:
                self.assertEqual(glyph['heavyMargin'] > 0, heavy)
                self.assertTrue(glyph['usable'])
                if heavy:
                    self.assertGreater(glyph['medianWeightFraction'], .5)
                else:
                    self.assertAlmostEqual(glyph['medianWeightFraction'], 0.)


if __name__ == '__main__':
    unittest.main()
