import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

import operational_appearance as live


class OperationalAppearanceTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.checkpoint = self.root / 'champion'
        self.checkpoint.mkdir()
        for name in live.MODEL_FILES + live.POLICY_FILES:
            (self.checkpoint / name).write_bytes(name.encode())
        (self.root / 'ACTIVE-ESTIMATOR.json').write_text(json.dumps({'checkpoint': 'champion'}))
        self.runtime = live.OperationalAppearance(self.root)
        self.inputs = dict(rgb=np.full((8, 9, 3), 240, np.uint8),
                           mask=np.ones((8, 9), np.uint8), context_mask=np.ones((8, 9), np.uint8),
                           rf=np.full((8, 9, 27), .25, np.float16), primary=np.full((8, 9), .8, np.float32),
                           boundary=np.full((8, 9), .7, np.float32), ocr=np.zeros((8, 9, 8), np.float32),
                           geometry=dict(polygons=[[[1, 1], [7, 1], [7, 6], [1, 6]]],
                                         mergedPolygon=[[1, 1], [7, 1], [7, 6], [1, 6]], fontPixels=12.),
                           rf_model_weights_sha256='a' * 64)

    def run_backend(self, args):
        # Assert that the real estimator receives newly written source evidence,
        # not a GT-bound prediction, cached appearance record or item ID.
        from PIL import Image
        with np.load(args.source_evidence, allow_pickle=False) as z:
            self.assertEqual(z['rfModelWeightsSHA256'].item(), 'a' * 64)
            self.assertEqual(z['sourceRGBSHA256'].item(), live.sha(args.image.read_bytes()))
            self.assertEqual(z['predictedMaskSHA256'].item(), live.sha(args.mask.read_bytes()))
            self.assertEqual(z['rf'].dtype, np.float16)
        self.assertTrue(np.array_equal(np.asarray(Image.open(args.image)), self.inputs['rgb']))
        self.assertIsNone(args.geometry)
        self.assertEqual(args.estimator, self.checkpoint.resolve())
        return dict(fill=dict(rgb=[20, 30, 40]), outline=dict(present=False, rgb=[255]*3, widthPx=0),
                    background=dict(rgb=[240]*3), shadow=dict(present=False, rgb=None, offsetPx=None))

    def test_every_request_calls_fresh_inference_and_binds_all_evidence(self):
        with patch('operational_appearance._run_source_inference', side_effect=self.run_backend) as backend:
            first = self.runtime.estimate(**self.inputs)
            second = self.runtime.estimate(**self.inputs)
        self.assertEqual(backend.call_count, 2)
        self.assertEqual(first, second)
        self.assertEqual(len(first['binding']), 10)
        self.assertFalse(first['cachedPredictionsRead'])
        self.assertTrue(first['freshInference'])

    def test_unaligned_nonfinite_or_missing_source_channels_are_rejected(self):
        for field, bad in [('rf', np.zeros((8, 9, 4))), ('primary', np.zeros((4, 9))),
                           ('boundary', np.full((8, 9), np.nan)), ('ocr', np.zeros((8, 9, 7))),
                           ('rgb', np.zeros((8, 9, 3), np.float32)), ('mask', np.full((8, 9), 2)),
                           ('context_mask', np.zeros((8, 9))), ('mask', np.zeros((8, 9)))]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.runtime.estimate(**dict(self.inputs, **{field: bad}))

    def test_labels_page_ids_and_extra_geometry_are_not_inputs(self):
        for key in ('itemID', 'page', 'GT', 'outlineRGB', 'maskPath'):
            geometry = dict(self.inputs['geometry'], **{key: 'forbidden'})
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.runtime.estimate(**dict(self.inputs, geometry=geometry))

    def test_changed_checkpoint_and_changed_policy_fail_before_inference(self):
        for name in ('model.pkl', 'NATIVE-OUTER-SHELL-POLICY.json'):
            path = self.checkpoint / name
            original = path.read_bytes()
            path.write_bytes(b'changed')
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.runtime.estimate(**self.inputs)
            path.write_bytes(original)

    def test_checkpoint_mutation_during_inference_discards_output(self):
        def mutation(args):
            result = self.run_backend(args)
            (self.checkpoint / 'width-model.pkl').write_bytes(b'changed during inference')
            return result
        with patch('operational_appearance._run_source_inference', side_effect=mutation), self.assertRaises(ValueError):
            self.runtime.estimate(**self.inputs)

    def test_inputs_are_snapshotted_and_binding_changes_with_evidence(self):
        old = copy.deepcopy(self.inputs)
        with patch('operational_appearance._run_source_inference', side_effect=self.run_backend):
            first = self.runtime.estimate(**self.inputs)
            self.inputs['rf'][0, 0, 0] = .5
            second = self.runtime.estimate(**self.inputs)
        self.assertNotEqual(first['binding']['rfSHA256'], second['binding']['rfSHA256'])
        self.assertEqual(first['binding']['geometrySHA256'], second['binding']['geometrySHA256'])
        self.assertEqual(self.inputs['geometry'], old['geometry'])

    def test_cli_uses_live_evidence_and_refuses_prior_output(self):
        from PIL import Image
        image, mask, context = [self.root / name for name in ('source.png', 'mask.png', 'context.png')]
        Image.fromarray(self.inputs['rgb']).save(image)
        Image.fromarray(self.inputs['mask'] * 255).save(mask)
        Image.fromarray(self.inputs['context_mask'] * 255).save(context)
        evidence, output = self.root / 'live.npz', self.root / 'output.json'
        np.savez(evidence, rf=self.inputs['rf'], segPrimary=self.inputs['primary'],
                 segBoundary=self.inputs['boundary'], ocr=self.inputs['ocr'],
                 sourceRGBSHA256=np.array(live.sha(image.read_bytes())),
                 predictedMaskSHA256=np.array(live.sha(mask.read_bytes())),
                 rfModelWeightsSHA256=np.array('a' * 64),
                 geometryJSON=np.array(json.dumps(self.inputs['geometry'])))
        argv = ['operational_appearance.py', '--image', str(image), '--mask', str(mask),
                '--context-mask', str(context), '--source-evidence', str(evidence),
                '--estimator', str(self.root), '--out', str(output)]
        with patch('sys.argv', argv), patch('operational_appearance._run_source_inference', side_effect=self.run_backend):
            live.main()
        self.assertTrue(json.loads(output.read_text())['freshInference'])
        with patch('sys.argv', argv), self.assertRaises(ValueError):
            live.main()


if __name__ == '__main__':
    unittest.main()
