import unittest
from unittest.mock import patch
import hashlib
import json
from pathlib import Path
import tempfile

import numpy as np
from PIL import Image

from existing_glyph_evidence import align_array, load_existing
from segmented_ink_geometry import reconstruct


class ExistingInkTests(unittest.TestCase):
    def test_visible_color_ink_survives_low_segmentation_probability(self):
        rgb = np.full((64, 64, 3), 255, np.uint8)
        rgb[12:52, 28:32] = [20, 80, 160]
        style = dict(fill=dict(rgb=[20, 80, 160]), background=dict(rgb=[255, 255, 255]),
                     outline=dict(present=False))
        evidence = dict(primary=np.zeros((64, 64), np.float32), boundary=np.zeros((64, 64), np.float32),
                        native=np.zeros((64, 64), np.uint8), rf=np.zeros((64, 64, 27), np.float32),
                        valid=np.ones((64, 64), bool))
        alpha, _, audit = reconstruct(rgb, np.ones((64, 64), bool), style, evidence, em=32)
        self.assertGreater(float(alpha[20:45, 29:31].mean()), .9)
        self.assertGreater(audit['colorInkPreservedOutsideSegmentation'], 0)

    def test_reencoded_crop_requires_same_source_and_same_pixels(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            folder = root/'runtime/source-case'
            folder.mkdir(parents=True)
            rgb = np.arange(36, dtype=np.uint8).reshape(3, 4, 3)
            cached, current = root/'cached.png', root/'current.png'
            Image.fromarray(rgb).save(cached, compress_level=0)
            Image.fromarray(rgb).save(current, compress_level=9)
            digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
            self.assertNotEqual(digest(cached), digest(current))
            prediction = folder/'appearance.json'
            prediction.write_text('{}')
            index = dict(sourceOnly=True, GTMaskUsed=False, items={'case': dict(
                sourceSHA256='source', imageSHA256=digest(cached), image=str(cached), cropBounds=[10, 20, 14, 23])})
            (root/'INDEX.json').write_text(json.dumps(index))
            np.savez(folder/'evidence.npz', sourceRGBSHA256=np.array(digest(cached)),
                     segPrimary=np.ones((3, 4), np.float32), segBoundary=np.ones((3, 4), np.float32),
                     rf=np.zeros((3, 4, 27), np.float16), rfModelWeightsSHA256=np.array('rf-model'))
            np.ones((3, 4), np.uint8).tofile(folder/'base.u8')
            row = dict(sourceImageSHA256='source', cropSHA256=digest(current), cropBounds=[10, 20, 14, 23])
            identity = dict(predictionPath=str(prediction), predictionSHA256=digest(prediction),
                            sourceCropSHA256=digest(cached))
            with patch('existing_glyph_evidence.source_reader', return_value=(root, {}, None)):
                result = load_existing(row, identity, rgb)
                self.assertTrue(result['valid'].all())
                self.assertFalse(result['newModelCreated'])
                with self.assertRaises(ValueError):
                    load_existing(dict(row, sourceImageSHA256='different-source'), identity, rgb)

    def test_absolute_crop_alignment_preserves_unknown_margins(self):
        values = np.arange(12).reshape(3, 4)
        aligned, valid = align_array(values, [11, 21, 15, 24], [10, 20, 16, 25])
        np.testing.assert_array_equal(aligned[1:4, 1:5], values)
        self.assertEqual(int(valid.sum()), 12)
        self.assertFalse(valid[0].any())
        self.assertFalse(valid[:, -1].any())

    def test_broad_segment_posterior_cannot_turn_background_into_ink(self):
        rgb = np.full((64, 64, 3), 255, np.uint8)
        rgb[12:52, 28:32] = 0
        style = dict(fill=dict(rgb=[0, 0, 0]), background=dict(rgb=[255, 255, 255]),
                     outline=dict(present=False))
        evidence = dict(primary=np.ones((64, 64), np.float32), boundary=np.ones((64, 64), np.float32),
                        native=np.ones((64, 64), np.uint8), rf=np.ones((64, 64, 27), np.float32),
                        valid=np.ones((64, 64), bool))
        alpha, valid, audit = reconstruct(rgb, np.ones((64, 64), bool), style, evidence, em=32)
        self.assertTrue(valid.all())
        self.assertGreater(float(alpha[20:45, 29:31].mean()), .9)
        self.assertEqual(float(alpha[:8].max()), 0.)
        self.assertEqual(float(alpha[:, :20].max()), 0.)
        self.assertGreater(audit['exteriorBackgroundPixels'], 0)


if __name__ == '__main__':
    unittest.main()
