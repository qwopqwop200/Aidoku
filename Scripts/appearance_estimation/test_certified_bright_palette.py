"""Small native-raster contracts for certified bright fill; no pages or labels."""
import copy
import json
import unittest

# This initializes the repository's optional accelerator guards before sklearn.
import optimize_appearance  # noqa: F401
import numpy as np

import certified_bright_palette as bright
import owned_palette as owned
import source_gradient_contour as stage


def synthetic(bodies=3, chromatic=True):
    """Repeated gradient interiors enclosed by a varying, three-pixel ring."""
    rgb = np.full((52, 116, 3), 255, np.uint8)
    mask = np.zeros(rgb.shape[:2], bool)
    polygons = []
    for i in range(bodies):
        x = 8 + 35 * i
        for y in range(8, 44):
            shade = (y - 8) // 3 - 5
            colour = np.array([140, 95, 45]) + shade
            rgb[y, x:x + 24] = colour if chromatic else [110 + shade] * 3
        for y in range(11, 41):
            t = (y - 11) / 29
            rgb[y, x + 3:x + 21] = np.rint(
                (1 - t) * np.array([255, 255, 245]) + t * np.array([255, 220, 90]))
        mask[8:44, x:x + 24] = True
        # Seed a majority, but not all, of each interior: these are not crops.
        polygons.append([[x + 3, 16], [x + 20, 16], [x + 20, 35], [x + 3, 35]])
    h, w = mask.shape
    arrays = dict(rf=np.zeros((h, w, 27), np.float32),
                  segPrimary=mask.astype(np.float32),
                  segBoundary=np.zeros((h, w), np.float32),
                  ocr=np.ones((h, w, 8), np.float32))
    arrays['rf'][:, :, 15:17] = 1
    prediction = dict(fillIndex=0, outlineIndex=1, backgroundIndex=0,
                      fill=dict(rgb=[255] * 3, colors=[[255] * 3],
                                representation='source-fusion-observed-palette'),
                      outline=dict(present=True, rgb=[200] * 3, probability=.9,
                                   widthPx=3., widthRangePx=[2., 4.]),
                      background=dict(rgb=[255] * 3, colors=[[255] * 3]),
                      shadow=dict(present=False, rgb=None))
    geometry = dict(polygons=polygons, fontPixels=30.)
    packet = dict(colors=[[255] * 3, [140, 95, 45] if chromatic else [110] * 3])
    # The bright route uses direct RF/seg/OCR evidence, not a role classifier.
    return [rgb, mask, arrays, geometry, prediction, None, packet]


def fresh(args):
    return stage._refine_contour(*args)[1]


def infer(args, diagnostic=None):
    return bright.infer(*args[:5], fresh(args) if diagnostic is None else diagnostic)


