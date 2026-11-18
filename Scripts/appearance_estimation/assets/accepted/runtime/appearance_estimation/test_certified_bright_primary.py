"""Focused native-raster primary, warm transport, and shadow-context contracts."""
import copy
import json
import unittest
from unittest.mock import patch

# Initialize optional accelerator guards before importing sklearn consumers.
import optimize_appearance  # noqa: F401
import numpy as np

import certified_bright_palette as palette
import certified_bright_primary as primary
import owned_palette as owned
import source_gradient_contour as stage
import source_shadow_observation as shadow
from source_appearance import lab
from test_certified_bright_palette import synthetic


def fresh(args):
    return stage._refine_contour(*args)[1]


class CertifiedBrightPrimaryTests(unittest.TestCase):
    def test_white_primary_and_background_infer_native_yellow_gradient_medoid(self):
        args = synthetic()
        before = copy.deepcopy(args[4])
        diagnostic = fresh(args)
        self.assertEqual(diagnostic['mechanism'], 'bounded-bright-interiors')
        self.assertIs(diagnostic['semantic']['accepted'], True)
        native = copy.deepcopy(args[4])
        native['outline']['rgb'] = diagnostic['sourceObservation']['rgb']
        observation = palette.propose(*args[:4], native)
        bodies = observation['bodies']
        self.assertEqual(len(bodies), 3)
        self.assertFalse(observation['cropResized'])
        self.assertFalse(observation['bboxHardClip'])
        pixels = np.concatenate([b['pixels'] for b in bodies])
        ll = np.concatenate([b['lab'] for b in bodies])
        xy = np.concatenate([b['xy'] for b in bodies])
        support = np.concatenate([b['support'] for b in bodies])
        medians = np.array([np.median(b['lab'], axis=0) for b in bodies])
        candidates = np.flatnonzero(support)
        selected = candidates[np.argmin(np.linalg.norm(
            ll[candidates] - np.median(medians, axis=0), axis=1))]
        colour, evidence = primary.infer(*args[:5], diagnostic)
        self.assertIs(evidence['eligible'], True)
        self.assertEqual(evidence['version'], primary.VERSION)
        self.assertIs(evidence['sourceOnly'], True)
        self.assertIs(evidence['GTAtInference'], False)
        self.assertEqual(evidence['sourceDiagnostic'], diagnostic)
        self.assertEqual(evidence['bodies'], 3)
        self.assertEqual(evidence['sourceBodySupportFractions'], [1.] * 3)
        self.assertEqual(evidence['nativeInteriorPixels'], 3 * 28 * 16)
        self.assertEqual(colour, pixels[selected].tolist())
        self.assertEqual(evidence['exactNativeRGB'], colour)
        self.assertEqual(evidence['exactNativeXY'], xy[selected].tolist())
        self.assertNotEqual(colour, [255] * 3)
        self.assertGreater(colour[0], colour[2])
        self.assertGreater(colour[1], colour[2])
        np.testing.assert_array_equal(evidence['bodyMedianLab'], medians)
        self.assertTrue(np.all(np.linalg.norm(medians - lab([colour])[0], axis=1) <= 10))
        old_coverage = float((np.linalg.norm(ll - lab([[255] * 3])[0], axis=1) <= 10).mean())
        new_coverage = float((np.linalg.norm(ll - lab([colour])[0], axis=1) <= 10).mean())
        self.assertAlmostEqual(evidence['oldPrimaryCoverage'], old_coverage)
        self.assertAlmostEqual(evidence['newPrimaryCoverage'], new_coverage)
        self.assertLess(old_coverage, .1)
        self.assertGreaterEqual(new_coverage, .2)
        self.assertEqual({w['body'] for w in evidence['witnesses']}, {0, 1, 2})
        for witness in evidence['witnesses']:
            x, y = witness['xy']
            body = bodies[witness['body']]
            self.assertEqual(args[0][y, x].tolist(), witness['rgb'])
            self.assertTrue(owned.supported(args[2], np.array([y]), np.array([x]))[0])
            distance = np.linalg.norm(body['lab'] - lab([colour])[0], axis=1)
            self.assertEqual(witness['supportedPixels'], int((body['support'] & (distance <= 10)).sum()))
            self.assertGreaterEqual(witness['supportedPixels'], 3)
            self.assertAlmostEqual(witness['deltaE'], float(np.linalg.norm(lab([witness['rgb']])[0] - lab([colour])[0])), places=4)
        primary.validate(evidence, args[0])
        self.assertEqual(args[4], before)

    def test_already_supported_old_primary_abstains(self):
        args = synthetic()
        diagnostic = fresh(args)
        colour, _ = primary.infer(*args[:5], diagnostic)
        args[4]['fill']['rgb'] = colour
        args[4]['fill']['colors'] = [colour, [255] * 3]
        before = copy.deepcopy(args[4])
        out, evidence = primary.attach(*args[:5], diagnostic)
        self.assertEqual(out, before)
        self.assertFalse(evidence['eligible'])
        self.assertEqual(evidence['reason'], 'Old primary still explains source')
        self.assertGreaterEqual(evidence['oldPrimaryCoverage'], .1)
        self.assertNotIn(primary.TAG, out['fill'])

    def test_one_weak_native_body_abstains_despite_fresh_certificate(self):
        diagnostic = fresh(synthetic())
        for channel in ('rf', 'seg', 'ocr'):
            with self.subTest(channel=channel):
                args = synthetic()
                arrays = args[2]
                if channel == 'rf':
                    arrays['rf'][:, 78:102] = 0
                elif channel == 'seg':
                    arrays['segPrimary'][:, 78:102] = .49
                else:
                    arrays['ocr'][:, 78:102, 4] = .19
                colour, evidence = primary.infer(*args[:5], diagnostic)
                self.assertIsNone(colour)
                self.assertFalse(evidence['eligible'])
                self.assertEqual(evidence['reason'], 'Insufficient source bodies')
                self.assertEqual(stage.refine(*args)[0]['fill'], args[4]['fill'])

    def test_disagreeing_native_body_medians_abstain(self):
        args = synthetic()
        diagnostic = fresh(args)
        args[0][11:41, 81:99] = [245, 150, 245]
        colour, evidence = primary.infer(*args[:5], diagnostic)
        self.assertIsNone(colour)
        self.assertFalse(evidence['eligible'])
        self.assertEqual(evidence['reason'], 'Body medians disagree')

    def test_missing_or_rejected_fresh_certificate_abstains(self):
        args = synthetic()
        diagnostic = fresh(args)
        for replacement in ({}, {**diagnostic, 'mechanism': 'confirmed-gradient-body'},
                            {**diagnostic, 'semantic': {'accepted': False}},
                            {**diagnostic, 'semantic': {'accepted': 1}}):
            with self.subTest(diagnostic=replacement):
                colour, evidence = primary.infer(*args[:5], replacement)
                self.assertIsNone(colour)
                self.assertFalse(evidence['eligible'])

    def test_exact_native_witness_tamper_rejected(self):
        args = synthetic()
        _, evidence = primary.infer(*args[:5], fresh(args))
        primary.validate(evidence, args[0])
        mutations = {
            'exact coordinate': lambda e: e.update(exactNativeXY=[0, 0]),
            'exact RGB': lambda e: e.update(exactNativeRGB=[1, 2, 3]),
            'out of bounds': lambda e: e.update(exactNativeXY=[116, 0]),
            'fractional coordinate': lambda e: e.update(exactNativeXY=[11.5, 12]),
            'body coordinate': lambda e: e['witnesses'][0].update(xy=[0, 0]),
            'body RGB': lambda e: e['witnesses'][0].update(rgb=[1, 2, 3]),
            'missing body': lambda e: e['witnesses'].pop(),
            'weak source': lambda e: e['sourceBodySupportFractions'].__setitem__(0, .94),
            'old coverage': lambda e: e.update(oldPrimaryCoverage=.1),
            'new coverage': lambda e: e.update(newPrimaryCoverage=.19),
            'median disagreement': lambda e: e['bodyMedianLab'].__setitem__(0, [0., 0., 0.]),
            'missing semantic': lambda e: e['sourceDiagnostic'].pop('semantic'),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                bad = copy.deepcopy(evidence)
                mutate(bad)
                with self.assertRaises(ValueError):
                    primary.validate(bad, args[0])
        for coordinate in [evidence['exactNativeXY']] + [w['xy'] for w in evidence['witnesses']]:
            with self.subTest(changed_source=coordinate):
                changed = args[0].copy()
                x, y = coordinate
                changed[y, x] = [0, 0, 0]
                with self.assertRaisesRegex(ValueError, 'Native primary witness'):
                    primary.validate(evidence, changed)

    def test_attach_moves_existing_selected_rgb_without_duplicates_and_restores_exactly(self):
        args = synthetic()
        diagnostic = fresh(args)
        colour, _ = primary.infer(*args[:5], diagnostic)
        # Existing selected colours may occur more than once in transported input.
        for repeats in (0, 1, 2):
            with self.subTest(existing_selected=repeats):
                prediction = copy.deepcopy(args[4])
                prediction['fill']['colors'] += [colour] * repeats + [[255, 220, 90]]
                before = copy.deepcopy(prediction)
                out, evidence = primary.attach(*args[:4], prediction, diagnostic)
                previous = before['fill']['colors']
                self.assertEqual(out['fill']['colors'], [colour] + [c for c in previous if c != colour])
                self.assertEqual(out['fill']['colors'].count(colour), 1)
                self.assertEqual({tuple(c) for c in out['fill']['colors']}, {tuple(c) for c in previous + [colour]})
                self.assertEqual(out['fill'][primary.TAG]['previousColors'], previous)
                self.assertEqual(out['fill'][primary.TAG]['sourceEvidence'], evidence)
                transported = json.loads(json.dumps(out))
                snapshot = copy.deepcopy(transported)
                self.assertEqual(primary.restore_baseline(transported), before)
                self.assertEqual(stage.restore_baseline(transported), before)
                self.assertEqual(primary.attach(*args[:4], transported, diagnostic), (out, evidence))
                self.assertEqual(transported, snapshot)
                self.assertEqual(prediction, before)

    def test_current_primary_palette_tag_order_full_restore_and_repeated_warm_refine(self):
        args = synthetic()
        before = copy.deepcopy(args[4])
        out, report = stage.refine(*args)
        fill = out['fill']
        primary_tag = fill[primary.TAG]
        palette_tag = fill[stage.PALETTE_TAG]
        self.assertEqual(palette_tag['version'], stage.POLICY_VERSION)
        self.assertEqual(palette_tag['primaryRGB'], before['fill']['rgb'])
        self.assertEqual(palette_tag['previousColors'], before['fill']['colors'])
        previous = palette_tag['previousColors'] + palette_tag['addedRGB']
        self.assertEqual(primary_tag['previousColors'], previous)
        self.assertEqual(primary_tag['previousRGB'], before['fill']['rgb'])
        self.assertEqual(fill['colors'], [fill['rgb']] + [c for c in previous if c != fill['rgb']])
        self.assertEqual(len(fill['colors']), len({tuple(c) for c in fill['colors']}))
        self.assertEqual(primary_tag['sourceEvidence'], report['fillPrimaryObservation'])
        self.assertEqual(palette_tag['sourceEvidence'], report['fillPaletteObservation'])
        peeled = primary.restore_baseline(out)
        self.assertNotIn(primary.TAG, peeled['fill'])
        self.assertEqual(peeled['fill'][stage.PALETTE_TAG], palette_tag)
        self.assertEqual(peeled['fill']['colors'], previous)
        self.assertEqual(peeled['outline'], out['outline'])
        transported = json.loads(json.dumps(out))
        for _ in range(3):
            snapshot = copy.deepcopy(transported)
            self.assertEqual(stage.restore_baseline(transported), before)
            warm = list(args)
            warm[4] = transported
            again, diagnostic = stage.refine(*warm)
            self.assertEqual((again, diagnostic), (out, report))
            self.assertEqual(transported, snapshot)
            transported = json.loads(json.dumps(again))
        self.assertEqual(args[4], before)

    def test_legacy_v4_palette_only_transport_still_restores_and_refines(self):
        args = synthetic()
        before = copy.deepcopy(args[4])
        out, report = stage.refine(*args)
        # Removing just the late primary yields the real v4 append-only layout.
        legacy = primary.restore_baseline(out)
        legacy['fill'][stage.PALETTE_TAG]['version'] = 'source-confirmed-contour-owned-palette-v4'
        transported = json.loads(json.dumps(legacy))
        snapshot = copy.deepcopy(transported)
        self.assertEqual(stage.restore_baseline(transported), before)
        warm = list(args)
        warm[4] = transported
        self.assertEqual(stage.refine(*warm), (out, report))
        self.assertEqual(transported, snapshot)

    def test_warm_primary_palette_tamper_rejected(self):
        args = synthetic()
        out, _ = stage.refine(*args)
        for kind in ('rgb', 'duplicate', 'order', 'tag', 'palette'):
            with self.subTest(mutation=kind):
                bad = copy.deepcopy(out)
                fill = bad['fill']
                if kind == 'rgb':
                    fill['rgb'] = [0, 0, 0]
                elif kind == 'duplicate':
                    fill['colors'].append(fill['rgb'])
                elif kind == 'order':
                    fill['colors'].reverse()
                elif kind == 'tag':
                    fill[primary.TAG]['version'] = 'stale'
                else:
                    fill[stage.PALETTE_TAG]['primaryRGB'] = fill['rgb']
                with self.assertRaises(ValueError):
                    stage.restore_baseline(bad)

    def test_shadow_peels_only_late_primary_for_attach_and_width_measurement(self):
        args = synthetic()
        corrected, _ = stage.refine(*args)
        descriptor = primary.restore_baseline(corrected)
        self.assertNotEqual(descriptor['fill']['rgb'], corrected['fill']['rgb'])
        self.assertIn(stage.PALETTE_TAG, descriptor['fill'])
        self.assertIn('gradientContourCorrection', descriptor['outline'])
        for model in (None, {}, {'adaptiveNormalRefinement': {'present': True}}):
            with self.subTest(width_model=model):
                prediction = copy.deepcopy(corrected)
                before = copy.deepcopy(prediction)
                adaptive = bool(model)

                def observe(rgb, mask, arrays, geometry, observed, pixel, packet):
                    expected = copy.deepcopy(descriptor)
                    if adaptive:
                        expected['outline']['widthPx'] = 4.
                    self.assertEqual(observed, expected)
                    self.assertNotIn(primary.TAG, observed['fill'])
                    observed['fill']['rgb'] = [9, 9, 9]
                    observed['fill']['colors'].clear()
                    observed['outline']['rgb'] = [0, 0, 0]
                    observed['shadow'] = dict(present=True, offsetPx=[3, 3])

                def width_features(packet, observed, vector, width_model):
                    self.assertEqual(observed, descriptor)
                    return np.zeros(662)

                call_args = list(args)
                call_args[4] = prediction
                with patch.object(shadow, 'attach', side_effect=observe) as attach, \
                        patch('calibrate_width.measure', return_value=({}, np.zeros(8))) as measure, \
                        patch('calibrate_width.width_features', side_effect=width_features) as features, \
                        patch('width_resolution.reference_predict', return_value=[4.]) as reference:
                    out = shadow.attach_with_width_context(*call_args, width_model=model)
                self.assertIs(out, prediction)
                attach.assert_called_once()
                if adaptive:
                    measure.assert_called_once_with(args[0], args[1], descriptor['fill']['rgb'], descriptor['outline']['rgb'])
                    features.assert_called_once()
                    reference.assert_called_once()
                    context = out['shadow']['sourceObservation']['widthContext']
                    self.assertEqual(context['referenceWidthPx'], 4.)
                    self.assertEqual(context['emittedStyleWidthPx'], before['outline']['widthPx'])
                else:
                    measure.assert_not_called()
                    features.assert_not_called()
                    reference.assert_not_called()
                self.assertEqual(out['shadow']['offsetPx'], [3, 3])
                self.assertEqual({k: v for k, v in out.items() if k != 'shadow'},
                                 {k: v for k, v in before.items() if k != 'shadow'})


if __name__ == '__main__':
    unittest.main()
