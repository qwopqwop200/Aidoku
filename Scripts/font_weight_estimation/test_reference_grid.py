import json
from pathlib import Path
import unittest

import numpy as np

from reference_grid import masks
from reference_ink_weight import reference_pairs


class ReferenceGridTests(unittest.TestCase):
    def test_selected_face_and_weight_pair_keep_identical_origins_and_pixels(self):
        path = Path(__file__).resolve().parents[3]/'font-weight-estimation-20261111/reference-bank/WORD-PAIRS.json'
        pair = next(p for p in reference_pairs(json.loads(path.read_text())['pairs'])
                    if p['name'] == 'NotoSerifJP')
        normal_face = dict(name=pair['name'], regular=pair['regular'], heavy=pair['regular'], _frame=pair)
        heavy_face = dict(name=pair['name'], regular=pair['heavy'], heavy=pair['heavy'], _frame=pair)
        for vertical in (False, True):
            a, b = masks(pair, '星街さん', vertical)
            x, _ = masks(normal_face, '星街さん', vertical)
            y, _ = masks(heavy_face, '星街さん', vertical)
            np.testing.assert_array_equal(a, x)
            np.testing.assert_array_equal(b, y)


if __name__ == '__main__':
    unittest.main()
