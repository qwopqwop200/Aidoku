"""Analytical native-raster pruning and selection guards; no pages or labels."""
import copy
import json
import unittest

# Install optional accelerator guards before any sklearn consumer is imported.
import optimize_appearance  # noqa: F401
import numpy as np

import certified_bright_palette as bright
import certified_bright_primary as primary
import certified_interior_palette as pruning
import continuous_optimize as optimize
import source_gradient_contour as stage
from paint_palette_metrics import measure, predicted_colours
from source_appearance import lab
from pixel_role_estimation import features
from test_certified_bright_palette import synthetic


INVALID = [15, 25, 230]
MINORITY = [235, 35, 165]


class RejectGradientSeeds:
    """Keep this fixture on the independent bright route, not the role route."""
    classes_ = np.arange(4)

    def predict_proba(self, matrix):
        return np.tile([0., 1., 0., 0.], (len(matrix), 1))


def fresh(args):
    return stage._refine_contour(*args)[1]


def fixture():
    args = synthetic()
    # This point is inside the eroded native body, away from the enclosing ring.
    args[0][24, 18] = MINORITY
    args[4]['fill']['colors'] += [args[0][32, 18].tolist(), MINORITY, INVALID]
    _, names = features(*args[:2], args[2]['rf'], args[2]['segPrimary'],
                        args[2]['segBoundary'], args[2]['ocr'], args[3], args[4], [0])
    args[5] = dict(classifier=RejectGradientSeeds(), probabilityThreshold=.8,
                   featureNames=names)
    return args


def infer(args, diagnostic=None):
    return pruning.infer(*args[:5], fresh(args) if diagnostic is None else diagnostic, 1)


