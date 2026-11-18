import copy
import tempfile
import unittest
from pathlib import Path
from PIL import Image
from merge_appearance_gt import validate


class AppearanceValidationTests(unittest.TestCase):
    def test_original_pixel_anchor_and_outline_invariants(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / 'source.png'
            Image.new('RGB', (3, 3), (4, 18, 30)).save(path)
            source = dict(itemID='test', crop=str(path), cropSHA256='fixed', cropSize=[3, 3], fontPixels=10)
            record = dict(itemID='test',
                fill=dict(mode='solid', rgb=[4, 18, 30], colors=[[4, 18, 30]], confidence=.9),
                outline=dict(present=False, rgb=None, widthPx=0, widthRangePx=[0, 0], layers=[], confidence=.9),
                shadow=dict(present=False, rgb=None, offsetPx=[0, 0], opacity=None, confidence=.9),
                background=dict(mode='textured', rgb=[4, 18, 30], confidence=.8),
                review=dict(reviewed=True, viewedImagePath=str(path), cropSHA256='fixed', observations='Original source pixel anchors verified.',
                    uncertainFields=[], anchors=[dict(role='fill', xy=[0, 0], rgb=[4, 18, 30]),
                                                dict(role='background', xy=[2, 2], rgb=[4, 18, 30])]))
            self.assertEqual(validate(record, source)[0], [])
            wrong = copy.deepcopy(record)
            wrong['review']['anchors'][0]['rgb'] = [4, 18, 31]
            self.assertTrue(any('!= source' in e for e in validate(wrong, source)[0]))
            wrong = copy.deepcopy(record)
            wrong['outline']['widthPx'] = 5
            self.assertIn('absent outline has paint/width', validate(wrong, source)[0])
            wrong = copy.deepcopy(record)
            wrong['substyles'] = [dict(rectCrop=[1, 1, 4, 4])]
            self.assertIn('substyle rectangle invalid or outside crop', validate(wrong, source)[0])


if __name__ == '__main__':
    unittest.main()
