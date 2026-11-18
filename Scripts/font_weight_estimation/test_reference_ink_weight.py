import json
from pathlib import Path
import unittest

import cv2
import numpy as np

from reference_ink_weight import measure, stroke_profile
from word_pairs import word_masks
from word_weight_summary import weight_intervals


class ReferenceInkTests(unittest.TestCase):
    def test_stroke_profile_measures_pen_width_instead_of_glyph_extent(self):
        narrow = np.zeros((80, 80), np.float32)
        broad = narrow.copy()
        narrow[10:70, 30:34] = 1
        broad[10:70, 30:38] = 1
        a = stroke_profile(narrow, np.ones(narrow.shape, bool), 40)
        b = stroke_profile(broad, np.ones(broad.shape, bool), 40)
        self.assertAlmostEqual(float(b[1]/a[1]), 2., delta=.3)

    def test_known_bold_raster_is_not_relabelled_by_a_learned_classifier(self):
        path = Path(__file__).resolve().parents[3]/'font-weight-estimation-20261111/reference-bank/WORD-PAIRS.json'
        pairs = json.loads(path.read_text())['pairs']
        intervals = weight_intervals(pairs)
        pair = next(p for p, interval in zip(pairs, intervals) if p['name'] == 'RoundedMplus' and interval[0] == 700)
        face = pair['regular']
        alpha = word_masks(dict(regular=face, heavy=face), 'あいう', False)[0]
        alpha = cv2.resize(alpha, None, fx=56/128, fy=56/128, interpolation=cv2.INTER_AREA)
        h, w = alpha.shape
        alpha = np.pad(alpha, 8)
        rgb = np.repeat(np.rint(255*(1-alpha))[:, :, None].astype(np.uint8), 3, axis=2)
        own, known = alpha > .01, np.ones(alpha.shape, bool)
        style = dict(fill=dict(rgb=[0, 0, 0]), background=dict(rgb=[255, 255, 255]), outline=dict(present=False))
        bbox = [8, 8, w, h]
        result = measure(rgb, bbox, 56, own, style, pairs, [dict(bbox=bbox, text='あいう')], alpha, known)
        self.assertFalse(result['modelTrainingPerformed'])
        self.assertEqual(len(result['words']), 1)
        self.assertEqual(result['words'][0]['matchedReferenceWeight'], 700.)
        self.assertGreater(result['words'][0]['templateFit'], .9)

    def test_regular_serif_is_compared_with_an_independently_refined_normal_face(self):
        path = Path(__file__).resolve().parents[3]/'font-weight-estimation-20261111/reference-bank/WORD-PAIRS.json'
        pairs = json.loads(path.read_text())['pairs']
        pair = next(p for p, interval in zip(pairs, weight_intervals(pairs))
                    if p['name'] == 'NotoSerifJP' and interval[0] == 400)
        face = pair['regular']
        alpha = word_masks(dict(regular=face, heavy=face), '星街さん', True)[0]
        alpha = cv2.resize(alpha, None, fx=56/128, fy=56/128, interpolation=cv2.INTER_AREA)
        h, w = alpha.shape
        alpha = np.pad(alpha, 8)
        rgb = np.repeat(np.rint(255*alpha)[:, :, None].astype(np.uint8), 3, axis=2)
        own, known = alpha > .01, np.ones(alpha.shape, bool)
        style = dict(fill=dict(rgb=[255, 255, 255]), background=dict(rgb=[0, 0, 0]),
                     outline=dict(present=False))
        bbox = [8, 8, w, h]
        result = measure(rgb, bbox, 56, own, style, pairs,
                         [dict(bbox=bbox, text='星街さん')], alpha, known)
        self.assertEqual(len(result['words']), 1)
        word = result['words'][0]
        self.assertEqual(word['matchedReferenceWeight'], 400.)
        # This legacy synthetic source centres each cropped glyph separately;
        # the shared-baseline matcher must retain its correct normal decision
        # despite that deliberately different vertical registration convention.
        self.assertGreater(word['bestRegularTemplateFit'], .85)
        self.assertAlmostEqual(word['normalTemplateMargin'], 0.)


if __name__ == '__main__':
    unittest.main()
