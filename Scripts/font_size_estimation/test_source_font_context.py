"""Cheap producer-contract tests: synthetic pixels, no models or font inference."""
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'inpainting_compare'))
import font_size_runtime
import optimized_runtime as runtime
from source_font_context import SourceFontObservations


class SourceFontContextTests(unittest.TestCase):
    def setUp(self):
        self.spec = {'fresh-test-spec': True}
        self.bundle = {'optimizedGraph': {'version': 'test', 'measurementSpec': self.spec}}
        self.calls = []
        self.measure = patch('optimized_measurements.measure_packets', side_effect=self.measure_signals)
        self.predict = patch.object(runtime, 'predict_optimized', side_effect=self.predict_values)
        self.measure.start()
        self.predict.start()
        self.addCleanup(self.measure.stop)
        self.addCleanup(self.predict.stop)

    def measure_signals(self, packets, spec):
        self.assertIs(spec, self.spec)
        call = len(self.calls) + 1
        signals = {'style187': np.full((len(packets), 262), call, float),
                   'angles131': np.arange(len(packets), dtype=float) + call}
        self.calls.append((packets, signals))
        return signals

    def predict_values(self, bundle, native, evidence, priors, groups, sizes,
                       signals, source_ids=None, return_stages=False):
        self.assertIs(signals, self.calls[-1][1])
        values = np.asarray(priors, float) + 3
        return (values, {'prediction-only': values.copy()}) if return_stages else values

    def packets(self):
        return [dict(native=np.zeros(156), evidence=np.zeros(291), prior=prior,
                     pageSize=[100, 100], sourceHash='one-source',
                     cropBounds=[i, i, i + 10, i + 12])
                for i, prior in enumerate([20., 10.])]

    def test_all_return_modes_keep_stages_separate_and_signals_fresh(self):
        packets = self.packets()
        for stages in (False, True):
            default = runtime.infer_packets(self.bundle, packets, return_stages=stages)
            if stages:
                self.assertEqual(len(default), 2)
                self.assertEqual(list(default[1]), ['prediction-only'])
                default = default[0]
            np.testing.assert_array_equal(default, [23, 13])
            result = runtime.infer_packets(self.bundle, packets,
                                           return_stages=stages, return_context=True)
            context = result[-1]
            self.assertEqual(len(result), 3 if stages else 2)
            self.assertIs(context.fresh_font_signals, self.calls[-1][1])
            self.assertIs(context.measurement_spec, self.spec)
            self.assertIs(context.packets[0], packets[0])
            self.assertIs(context.packets[1], packets[1])
            self.assertEqual(context.packet_order, (0, 1))
            self.assertEqual(context.crop_bounds, ((0, 0, 10, 12), (1, 1, 11, 13)))
            self.assertEqual(context.source_observations, (None, None))
            np.testing.assert_array_equal(context.original_priors, [20, 10])
            np.testing.assert_array_equal(context.final_source_ems, [23, 13])
            self.assertNotIn('prediction-only', context.fresh_font_signals)
            result[0][0] = 999
            self.assertEqual(context.final_source_ems[0], 23)
        self.assertIsNot(self.calls[-1][1], self.calls[-2][1])
        self.assertNotEqual(self.calls[-1][1]['style187'][0, 0],
                            self.calls[-2][1]['style187'][0, 0])
        self.assertEqual([p['prior'] for p in packets], [20, 10])

    def test_original_observations_pass_through_without_word_fabrication(self):
        actual = SourceFontObservations(
            original_word_members=[{'text': 'actual word', 'polygon': [[1, 2]]}],
            glyph_arrays={'owned': np.array([[1]])},
            rf_arrays={'probabilities': np.array([[.9]])})
        _, context = runtime.infer_packets(self.bundle, self.packets(),
            return_context=True, source_observations=[actual, None])
        self.assertIs(context.source_observations[0], actual)
        self.assertIsNone(context.source_observations[1])
        with self.assertRaisesRegex(ValueError, 'order and count'):
            runtime.infer_packets(self.bundle, self.packets(),
                return_context=True, source_observations=[actual])
        with self.assertRaisesRegex(ValueError, 'require return_context'):
            runtime.infer_packets(self.bundle, self.packets(), source_observations=[actual, None])

    def test_empty_context_has_no_fabricated_measurements_or_io(self):
        for stages in (False, True):
            result = runtime.infer_packets(self.bundle, [], return_stages=stages, return_context=True)
            self.assertEqual(result[-1].packets, ())
            self.assertEqual(result[-1].fresh_font_signals, {})
            self.assertEqual(result[-1].final_source_ems.shape, (0,))
        receipts, context = runtime.estimate_page(self.bundle, [], 'absent', 'absent', 'absent',
                                                 return_context=True)
        self.assertEqual(receipts, [])
        self.assertEqual(context.crop_bounds, ())
        self.assertEqual(self.calls, [])
        self.assertEqual(runtime.estimate_page(self.bundle, [], 'absent', 'absent', 'absent'), [])

    def test_render_producer_preserves_receipts_priors_order_and_source_geometry(self):
        items = [dict(id='z', frame=[20, 30, 10, 20], fontReference=20.,
                      sourcePredictedStyle={'sourceOnly': True},
                      sourceMemberPolygons=[[[20, 30], [30, 50]]]),
                 dict(id='a', frame=[0, 0, 20, 10], fontReference=10.)]
        def measure_packet(bundle, rgb, bbox, prior, text, ownership, page_size,
                           center, source_hash, confidence, role, **kwargs):
            return dict(rgb=rgb, bbox=bbox, prior=prior, text=text, ownership=ownership,
                        pageSize=page_size, sourceHash=source_hash, native=np.zeros(156),
                        evidence=np.zeros(291), **kwargs)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'source.png'
            Image.new('RGB', (100, 100), 'white').save(path)
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            arguments = (str(path), sha, 'test-model')
            metadata = dict(source_texts={'z': 'paragraph, not word records', 'a': 'other'},
                            mask_metadata={}, source_confidences={'z': .9, 'a': .8},
                            source_roles={'z': 'dialogue', 'a': 'sfx'})
            with patch('estimator.load_model', return_value=self.bundle), \
                    patch.object(runtime, 'predicted_mask', return_value=np.ones((100, 100), bool)), \
                    patch.object(runtime, 'measure_packet', side_effect=measure_packet):
                default_items = copy.deepcopy(items)
                default = font_size_runtime.estimate_page(default_items, *arguments, **metadata)
                receipts, context = font_size_runtime.estimate_page(items, *arguments, **metadata,
                                                                   return_context=True)
        self.assertEqual(receipts, default)
        self.assertEqual(items, default_items)
        self.assertEqual([r['id'] for r in receipts], ['z', 'a'])
        self.assertEqual([p['sourceRegionID'] for p in context.packets], ['z', 'a'])
        self.assertEqual(context.crop_bounds, ((18, 27, 32, 53), (0, 0, 23, 12)))
        self.assertEqual(context.packets[0]['bbox'], [2, 3, 10, 20])
        self.assertEqual(context.packets[0]['rgb'].shape, (26, 14, 3))
        self.assertEqual(context.source_observations, (None, None))
        self.assertNotIn('words', context.packets[0])
        np.testing.assert_array_equal(context.original_priors, [20, 10])
        np.testing.assert_array_equal(context.final_source_ems, [23, 13])
        self.assertFalse(any('renderBold' in item or 'sourceFontWeight' in item for item in items))

    def test_nonoptimized_context_is_explicit_even_for_empty_items(self):
        with patch('estimator.load_model', return_value={'featureVersion': 4}):
            with self.assertRaisesRegex(NotImplementedError, 'optimized source graph'):
                font_size_runtime.estimate_page([], 'absent', 'absent', 'model', return_context=True)
            self.assertEqual(font_size_runtime.estimate_page([], 'absent', 'absent', 'model'), [])

    def test_bridge_forwards_actual_observations_without_resolving_ids(self):
        observations = [SourceFontObservations(original_word_members=[])]
        marker = object()
        with patch('estimator.load_model', return_value=self.bundle), \
                patch.object(runtime, 'estimate_page', return_value=marker) as run:
            result = font_size_runtime.estimate_page([{'id': 'no-resource'}],
                'absent', 'source', 'model', return_context=True, source_observations=observations)
        self.assertIs(result, marker)
        self.assertIs(run.call_args.kwargs['source_observations'], observations)
        self.assertTrue(run.call_args.kwargs['return_context'])

    def test_context_rejects_misaligned_fresh_signal_arrays(self):
        for name in ('style187', 'angles131'):
            signals = {'style187': np.zeros((2, 262)), 'angles131': np.zeros(2)}
            signals[name] = signals[name][:1]
            with patch('optimized_measurements.measure_packets', return_value=signals), \
                    patch.object(runtime, 'predict_optimized', return_value=np.array([23., 13.])):
                with self.assertRaisesRegex(ValueError, name):
                    runtime.infer_packets(self.bundle, self.packets(), return_context=True)


if __name__ == '__main__':
    unittest.main()
