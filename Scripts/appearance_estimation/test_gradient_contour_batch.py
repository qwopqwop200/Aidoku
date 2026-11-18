"""Batch isolation, lazy source loading, byte identity, and actual-RGB evaluation."""
import argparse
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image
import apply_gradient_contour as batch
from optimize_appearance import digest, evaluate_predictions, read, save
import source_gradient_contour as contour


def prediction(item='synthetic'):
    return dict(itemID=item, fillIndex=0, outlineIndex=0, backgroundIndex=0,
                fill=dict(rgb=[255, 255, 255]), outline=dict(rgb=[120, 120, 120], present=True),
                background=dict(rgb=[255, 255, 255]), shadow=dict(present=False),
                width=dict(nominal=2, interval=[1, 3]), pixelRoleEvidence={'untouched': [1, 2]})


class GradientContourBatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        Image.fromarray(np.full((8, 9, 3), 140, np.uint8)).save(self.root / 'rgb.png')
        Image.fromarray(np.full((8, 9), 255, np.uint8)).save(self.root / 'synthetic.png')
        self.source = dict(itemID='synthetic', crop=str(self.root / 'rgb.png'),
                           cropSHA256=digest(self.root / 'rgb.png'), page='source',
                           sourceImageSHA256='page-sha', pageSize=[100, 100], cropBounds=[1, 2, 10, 10],
                           maxContextFraction=.15, individualPolygonsCrop=[], mergedPolygonCrop=[], fontPixels=8)
        self.entry = dict(itemID='synthetic', identity=dict(
            sourceRGBSHA256=self.source['cropSHA256'],
            predictedMaskSHA256=digest(self.root / 'synthetic.png'), OCRSourceSHA256='ocr-file-sha',
            polygons=[], mergedPolygon=[], fontPixels=8), packet=dict(fontPixels=8, colors=[[255, 255, 255]]))
        save(self.root / 'synthetic.json', self.entry)
        self.options = {k: str(self.root) for k in ('features', 'masks', 'estimator', 'source_root', 'ocr_evidence')}

    def execute(self):
        return batch.process_one((self.source, prediction(), self.options))

    def test_worker_request_excludes_styles_anchors_and_unknown_fields(self):
        row = {**self.source, 'outline': {'rgb': [1, 2, 3]}, 'review': {'anchors': [1]}, 'futureGT': True}
        self.assertEqual(batch.source_request(row), self.source)
        self.source['review'] = {'anchors': []}
        with self.assertRaisesRegex(ValueError, 'whitelisted'):
            self.execute()

    def test_empty_body_alone_skips_expensive_load_and_refine(self):
        with patch.object(contour, 'propose', return_value=[]) as propose, \
                patch.object(contour, 'select_components', return_value=[]) as select, \
                patch.object(batch, 'load_expensive', side_effect=AssertionError('loaded')) as load, \
                patch.object(contour, 'refine', side_effect=AssertionError('refined')):
            result, diagnostic = self.execute()
        self.assertEqual(result, prediction())
        self.assertFalse(diagnostic['diagnostic']['expensiveSourceLoaded'])
        propose.assert_called_once()
        select.assert_called_once_with([])
        load.assert_not_called()

    def test_nonempty_body_never_prunes_and_sidecar_keeps_diagnostics(self):
        def refine(rgb, mask, arrays, geometry, pred, model, packet):
            self.assertEqual(set(geometry), {'polygons', 'mergedPolygon', 'fontPixels'})
            self.assertEqual(rgb.shape[:2], mask.shape)
            pred['outline']['rgb'] = [71, 38, 29]
            pred['outline']['gradientContourCorrection'] = {'sourceEvidence': 'observed'}
            return pred, {'applied': True}
        with patch.object(contour, 'propose', return_value=['component']), \
                patch.object(contour, 'select_components', return_value=[['component']]), \
                patch.object(batch, 'load_expensive', return_value=({}, {}, {})) as load, \
                patch.object(contour, 'refine', side_effect=refine):
            result, diagnostic = self.execute()
        load.assert_called_once()
        expected = prediction()
        expected['outline']['rgb'] = [71, 38, 29]
        expected['outline']['gradientContourCorrection'] = {'sourceEvidence': 'observed'}
        self.assertEqual(result, expected)
        self.assertTrue(diagnostic['diagnostic']['applied'])
        self.assertTrue(diagnostic['outlineRGBChanged'])

    def test_warm_prescreen_and_empty_body_restore_raw_prediction(self):
        warm = prediction()
        warm['outline']['rgb'] = [71, 38, 29]
        warm['outline']['gradientContourCorrection'] = dict(version=contour.VERSION, previousRGB=[120, 120, 120])
        with patch.object(contour, 'propose', return_value=[]) as propose, \
                patch.object(contour, 'select_components', return_value=[]), \
                patch.object(batch, 'load_expensive', side_effect=AssertionError('loaded')):
            result, _ = batch.process_one((self.source, warm, self.options))
        self.assertEqual(propose.call_args.args[2], prediction())
        self.assertEqual(result, prediction())
        batch.assert_rgb_only(warm, result)
        batch.assert_document_rgb_only({'items': [warm]}, {'items': [result]})
        self.assertIn('gradientContourCorrection', warm['outline'])

    def test_source_context_is_bounded_without_a_page_area_gate(self):
        self.assertEqual(batch.source_request(self.source), self.source)
        for context in (.151, float('nan'), -1):
            with self.subTest(context=context), self.assertRaises(ValueError):
                batch.source_request({**self.source, 'maxContextFraction': context})

    def test_hash_and_geometry_tampering_fails_even_for_empty_body(self):
        for field in ('sourceRGBSHA256', 'predictedMaskSHA256', 'polygons'):
            entry = copy.deepcopy(self.entry)
            entry['identity'][field] = 'tampered'
            save(self.root / 'synthetic.json', entry)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.execute()

    def test_each_other_field_and_document_metadata_are_immutable(self):
        old = prediction()
        mutations = [lambda p: p.update(outlineIndex=1),
                     lambda p: p['outline'].update(present=False),
                     lambda p: p['width'].update(nominal=3),
                     lambda p: p['fill'].update(rgb=[0, 0, 0]),
                     lambda p: p['background'].update(rgb=[0, 0, 0]),
                     lambda p: p['shadow'].update(present=True),
                     lambda p: p['pixelRoleEvidence'].update(untouched=[]),
                     lambda p: p.update(unexpected=True)]
        for mutate in mutations:
            changed = copy.deepcopy(old)
            mutate(changed)
            with self.assertRaises(ValueError):
                batch.assert_rgb_only(old, changed)
        with self.assertRaises(ValueError):
            batch.assert_document_rgb_only({'items': [old], 'metadata': 1}, {'items': [old], 'metadata': 2})

    def test_in_place_mutation_of_other_fields_is_rejected(self):
        def bad_refine(*args):
            pred = args[4]
            pred['width']['nominal'] = 999
            return pred, {}
        with patch.object(contour, 'propose', return_value=[1]), \
                patch.object(contour, 'select_components', return_value=[[1]]), \
                patch.object(batch, 'load_expensive', return_value=({}, {}, {})), \
                patch.object(contour, 'refine', side_effect=bad_refine), \
                self.assertRaisesRegex(ValueError, 'non-outline'):
            self.execute()

    def test_evaluator_scores_emitted_rgb_with_stale_indices(self):
        rows, predictions, packets = [], [], []
        for group in ('train', 'dev', 'test'):
            rows.append(dict(evaluationSplit=group, fill=dict(rgb=[255, 255, 255]),
                             outline=dict(present=True, rgb=[71, 38, 29]),
                             background=dict(rgb=[255, 255, 255]), shadow=dict(present=False)))
            predictions.append(prediction(group))
            packets.append(dict(colors=[[255, 255, 255], [120, 120, 120]]))
        before = evaluate_predictions(rows, packets, predictions)
        for pred in predictions:
            pred['outline']['rgb'] = [71, 38, 29]
        after = evaluate_predictions(rows, packets, predictions)
        self.assertEqual(after['dev']['outline']['within10'], 1.)
        self.assertEqual(after['dev']['outline']['deltaEMedian'], 0.)
        self.assertGreater(before['dev']['outline']['deltaEMedian'], 10.)
        self.assertEqual(after['dev']['outline']['candidateCeilingWithin10'], 0.)

    def test_policy_binds_all_six_models_and_helper_bytes(self):
        for name in contour.MODEL_NAMES:
            (self.root / name).write_bytes(name.encode())
        identities = {name: digest(self.root / name) for name in contour.MODEL_NAMES}
        policy = contour.make_policy(self.root)
        contour.validate_policy(policy, identities)
        self.assertEqual(set(batch.MODEL_FILES), set(contour.MODEL_NAMES))
        for name in contour.MODEL_NAMES:
            stale = {**identities, name: 'stale'}
            with self.assertRaises(ValueError):
                contour.validate_policy(policy, stale)
        stale = copy.deepcopy(policy)
        stale['helperSHA256']['source_gradient_core.py'] = 'stale'
        with self.assertRaises(ValueError):
            contour.validate_policy(stale, identities)


if __name__ == '__main__':
    unittest.main()