class CertifiedInteriorPaletteTests(unittest.TestCase):
    def test_removes_only_unsupported_colours_with_analytical_native_counts(self):
        args = fixture()
        before = copy.deepcopy(args[4])
        diagnostic = fresh(args)
        retained, evidence = infer(args, diagnostic)
        self.assertEqual(retained, before['fill']['colors'][:-1])
        self.assertEqual(evidence['minimumPixels'], 1)
        self.assertEqual(evidence['version'], pruning.VERSION)
        self.assertIs(evidence['sourceOnly'], True)
        self.assertIs(evidence['GTAtInference'], False)
        self.assertEqual(evidence['sourceDiagnostic'], diagnostic)
        self.assertEqual(evidence['bodies'], 3)
        self.assertEqual(evidence['sourceBodySupportFractions'], [1.] * 3)
        self.assertEqual(evidence['nativeInteriorPixels'], 3 * 28 * 16)
        self.assertEqual(evidence['supportedInteriorPixels'], 3 * 28 * 16)
        native = copy.deepcopy(before)
        native['outline']['rgb'] = diagnostic['sourceObservation']['rgb']
        bodies = bright.propose(*args[:4], native)['bodies']
        ll = np.concatenate([b['lab'] for b in bodies])
        support = np.concatenate([b['support'] for b in bodies])
        for row in evidence['colours']:
            distances = np.linalg.norm(ll - lab([row['rgb']])[0], axis=1)
            self.assertEqual(row['supportedNativePixels'], int((support & (distances <= 10)).sum()))
            self.assertAlmostEqual(row['minimumNativeDeltaE'], float(distances[support].min()))
            self.assertEqual(sum(w['supportedPixels'] for w in row['bodyWitnesses']), row['supportedNativePixels'])
            for witness in row['bodyWitnesses']:
                x, y = witness['xy']
                self.assertEqual(args[0][y, x].tolist(), witness['rgb'])
        self.assertGreater(evidence['colours'][-1]['minimumNativeDeltaE'], 10)
        self.assertEqual(evidence['colours'][-1]['bodyWitnesses'], [])
        pruning.validate(evidence, before['fill']['colors'], retained, before['fill']['rgb'], args[0])
        self.assertEqual(args[4], before)

    def test_single_supported_minority_pixel_survives(self):
        args = fixture()
        retained, evidence = infer(args)
        row = evidence['colours'][2]
        self.assertEqual(row['rgb'], MINORITY)
        self.assertIn(MINORITY, retained)
        self.assertEqual(row['supportedNativePixels'], 1)
        self.assertEqual(row['bodyWitnesses'], [dict(body=0, supportedPixels=1, xy=[18, 24], rgb=MINORITY, deltaE=0.)])
        # Losing body RF support does not prove an observed colour is contour-only.
        args[2]['rf'][24, 18] = 0
        retained, evidence = infer(args)
        self.assertIn(MINORITY, retained)
        self.assertEqual(evidence['colours'][2]['supportedNativePixels'], 0)
        self.assertEqual(evidence['colours'][2]['minimumNativeCropDeltaE'], 0.)
        self.assertFalse(evidence['colours'][2]['boundaryExclusive'])

    def test_primary_is_retained_even_without_any_native_support(self):
        args = fixture()
        diagnostic = fresh(args)
        args[4]['fill']['rgb'] = INVALID
        args[4]['fill']['colors'][0] = INVALID
        retained, evidence = infer(args, diagnostic)
        self.assertEqual(retained[0], INVALID)
        self.assertTrue(evidence['colours'][0]['primary'])
        self.assertTrue(evidence['colours'][0]['kept'])
        self.assertEqual(evidence['colours'][0]['supportedNativePixels'], 0)
        pruning.validate(evidence, args[4]['fill']['colors'], retained, INVALID, args[0])

    def test_missing_fresh_certificate_abstains(self):
        args = fixture()
        diagnostic = fresh(args)
        for candidate in ({}, {**diagnostic, 'mechanism': 'confirmed-gradient-body'},
                          {**diagnostic, 'semantic': {}},
                          {**diagnostic, 'semantic': {'accepted': False}},
                          {**diagnostic, 'semantic': {'accepted': 1}}):
            with self.subTest(diagnostic=candidate):
                retained, evidence = infer(args, candidate)
                self.assertIsNone(retained)
                self.assertFalse(evidence['eligible'])
                out, _ = pruning.attach(*args[:5], candidate)
                self.assertEqual(out, args[4])

    def test_fewer_than_three_bodies_abstains_with_stale_certificate(self):
        diagnostic = fresh(synthetic())
        for count in (0, 1, 2):
            with self.subTest(bodies=count):
                args = synthetic(bodies=count)
                args[4]['fill']['colors'].append(INVALID)
                retained, evidence = infer(args, diagnostic)
                self.assertIsNone(retained)
                self.assertFalse(evidence['eligible'])
                self.assertEqual(pruning.attach(*args[:5], diagnostic)[0], args[4])

    def test_insufficient_direct_rf_seg_and_ocr_abstains(self):
        diagnostic = fresh(synthetic())
        for kind in ('rf', 'seg', 'ocr-box', 'ocr-detector', 'ocr-recognizer'):
            with self.subTest(channel=kind):
                args = fixture()
                arrays = args[2]
                if kind == 'rf':
                    arrays['rf'][:, 78:102] = 0
                elif kind == 'seg':
                    arrays['segPrimary'][:, 78:102] = .49
                    arrays['segBoundary'][:, 78:102] = .49
                else:
                    channel = {'ocr-box': 0, 'ocr-detector': 2, 'ocr-recognizer': 4}[kind]
                    arrays['ocr'][:, 78:102, channel] = 0
                retained, evidence = infer(args, diagnostic)
                self.assertIsNone(retained)
                self.assertFalse(evidence['eligible'])
                self.assertEqual(pruning.attach(*args[:5], diagnostic)[0], args[4])

    def test_no_source_palette_abstains_and_already_supported_palette_is_untagged(self):
        args = fixture()
        args[4]['fill']['representation'] = 'single-colour'
        self.assertIsNone(infer(args)[0])
        args = fixture()
        args[4]['fill']['colors'].pop()
        out, evidence = pruning.attach(*args[:5], fresh(args))
        self.assertTrue(evidence['eligible'])
        self.assertEqual(out, args[4])
        self.assertNotIn(pruning.TAG, out['fill'])

    def test_native_witness_and_negative_proof_tampering_rejected(self):
        args = fixture()
        retained, evidence = infer(args)
        mutations = {
            'version': lambda e: e.update(version='stale'),
            'minimumPixels': lambda e: e.update(minimumPixels=3),
            'semantic': lambda e: e['sourceDiagnostic'].pop('semantic'),
            'confirmed bodies': lambda e: e['sourceDiagnostic']['semantic'].update(holes=[{'confirmed': True}] * 2),
            'body fraction': lambda e: e['sourceBodySupportFractions'].__setitem__(0, .94),
            'negative distance': lambda e: e['colours'][-1].update(minimumNativeDeltaE=10.),
            'negative nan': lambda e: e['colours'][-1].update(minimumNativeDeltaE=float('nan')),
            'negative witness': lambda e: e['colours'][-1].update(bodyWitnesses=[{}]),
            'positive witness absent': lambda e: e['colours'][2].update(bodyWitnesses=[]),
            'witness RGB': lambda e: e['colours'][2]['bodyWitnesses'][0].update(rgb=[0, 0, 0]),
            'witness coordinate': lambda e: e['colours'][2]['bodyWitnesses'][0].update(xy=[0, 0]),
            'outside raster': lambda e: e['colours'][2]['bodyWitnesses'][0].update(xy=[116, 0]),
            'fractional coordinate': lambda e: e['colours'][2]['bodyWitnesses'][0].update(xy=[18.5, 24]),
            'body identity': lambda e: e['colours'][2]['bodyWitnesses'][0].update(body=3),
            'support count': lambda e: e['colours'][2]['bodyWitnesses'][0].update(supportedPixels=2),
            'unsupported retained': lambda e: e['colours'][-1].update(kept=True),
            'minority discarded': lambda e: e['colours'][2].update(kept=False),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                bad = copy.deepcopy(evidence)
                mutate(bad)
                with self.assertRaises(ValueError):
                    pruning.validate(bad, args[4]['fill']['colors'], retained, args[4]['fill']['rgb'], args[0])
        changed = args[0].copy()
        changed[24, 18] = [0, 0, 0]
        with self.assertRaisesRegex(ValueError, 'differs from RGB'):
            pruning.validate(evidence, args[4]['fill']['colors'], retained, args[4]['fill']['rgb'], changed)

    def test_attach_transport_and_warm_pruning_are_exact_and_nonmutating(self):
        args = fixture()
        before = copy.deepcopy(args[4])
        diagnostic = fresh(args)
        out, evidence = pruning.attach(*args[:5], diagnostic)
        tag = out['fill'][pruning.TAG]
        self.assertEqual(tag['previousColors'], before['fill']['colors'])
        self.assertEqual(tag['retainedColors'], before['fill']['colors'][:-1])
        self.assertEqual(tag['sourceEvidence'], evidence)
        transported = json.loads(json.dumps(out))
        snapshot = copy.deepcopy(transported)
        self.assertEqual(pruning.restore_baseline(transported), before)
        self.assertEqual(pruning.attach(*args[:4], transported, diagnostic), (out, evidence))
        self.assertEqual(transported, snapshot)
        self.assertEqual(args[4], before)

    def test_previous_colours_and_provenance_tampering_rejected(self):
        args = fixture()
        out, _ = pruning.attach(*args[:5], fresh(args))
        mutations = {
            'version': lambda f: f[pruning.TAG].update(version='stale'),
            'primary provenance': lambda f: f[pruning.TAG].update(primaryRGB=INVALID),
            'emitted primary': lambda f: f.update(rgb=INVALID),
            'emitted palette': lambda f: f['colors'].pop(),
            'retained provenance': lambda f: f[pruning.TAG]['retainedColors'].pop(),
            'previous colour': lambda f: f[pruning.TAG]['previousColors'].__setitem__(-1, [0, 0, 0]),
            'previous order': lambda f: f[pruning.TAG]['previousColors'].reverse(),
            'previous omitted': lambda f: f[pruning.TAG].pop('previousColors'),
            'certificate omitted': lambda f: f[pruning.TAG].pop('sourceEvidence'),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                bad = json.loads(json.dumps(out))
                mutate(bad['fill'])
                for restore in (pruning.restore_baseline, primary.restore_baseline, stage.restore_baseline):
                    with self.assertRaises(ValueError):
                        restore(bad)

    def test_full_stage_nested_restoration_and_repeated_warm_idempotence(self):
        args = fixture()
        before = copy.deepcopy(args[4])
        contour, _ = stage._refine_contour(*args)
        out, report = stage.refine(*args)
        self.assertEqual(stage.POLICY_VERSION, 'source-confirmed-contour-owned-palette-v6')
        fill = out['fill']
        self.assertIn(pruning.TAG, fill)
        self.assertIn(primary.TAG, fill)
        self.assertIn(stage.PALETTE_TAG, fill)
        self.assertNotIn(INVALID, fill['colors'])
        self.assertIn(MINORITY, fill['colors'])
        self.assertEqual(fill[pruning.TAG]['sourceEvidence'], report['fillPalettePruningObservation'])
        self.assertEqual(fill[primary.TAG]['sourceEvidence'], report['fillPrimaryObservation'])
        self.assertEqual(fill[stage.PALETTE_TAG]['sourceEvidence'], report['fillPaletteObservation'])
        peeled = pruning.restore_baseline(out)
        self.assertNotIn(pruning.TAG, peeled['fill'])
        self.assertEqual(peeled['fill']['colors'], fill[pruning.TAG]['previousColors'])
        self.assertEqual(peeled['fill'][primary.TAG], fill[primary.TAG])
        self.assertEqual(peeled['fill']['colors'], [fill['rgb']] + [c for c in fill[primary.TAG]['previousColors'] if c != fill['rgb']])
        palette_only = primary.restore_baseline(out)
        expected = copy.deepcopy(contour)
        expected['fill']['colors'] += fill[stage.PALETTE_TAG]['addedRGB']
        expected['fill'][stage.PALETTE_TAG] = copy.deepcopy(fill[stage.PALETTE_TAG])
        self.assertEqual(palette_only, expected)
        transported = json.loads(json.dumps(out))
        for _ in range(3):
            snapshot = copy.deepcopy(transported)
            self.assertEqual(stage.restore_baseline(transported), before)
            warm = list(args)
            warm[4] = transported
            self.assertEqual(stage.refine(*warm), (out, report))
            self.assertEqual(transported, snapshot)
            transported = json.loads(json.dumps(stage.refine(*warm)[0]))
        self.assertEqual(args[4], before)

    def test_legacy_v5_without_pruning_restores_and_refines(self):
        args = fixture()
        before = copy.deepcopy(args[4])
        out, report = stage.refine(*args)
        legacy = pruning.restore_baseline(out)
        legacy['fill'][stage.PALETTE_TAG]['version'] = 'source-confirmed-contour-owned-palette-v5'
        self.assertNotIn(pruning.TAG, legacy['fill'])
        self.assertIn(primary.TAG, legacy['fill'])
        transported = json.loads(json.dumps(legacy))
        snapshot = copy.deepcopy(transported)
        self.assertEqual(stage.restore_baseline(transported), before)
        warm = list(args)
        warm[4] = transported
        self.assertEqual(stage.refine(*warm), (out, report))
        self.assertEqual(transported, snapshot)


class PaletteSelectionGuardTests(unittest.TestCase):
    @staticmethod
    def row(key, group, colours, substyles=None):
        return dict(itemID=key, evaluationSplit=group,
                    fill=dict(rgb=colours[0], colors=colours), substyles=substyles or [])

    @staticmethod
    def prediction(key, colours):
        return dict(itemID=key, fill=dict(rgb=colours[0], colors=colours,
                                        representation='source-fusion-observed-palette'))

    def test_equal_aggregate_tradeoff_is_rejected_per_item_on_train_and_dev(self):
        red, blue = [240, 20, 20], [20, 20, 240]
        for group in ('train', 'dev'):
            with self.subTest(split=group):
                rows = [self.row('a', group, [red, blue]), self.row('b', group, [red, blue])]
                old = [self.prediction('a', [red, blue]), self.prediction('b', [red])]
                new = [self.prediction('a', [red]), self.prediction('b', [red, blue])]
                scores = lambda ps: measure(rows, ps, [predicted_colours(p) for p in ps])
                self.assertEqual(scores(old), scores(new))
                self.assertFalse(optimize.palette_target_guard(rows, old, new))
                self.assertTrue(optimize.palette_target_guard(rows, old, old))

    def test_secondary_substyle_and_primary_hits_cannot_be_lost(self):
        red, blue = [240, 20, 20], [20, 20, 240]
        for group in ('train', 'dev'):
            row = self.row('a', group, [red], [dict(fill=dict(colors=[blue]))])
            old = self.prediction('a', [red, blue])
            with self.subTest(split=group, loss='substyle'):
                self.assertFalse(optimize.palette_target_guard([row], [old], [self.prediction('a', [red])]))
            with self.subTest(split=group, loss='primary only'):
                new = self.prediction('a', [[0, 0, 0], red, blue])
                self.assertFalse(optimize.palette_target_guard([row], [old], [new]))

    def test_test_labels_do_not_select_candidates(self):
        red, blue = [240, 20, 20], [20, 20, 240]
        rows = [self.row('train', 'train', [red]), self.row('dev', 'dev', [red]),
                self.row('test', 'test', [red, blue])]
        old = [self.prediction(row['itemID'], [red, blue]) for row in rows]
        new = copy.deepcopy(old)
        new[-1] = self.prediction('test', [INVALID])
        for target in ([red, blue], [INVALID], [[0, 255, 0]]):
            with self.subTest(test_labels=target):
                rows[-1]['fill'] = dict(rgb=target[0], colors=target)
                self.assertTrue(optimize.palette_target_guard(rows, old, new))
        new[1] = self.prediction('dev', [INVALID])
        self.assertFalse(optimize.palette_target_guard(rows, old, new))

    def test_item_correspondence_is_required(self):
        rows = [self.row('a', 'train', [[255, 0, 0]])]
        old = [self.prediction('a', [[255, 0, 0]])]
        self.assertFalse(optimize.palette_target_guard(rows, old, []))
        self.assertFalse(optimize.palette_target_guard(rows, old, [self.prediction('b', [[255, 0, 0]])]))

    @staticmethod
    def native_report():
        return dict(fillPaletteMetrics=dict(
            baseline={g: dict(emittedColours=5, validColours=3, coveredColours=3) for g in ('train', 'dev')},
            selected={g: dict(emittedColours=3, validColours=3, coveredColours=3) for g in ('train', 'dev')}))

    def test_native_guard_accepts_true_invalid_removal_without_recall_gain(self):
        report = self.native_report()
        self.assertTrue(optimize.native_palette_guard(report))
        self.assertTrue(optimize.native_palette_guard({}))
        # Held-out metrics, including losses, have no vote in selection.
        report['fillPaletteMetrics']['baseline']['test'] = dict(emittedColours=3, validColours=3, coveredColours=3)
        report['fillPaletteMetrics']['selected']['test'] = dict(emittedColours=8, validColours=0, coveredColours=0)
        self.assertTrue(optimize.native_palette_guard(report))

    def test_native_guard_rejects_recall_loss_and_new_invalid_per_split(self):
        for group in ('train', 'dev'):
            for failure in ('recall', 'invalid'):
                with self.subTest(split=group, failure=failure):
                    report = self.native_report()
                    selected = report['fillPaletteMetrics']['selected']
                    other = 'dev' if group == 'train' else 'train'
                    selected[other]['coveredColours'] = 4
                    selected[group].update(coveredColours=2) if failure == 'recall' else selected[group].update(emittedColours=6)
                    self.assertFalse(optimize.native_palette_guard(report))

    def test_native_guard_distinguishes_primary_repair_from_duplicate_colour_addition(self):
        report = self.native_report()
        for group in ('train', 'dev'):
            report['fillPaletteMetrics']['selected'][group] = dict(emittedColours=6, validColours=4, coveredColours=3)
        self.assertFalse(optimize.native_palette_guard(report))
        report['baseline'] = {g: dict(fill=dict(n=10, within10=.9)) for g in ('train', 'dev')}
        report['selected'] = {g: dict(fill=dict(n=10, within10=.9)) for g in ('train', 'dev')}
        report['selected']['dev']['fill']['within10'] = 1.
        self.assertTrue(optimize.native_palette_guard(report))
        report['fillPaletteMetrics']['selected']['dev']['emittedColours'] = 7
        self.assertFalse(optimize.native_palette_guard(report))


if __name__ == '__main__':
    unittest.main()
