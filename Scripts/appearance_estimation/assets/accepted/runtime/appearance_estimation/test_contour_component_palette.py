"""Native contour coverage counterexamples; synthetic rasters only, no corpus."""
import copy
import json
import unittest

# Install optional accelerator guards before importing any sklearn consumer.
import optimize_appearance  # noqa: F401
import cv2
import numpy as np
from scipy import ndimage

import certified_bright_palette as bright
import certified_bright_primary as primary
import certified_interior_palette as pruning
import source_gradient_contour as stage
from source_appearance import lab
from source_bright_ring import family_mask
from source_outer_shell import confirmed_bodies
from test_certified_bright_palette import synthetic


BROWN = [140, 95, 45]
GREEN = [30, 180, 70]
ABSENT = [15, 25, 230]
WHITE = [255, 255, 255]


def fixture():
    args = synthetic()
    args[4]['fill']['colors'] += [BROWN.copy(), GREEN.copy(), ABSENT.copy()]
    return args


def text_pixel(args, x, y, colour):
    args[0][y, x] = colour
    args[1][y, x] = True
    args[2]['rf'][y, x, 15:17] = 1
    args[2]['segPrimary'][y, x] = 1
    args[2]['ocr'][y, x] = 1


def fresh(args):
    diagnostic = stage._refine_contour(*args)[1]
    assert diagnostic['mechanism'] == 'bounded-bright-interiors'
    assert diagnostic['semantic']['accepted'] is True
    return diagnostic


def infer(args):
    return pruning.infer(*args[:5], fresh(args), 1)


def row_for(evidence, colour):
    return next(row for row in evidence['colours'] if row['rgb'] == colour)


