import json
from pathlib import Path
import unittest

from glyph_information import count, perimeter


class GlyphInformationTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[3]/'font-weight-estimation-20261111/reference-bank/WORD-PAIRS.json'
        self.font = next(p['regular'] for p in json.loads(path.read_text())['pairs']
                         if p['name'] == 'NotoSansJP' and p['regular'].get('weight') == 400)

    def test_contour_evidence_is_geometric_and_does_not_count_whitespace(self):
        a = perimeter(self.font['path'], self.font['SHA256'], self.font['weight'], '議')
        b = perimeter(self.font['path'], self.font['SHA256'], self.font['weight'], 'し')
        self.assertGreater(a, 2*b)
        self.assertEqual(perimeter(self.font['path'], self.font['SHA256'], self.font['weight'], ' '), 0)

    def test_overlapping_detection_duplicates_do_not_inflate_independent_evidence(self):
        member = dict(text='議論', bbox=[0, 0, 100, 40])
        once = count([member], self.font, 7.)
        self.assertEqual(once, 2)
        self.assertEqual(count([member, member], self.font, 7.), once)
        self.assertEqual(count([member, dict(member, bbox=[0, 60, 100, 40])], self.font, 7.), 2*once)


if __name__ == '__main__':
    unittest.main()