class CertifiedBrightPaletteTests(unittest.TestCase):
    def test_variable_ring_native_bodies_and_exact_repeated_witnesses(self):
        args = synthetic()
        rgb, mask, arrays, geometry, prediction = args[:5]
        before = copy.deepcopy(prediction)
        diagnostic = fresh(args)
        self.assertEqual(diagnostic['mechanism'], 'bounded-bright-interiors')
        self.assertTrue(diagnostic['semantic']['accepted'])
        self.assertEqual(sum(h['confirmed'] for h in diagnostic['semantic']['holes']), 3)
        native = copy.deepcopy(prediction)
        native['outline']['rgb'] = diagnostic['sourceObservation']['rgb']
        observation = bright.propose(rgb, mask, arrays, geometry, native)
        self.assertTrue(observation['eligible'])
        self.assertEqual(len(observation['bodies']), 3)
        self.assertFalse(observation['cropResized'])
        self.assertFalse(observation['bboxHardClip'])
        self.assertGreater(len(np.unique(rgb[8:44, 8], axis=0)), 1)
        for body in observation['bodies']:
            self.assertEqual(body['sourceSupportFraction'], 1.)
            self.assertEqual(body['interiorPixels'], (30 - 2) * (18 - 2))
            self.assertGreater(len(np.unique(body['pixels'], axis=0)), 10)
            xy = body['xy']
            np.testing.assert_array_equal(body['pixels'], rgb[xy[:, 1], xy[:, 0]])
            self.assertLess(int(xy[:, 1].min()), 16)
            self.assertGreater(int(xy[:, 1].max()), 35)
        additions, evidence = infer(args, diagnostic)
        self.assertTrue(evidence['eligible'])
        self.assertGreater(len(additions), 0)
        self.assertLessEqual(len(additions), 3)
        self.assertFalse(evidence['GTAtInference'])
        self.assertEqual(evidence['version'], bright.VERSION)
        n = evidence['nativeBodyReport']['nativeInteriorPixels']
        for colour, selected in zip(additions, evidence['selectedAdditions']):
            self.assertEqual(colour, selected['rgb'])
            x, y = selected['exactRGBWitnessXY']
            self.assertEqual(rgb[y, x].tolist(), colour)
            self.assertNotIn(colour, prediction['fill']['colors'])
            self.assertGreaterEqual(selected['gainPixels'], max(12, .1 * n))
            self.assertGreaterEqual(len(set(selected['components'])), 2)
            self.assertEqual(set(selected['components']), {w['body'] for w in selected['witnesses']})
            for witness in selected['witnesses']:
                x, y = witness['xy']
                self.assertEqual(rgb[y, x].tolist(), witness['rgb'])
                self.assertGreaterEqual(witness['supportedNewPixels'], 3)
                self.assertLessEqual(witness['deltaE'], 10.)
                self.assertTrue(owned.supported(arrays, np.array([y]), np.array([x]))[0])
        bright.validate(evidence, additions, rgb)
        owned.validate_additions(evidence, additions, rgb)
        self.assertEqual(prediction, before)

    def test_owned_branch_append_phase_and_current_stage_roundtrip(self):
        args = synthetic()
        before = copy.deepcopy(args[4])
        diagnostic = fresh(args)
        expected = infer(args, diagnostic)
        self.assertEqual(owned._from_fresh_contour(*args, diagnostic), expected)
        self.assertEqual(owned.infer(*args), expected)
        contour, _ = stage._refine_contour(*args)
        out, report = stage.refine(*args)
        additions, evidence = expected
        self.assertEqual(report['fillPaletteObservation'], evidence)
        from certified_bright_primary import restore_baseline as restore_primary_fill
        # Inspect the unchanged append-only phase before the separately tested primary head.
        palette_only = restore_primary_fill(out)
        self.assertEqual(palette_only['fill']['rgb'], before['fill']['rgb'])
        self.assertEqual(palette_only['fill']['colors'], before['fill']['colors'] + additions)
        tag = palette_only['fill'][stage.PALETTE_TAG]
        self.assertEqual(tag['version'], stage.POLICY_VERSION)
        self.assertEqual(tag['policyVersion'], owned.POLICY['version'])
        self.assertEqual(tag['sourceEvidence'], evidence)
        stripped = copy.deepcopy(palette_only)
        stripped['fill']['colors'] = copy.deepcopy(before['fill']['colors'])
        del stripped['fill'][stage.PALETTE_TAG]
        self.assertEqual(stripped, contour)
        self.assertEqual(args[4], before)
        transported = json.loads(json.dumps(out))
        self.assertEqual(stage.restore_baseline(transported), before)
        warm = list(args)
        warm[4] = transported
        self.assertEqual(stage.refine(*warm), (out, report))
        self.assertEqual(owned.infer(*warm), expected)

    def test_missing_or_rejected_fresh_semantic_certificate_abstains(self):
        args = synthetic()
        diagnostic = fresh(args)
        variants = [{}, {**diagnostic, 'mechanism': 'confirmed-gradient-body'}]
        for semantic in ({}, {'accepted': False}, {'accepted': 1}):
            variants.append({**diagnostic, 'semantic': semantic})
        for candidate in variants:
            with self.subTest(diagnostic=candidate):
                additions, evidence = infer(args, candidate)
                self.assertEqual(additions, [])
                self.assertFalse(evidence['eligible'])

    def test_fewer_than_three_native_bodies_abstains_even_with_stale_certificate(self):
        diagnostic = fresh(synthetic())
        for count in (0, 1, 2):
            with self.subTest(bodies=count):
                args = synthetic(bodies=count)
                additions, evidence = infer(args, diagnostic)
                self.assertEqual(additions, [])
                self.assertFalse(evidence['eligible'])
                self.assertEqual(stage.refine(*args)[0], args[4])

    def test_insufficient_rf_seg_or_ocr_support_abstains(self):
        diagnostic = fresh(synthetic())
        for kind in ('rf', 'seg', 'ocr-box', 'ocr-detector', 'ocr-recognizer'):
            with self.subTest(support=kind):
                args = synthetic()
                arrays = args[2]
                if kind == 'rf':
                    arrays['rf'][:] = 0
                elif kind == 'seg':
                    arrays['segPrimary'][:] = .49
                    arrays['segBoundary'][:] = .49
                elif kind == 'ocr-box':
                    arrays['ocr'][:, :, 0] = 0
                elif kind == 'ocr-detector':
                    arrays['ocr'][:, :, 2] = .19
                else:
                    arrays['ocr'][:, :, 4] = .19
                additions, evidence = infer(args, diagnostic)
                self.assertEqual(additions, [])
                self.assertFalse(evidence['eligible'])
                # The ring corroborator does not gate recognizer confidence;
                # the native fill branch must independently reject it.
                self.assertEqual(stage.refine(*args)[0]['fill'], args[4]['fill'])

    def test_achromatic_contour_and_disabled_outline_abstain(self):
        args = synthetic(chromatic=False)
        diagnostic = fresh(args)
        self.assertEqual(diagnostic['mechanism'], 'bounded-bright-interiors')
        self.assertTrue(diagnostic['semantic']['accepted'])
        additions, evidence = infer(args, diagnostic)
        self.assertEqual(additions, [])
        self.assertFalse(evidence['eligible'])
        self.assertEqual(stage.refine(*args)[0]['fill'], args[4]['fill'])
        args = synthetic()
        args[4]['outline']['present'] = False
        self.assertEqual(infer(args, fresh(synthetic()))[0], [])

    def test_already_covered_palette_has_no_additions(self):
        args = synthetic()
        diagnostic = fresh(args)
        # Cover every actual gradient colour, without relying on selected RGBs.
        args[4]['fill']['colors'] += np.unique(args[0][11:41, 11], axis=0).tolist()
        additions, evidence = infer(args, diagnostic)
        self.assertEqual(additions, [])
        self.assertFalse(evidence['eligible'])

    def test_native_validation_rejects_missing_or_altered_evidence(self):
        args = synthetic()
        additions, evidence = infer(args)

        def selected(ev):
            # deepcopy preserves aliasing with nativeBodyReport.additions;
            # mutations therefore remain internally consistent in the report.
            return ev['selectedAdditions'][0]

        mutations = {
            'version': lambda ev: ev.update(version='stale'),
            'semantic absent': lambda ev: ev['diagnostic'].pop('semantic'),
            'semantic rejected': lambda ev: ev['diagnostic']['semantic'].update(accepted=False),
            'too few confirmed holes': lambda ev: ev['diagnostic']['semantic'].update(holes=[{'confirmed': True}] * 2),
            'missing exact RGB': lambda ev: selected(ev).pop('rgb'),
            'missing exact coordinate': lambda ev: selected(ev).pop('exactRGBWitnessXY'),
            'off-source exact coordinate': lambda ev: selected(ev).update(exactRGBWitnessXY=[0, 0]),
            'out of bounds': lambda ev: selected(ev).update(exactRGBWitnessXY=[args[0].shape[1], 0]),
            'negative coordinate': lambda ev: selected(ev).update(exactRGBWitnessXY=[-1, 0]),
            'fractional coordinate': lambda ev: selected(ev).update(exactRGBWitnessXY=[11.5, 12]),
            'missing body RGB': lambda ev: selected(ev)['witnesses'][0].pop('rgb'),
            'altered body RGB': lambda ev: selected(ev)['witnesses'][0].update(rgb=[1, 2, 3]),
            'missing body coordinate': lambda ev: selected(ev)['witnesses'][0].pop('xy'),
            'altered body coordinate': lambda ev: selected(ev)['witnesses'][0].update(xy=[0, 0]),
            'one repeated body': lambda ev: selected(ev).update(components=[0], witnesses=selected(ev)['witnesses'][:1]),
            'missing report certificate': lambda ev: ev.pop('nativeBodyReport'),
            'missing selected certificate': lambda ev: ev.pop('selectedAdditions'),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                bad = copy.deepcopy(evidence)
                mutate(bad)
                for validator in (bright.validate, owned.validate_additions):
                    with self.assertRaises(ValueError):
                        validator(bad, additions, args[0])
        # Alter both transported palette and certificate RGB: only native binding
        # distinguishes this from a self-consistent fabricated colour.
        bad = copy.deepcopy(evidence)
        selected(bad)['rgb'] = [1, 2, 3]
        changed = [ev['rgb'] for ev in bad['selectedAdditions']]
        with self.assertRaises(ValueError):
            bright.validate(bad, changed, args[0])
        with self.assertRaises(ValueError):
            bright.validate(evidence, [], args[0])
        changed_source = args[0].copy()
        x, y = evidence['selectedAdditions'][0]['exactRGBWitnessXY']
        changed_source[y, x] = [0, 0, 0]
        with self.assertRaises(ValueError):
            bright.validate(evidence, additions, changed_source)

    def test_v4_warm_restore_rejects_broken_transport(self):
        args = synthetic()
        out, _ = stage.refine(*args)
        for kind in ('primary', 'palette', 'certificate', 'tag'):
            with self.subTest(mutation=kind):
                bad = copy.deepcopy(out)
                if kind == 'primary':
                    bad['fill']['rgb'] = [0, 0, 0]
                elif kind == 'palette':
                    bad['fill']['colors'].pop()
                elif kind == 'certificate':
                    bad['fill'][stage.PALETTE_TAG]['sourceEvidence']['diagnostic'].pop('semantic')
                else:
                    bad['fill'][stage.PALETTE_TAG]['version'] = 'stale'
                with self.assertRaises(ValueError):
                    stage.restore_baseline(bad)

    def test_legacy_v3_nonbright_certificate_restores_without_input_mutation(self):
        # Generate legacy gradient-body evidence from a separate tiny raster,
        # rather than disguising a v4 bright certificate with an older tag.
        args = synthetic()
        args[4]['fill']['rgb'] = [255, 220, 90]
        args[4]['fill']['colors'] = [[255, 220, 90]]
        args[3]['polygons'] = []
        from pixel_role_estimation import features

        class KnownFill:
            classes_ = np.arange(4)

            def predict_proba(self, matrix):
                return np.tile([.99, .005, .005, 0.], (len(matrix), 1))

        _, names = features(*args[:2], args[2]['rf'], args[2]['segPrimary'],
                            args[2]['segBoundary'], args[2]['ocr'], args[3], args[4], [0])
        args[5] = dict(classifier=KnownFill(), probabilityThreshold=.8, featureNames=names)
        baseline = copy.deepcopy(args[4])
        out, diagnostic = stage.refine(*args)
        self.assertEqual(diagnostic['mechanism'], 'confirmed-gradient-body')
        tag = out['fill'][stage.PALETTE_TAG]
        self.assertTrue(tag['addedRGB'])
        self.assertNotIn('version', tag['sourceEvidence'])
        tag['version'] = 'source-confirmed-contour-owned-palette-v3'
        tag['policyVersion'] = 'independent-contour-native-marginal-coverage-v1'
        transported = json.loads(json.dumps(out))
        before = copy.deepcopy(transported)
        owned.validate_additions(tag['sourceEvidence'], tag['addedRGB'], args[0])
        self.assertEqual(stage.restore_baseline(transported), baseline)
        self.assertEqual(transported, before)
        warm = list(args)
        warm[4] = transported
        self.assertEqual(stage.refine(*warm), stage.refine(*args))


if __name__ == '__main__':
    unittest.main()