class ContourComponentPaletteTests(unittest.TestCase):
    def validate(self, args, retained, evidence):
        pruning.validate(evidence, args[4]['fill']['colors'], retained,
                         args[4]['fill']['rgb'], args[0])

    def test_native_ring_brown_removed_and_nonexistent_crop_colour_can_drop(self):
        args = fixture()
        retained, evidence = infer(args)
        self.assertTrue(evidence['eligible'])
        self.assertEqual(retained, [WHITE])
        brown = row_for(evidence, BROWN)
        self.assertEqual(brown['supportedNativePixels'], 0)
        self.assertEqual(brown['bodyWitnesses'], [])
        self.assertGreater(brown['possibleTextPixels'], 0)
        self.assertEqual(brown['unexplainedTextPixels'], 0)
        self.assertTrue(brown['boundaryExclusive'])
        self.assertLessEqual(brown['nativeBoundaryWitness']['deltaE'], 10)
        self.assertFalse(brown['kept'])
        image_lab = cv2.cvtColor(args[0].astype(np.float32) / 255, cv2.COLOR_RGB2LAB)
        source = evidence['sourceDiagnostic']['sourceObservation']
        native = family_mask(image_lab, source['candidateRGB'])
        closed = cv2.morphologyEx(native.astype(np.uint8), cv2.MORPH_CLOSE,
                                 np.ones((3, 3), np.uint8))
        _, labels = cv2.connectedComponents(closed, 8)
        contour = native & np.isin(labels, evidence['certifiedContourComponents'])
        x, y = brown['nativeBoundaryWitness']['xy']
        self.assertTrue(contour[y, x])
        self.assertEqual(int(labels[y, x]), brown['nativeBoundaryWitness']['component'])
        self.assertEqual(args[0][y, x].tolist(), brown['nativeBoundaryWitness']['rgb'])
        candidates = args[1] & (np.linalg.norm(image_lab - lab([BROWN])[0], axis=2) <= 10)
        self.assertEqual(int(candidates.sum()), brown['possibleTextPixels'])
        self.assertTrue(np.all(ndimage.distance_transform_edt(~contour)[candidates] <= 2))
        absent = row_for(evidence, ABSENT)
        self.assertGreater(absent['minimumNativeCropDeltaE'], 10)
        self.assertFalse(absent['kept'])
        self.validate(args, retained, evidence)

    def test_same_outline_brown_at_far_flagged_text_pixel_must_remain(self):
        args = fixture()
        text_pixel(args, 0, 0, BROWN)
        self.assertTrue(args[1][0, 0])
        self.assertGreaterEqual(args[2]['segPrimary'][0, 0], .5)
        rf = args[2]['rf'][0, 0]
        self.assertGreaterEqual(max(rf[15] * rf[16], rf[17] * rf[18]), .001)
        self.assertGreater(args[2]['ocr'][0, 0, 0], 0)
        retained, evidence = infer(args)
        brown = row_for(evidence, BROWN)
        self.assertIn(BROWN, retained)
        self.assertEqual(brown['supportedNativePixels'], 0)
        self.assertGreater(brown['minimumNativeDeltaE'], 10)
        self.assertEqual(brown['unexplainedTextPixels'], 1)
        self.assertFalse(brown['boundaryExclusive'])
        witness = brown['unexplainedTextWitness']
        self.assertEqual(witness['xy'], [0, 0])
        self.assertEqual(witness['rgb'], BROWN)
        self.assertGreater(witness['distanceToContourPx'], 2)
        self.assertGreater(witness['distanceToCorePx'], 2)
        self.validate(args, retained, evidence)

    def test_distinct_green_independent_text_component_kept(self):
        args = fixture()
        for x in (109, 110):
            text_pixel(args, x, 48, GREEN)
        retained, evidence = infer(args)
        self.assertEqual(retained, [WHITE, GREEN])
        green = row_for(evidence, GREEN)
        self.assertEqual(green['supportedNativePixels'], 0)
        self.assertEqual(green['possibleTextPixels'], 2)
        self.assertEqual(green['unexplainedTextPixels'], 2)
        self.assertEqual(green['unexplainedTextWitness']['xy'], [109, 48])
        self.assertGreater(green['nativeBoundaryWitness']['deltaE'], 10)
        self.assertFalse(green['boundaryExclusive'])
        self.assertNotIn(BROWN, retained)
        self.validate(args, retained, evidence)

    def test_nearby_colour_needs_actual_native_band_rgb_witness(self):
        args = fixture()
        # One pixel from the ring, yet no green occurs in its native band.
        text_pixel(args, 7, 26, GREEN)
        retained, evidence = infer(args)
        green = row_for(evidence, GREEN)
        self.assertEqual(green['supportedNativePixels'], 0)
        self.assertEqual(green['possibleTextPixels'], 1)
        self.assertEqual(green['unexplainedTextPixels'], 0)
        self.assertGreater(green['nativeBoundaryWitness']['deltaE'], 10)
        self.assertFalse(green['boundaryExclusive'])
        self.assertIn(GREEN, retained)
        self.validate(args, retained, evidence)

    def test_single_supported_native_body_pixel_preserves_minority_colour(self):
        args = fixture()
        text_pixel(args, 18, 24, GREEN)
        retained, evidence = infer(args)
        green = row_for(evidence, GREEN)
        self.assertIn(GREEN, retained)
        self.assertEqual(green['supportedNativePixels'], 1)
        self.assertEqual(green['bodyWitnesses'], [dict(
            body=0, supportedPixels=1, xy=[18, 24], rgb=GREEN, deltaE=0.)])
        self.validate(args, retained, evidence)

    def test_primary_always_kept_even_when_it_is_absent_from_crop(self):
        args = fixture()
        diagnostic = fresh(args)
        args[4]['fill']['rgb'] = ABSENT.copy()
        args[4]['fill']['colors'] = [ABSENT.copy(), BROWN.copy()]
        retained, evidence = pruning.infer(*args[:5], diagnostic, 1)
        self.assertEqual(retained, [ABSENT])
        row = row_for(evidence, ABSENT)
        self.assertEqual(row['supportedNativePixels'], 0)
        self.assertGreater(row['minimumNativeCropDeltaE'], 10)
        self.assertTrue(row['primary'])
        self.assertTrue(row['kept'])
        self.validate(args, retained, evidence)

    def test_thin_fourth_certified_core_need_not_be_an_eroded_palette_body(self):
        args = fixture()
        args[0] = np.pad(args[0], ((0, 0), (0, 34), (0, 0)), constant_values=255)
        args[1] = np.pad(args[1], ((0, 0), (0, 34)))
        for key, array in args[2].items():
            args[2][key] = np.pad(array, ((0, 0), (0, 34)) +
                                 ((0, 0),) * (array.ndim - 2))
        for x in (8, 43, 78):
            args[0][11:41, x + 3:x + 21] = WHITE
        args[0][12:24, 130:139] = BROWN
        args[0][15:21, 133:136] = WHITE
        args[1][12:24, 130:139] = True
        args[2]['rf'][12:24, 130:139, 15:17] = 1
        args[2]['segPrimary'][12:24, 130:139] = 1
        args[2]['ocr'][12:24, 130:139] = 1
        args[3]['polygons'].append([[133, 15], [135, 15], [135, 20], [133, 20]])
        self.assertEqual(args[0].shape, (52, 150, 3))
        diagnostic = fresh(args)
        self.assertEqual(sum(h['confirmed'] for h in diagnostic['semantic']['holes']), 4)
        core, certificates = confirmed_bodies(args[0], diagnostic)
        self.assertEqual(len(certificates), 4)
        self.assertEqual(sorted(c['nativeArea'] for c in certificates), [18, 540, 540, 540])
        self.assertEqual(int(core[15:21, 133:136].sum()), 18)
        thin = np.zeros(args[1].shape, bool)
        thin[15:21, 133:136] = True
        self.assertEqual(int((ndimage.distance_transform_edt(thin) > 1.5).sum()), 4)
        native = copy.deepcopy(args[4])
        native['outline']['rgb'] = diagnostic['sourceObservation']['rgb']
        bodies = bright.propose(*args[:4], native)['bodies']
        self.assertEqual(len(bodies), 3)
        self.assertTrue(all(np.all(body['xy'][:, 0] < 130) for body in bodies))
        retained, evidence = pruning.infer(*args[:5], diagnostic, 1)
        self.assertEqual(evidence['bodies'], 3)
        self.assertEqual(evidence['nativeInteriorPixels'], 3 * 28 * 16)
        self.assertEqual(evidence['confirmedSourceCorePixels'], 3 * 540 + 18)
        self.assertEqual(len(evidence['certifiedContourComponents']), 4)
        band = args[1] & ~core
        self.assertTrue(np.all(np.linalg.norm(
            lab(args[0][band].tolist()) - lab([BROWN])[0], axis=1) <= 10))
        self.assertEqual(row_for(evidence, BROWN)['possibleTextPixels'], int(band.sum()))
        self.assertEqual(row_for(evidence, BROWN)['unexplainedTextPixels'], 0)
        self.assertTrue(row_for(evidence, BROWN)['boundaryExclusive'])
        self.assertNotIn(BROWN, retained)
        self.validate(args, retained, evidence)

    def test_direct_native_contour_witness_and_component_ids_tamper_rejected(self):
        args = fixture()
        text_pixel(args, 0, 0, BROWN)
        retained, evidence = infer(args)
        self.validate(args, retained, evidence)
        mutations = {
            'band missing': lambda e: row_for(e, BROWN).pop('nativeBoundaryWitness'),
            'band coordinate': lambda e: row_for(e, BROWN)['nativeBoundaryWitness'].update(xy=[0, 0]),
            'band RGB': lambda e: row_for(e, BROWN)['nativeBoundaryWitness'].update(rgb=GREEN),
            'band delta': lambda e: row_for(e, BROWN)['nativeBoundaryWitness'].update(deltaE=11.),
            'uncertified ID': lambda e: row_for(e, BROWN)['nativeBoundaryWitness'].update(component=999),
            'wrong certified ID': lambda e: row_for(e, BROWN)['nativeBoundaryWitness'].update(
                component=next(c for c in e['certifiedContourComponents']
                               if c != row_for(e, BROWN)['nativeBoundaryWitness']['component'])),
            'certified IDs': lambda e: e['certifiedContourComponents'].pop(),
            'contour count': lambda e: e.update(sourceContourPixels=e['sourceContourPixels'] + 1),
            'core count': lambda e: e.update(confirmedSourceCorePixels=e['confirmedSourceCorePixels'] + 1),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                bad = copy.deepcopy(evidence)
                mutate(bad)
                with self.assertRaises(ValueError):
                    self.validate(args, retained, bad)
        # Same RGB and distance at (0,0): only native contour membership rejects it.
        bad = copy.deepcopy(evidence)
        row_for(bad, BROWN)['nativeBoundaryWitness']['xy'] = [0, 0]
        with self.assertRaisesRegex(ValueError, 'not in certified contour'):
            self.validate(args, retained, bad)

    def test_global_native_crop_witness_tamper_rejected(self):
        args = fixture()
        retained, evidence = infer(args)
        mutations = {
            'missing': lambda r: r.pop('nativeCropWitness'),
            'coordinate': lambda r: r['nativeCropWitness'].update(xy=[0, 0]),
            'outside': lambda r: r['nativeCropWitness'].update(xy=[116, 0]),
            'RGB': lambda r: r['nativeCropWitness'].update(rgb=GREEN),
            'distance': lambda r: r['nativeCropWitness'].update(deltaE=1.),
            'minimum mismatch': lambda r: r.update(minimumNativeCropDeltaE=1.),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                bad = copy.deepcopy(evidence)
                mutate(row_for(bad, BROWN))
                with self.assertRaises(ValueError):
                    self.validate(args, retained, bad)

    def test_warm_ordered_tag_restoration_and_replay(self):
        args = fixture()
        text_pixel(args, 0, 0, BROWN)
        text_pixel(args, 109, 48, GREEN)
        baseline = copy.deepcopy(args[4])
        contour, _ = stage._refine_contour(*args)
        out, report = stage.refine(*args)
        fill = out['fill']
        for tag in (pruning.TAG, primary.TAG, stage.PALETTE_TAG):
            self.assertIn(tag, fill)
        self.assertIn(BROWN, fill['colors'])
        self.assertIn(GREEN, fill['colors'])
        self.assertNotIn(ABSENT, fill['colors'])
        self.assertEqual(fill[pruning.TAG]['sourceEvidence'], report['fillPalettePruningObservation'])
        transported = json.loads(json.dumps(out))
        snapshot = copy.deepcopy(transported)
        peeled = pruning.restore_baseline(transported)
        self.assertNotIn(pruning.TAG, peeled['fill'])
        self.assertEqual(peeled['fill']['colors'], fill[pruning.TAG]['previousColors'])
        self.assertEqual(peeled['fill'][primary.TAG], fill[primary.TAG])
        self.assertEqual(peeled['fill'][stage.PALETTE_TAG], fill[stage.PALETTE_TAG])
        palette_only = primary.restore_baseline(transported)
        expected = copy.deepcopy(contour)
        expected['fill']['colors'] += fill[stage.PALETTE_TAG]['addedRGB']
        expected['fill'][stage.PALETTE_TAG] = copy.deepcopy(fill[stage.PALETTE_TAG])
        self.assertEqual(palette_only, expected)
        self.assertEqual(stage.restore_baseline(transported), baseline)
        warm = list(args)
        warm[4] = transported
        self.assertEqual(stage.refine(*warm), (out, report))
        self.assertEqual(transported, snapshot)
        self.assertEqual(args[4], baseline)


if __name__ == '__main__':
    unittest.main()
