"""Focused source-stage contract, ownership, warm replay, and policy regression tests."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
import numpy as np
from PIL import Image
import test_source_gradient_contour as fixtures
import source_gradient_contour as stage
from owned_palette import POLICY, infer

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'labels').is_dir())
BASE=ROOT/'appearance-estimation-20261109/rf-seg-fusion'
STUDY=BASE/'native-confirmed-gradient-fill-study'


def synthetic():
    args=list(fixtures.SourceGradientContourTests().arguments())
    args[4]['fill']['representation']='source-fusion-observed-palette'
    return args


def actual():
    item='p0481-M001'
    request=json.loads((BASE/'final-background-local-fusion-study/runtime'/f'{item}.json').read_text())
    entry=json.loads((BASE/'features'/f'{item}.json').read_text())
    with np.load(BASE/'final-background-local-fusion-study/runtime'/f'{item}.npz',allow_pickle=False) as f:
        arrays={k:f[k] for k in ('rf','segPrimary','segBoundary','ocr')}
        geometry=json.loads(str(f['geometryJSON'].item()))
    import pickle
    with (BASE/'background-relative-quality-study/integration-staging/pixel-role-model.pkl').open('rb') as f:model=pickle.load(f)
    pred=json.loads((STUDY/'FROZEN-PALETTE-INPUT.json').read_text())
    return [np.asarray(Image.open(request['image']).convert('RGB')),np.asarray(Image.open(request['mask']))>0,
            arrays,geometry,pred,model,entry['packet']]


class OwnedPaletteIntegrationTests(unittest.TestCase):
    def test_actual_frozen_addition_exactly_preserves_every_other_field(self):
        args=actual();before=copy.deepcopy(args[4]);out,diag=stage.refine(*args)
        self.assertTrue(diag['sourceObservation']['identified'])
        self.assertEqual(out['fill']['colors'],before['fill']['colors']+[[255,240,159]])
        restored=copy.deepcopy(out);restored['fill']['colors']=before['fill']['colors']
        del restored['fill'][stage.PALETTE_TAG]
        self.assertEqual(restored,before)
        g=diag['fillPaletteObservation']['groups'][0]
        self.assertEqual((g['interiorPixels'],g['baselineCoveredPixels'],g['candidateCoveredPixels']),(152,34,107))
        self.assertEqual(g['selected']['exactRGBWitnessXY'],[135,16])
        self.assertEqual(infer(*args)[0],[[255,240,159]])

    def test_actual_warm_repeat_is_exactly_idempotent_and_input_is_immutable(self):
        args=actual();before=copy.deepcopy(args[4]);out,diag=stage.refine(*args)
        self.assertEqual(args[4],before)
        warm=list(args);warm[4]=out
        self.assertEqual(stage.refine(*warm),(out,diag))
        self.assertEqual(infer(*warm),infer(*args))
        self.assertEqual(stage.needs_source(args[0],args[1],args[3],out,args[6]),
                         stage.needs_source(args[0],args[1],args[3],before,args[6]))

    def test_no_independent_contour_means_no_palette_even_with_known_fill(self):
        args=synthetic();rgb,_,_=fixtures.SourceGradientContourTests().source(ring=False)
        args[0]=rgb;out,diag=stage.refine(*args)
        self.assertEqual(out,args[4]);self.assertFalse(diag['fillPaletteObservation']['eligible'])

    def test_two_components_or_missing_source_ownership_abstain(self):
        args=synthetic();args[0][:,130:]=[235,180,205];args[1][:,130:]=False
        self.assertEqual(stage.refine(*args)[0],args[4])
        args=synthetic();args[2]['rf'][:]=0
        self.assertEqual(stage.refine(*args)[0],args[4])

    def test_primary_background_width_shadow_and_legacy_contour_are_preserved(self):
        args=synthetic();contour,old_diagnostic=stage._refine_contour(*args)
        out,diag=stage.refine(*args)
        for key in ('outline','background','shadow','fillIndex','outlineIndex','backgroundIndex'):
            self.assertEqual(out[key],contour[key])
        self.assertEqual(out['fill']['rgb'],args[4]['fill']['rgb'])
        self.assertEqual(out['fill']['colors'][:len(args[4]['fill']['colors'])],args[4]['fill']['colors'])
        self.assertFalse(diag['fillPrimaryObservation']['eligible'])
        self.assertEqual({k:v for k,v in diag.items() if k not in ('fillPaletteObservation','fillPrimaryObservation','fillPalettePruningObservation')},old_diagnostic)

    def test_invalid_warm_provenance_or_palette_transport_fails_closed(self):
        args=actual();out,_=stage.refine(*args)
        for mutate in ('primary','colors','version'):
            bad=copy.deepcopy(out)
            if mutate=='primary':bad['fill']['rgb']=[0,0,0]
            elif mutate=='colors':bad['fill']['colors'].append([1,2,3])
            else:bad['fill'][stage.PALETTE_TAG]['version']='stale'
            with self.assertRaises(ValueError):stage.restore_baseline(bad)
        args=actual();args[4]['fill']['representation']='unsupported'
        with self.assertRaises(ValueError):stage.refine(*args)

    def test_policy_rejects_old_version_rule_helper_and_model_drift(self):
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder)
            for name in stage.MODEL_NAMES:(folder/name).write_bytes(name.encode())
            p=stage.make_policy(folder);stage.validate_policy(p,p['modelIdentities'])
            self.assertIn('owned_palette.py',p['helperSHA256'])
            for kind in ('version','rule','helper','model'):
                bad=copy.deepcopy(p)
                if kind=='version':bad['version']=stage.VERSION
                elif kind=='rule':bad['fillPalettePolicy']['coverageDeltaE']=9
                elif kind=='helper':bad['helperSHA256']['owned_palette.py']='stale'
                else:bad['modelIdentities']['model.pkl']='stale'
                with self.assertRaises(ValueError):stage.validate_policy(bad,p['modelIdentities'])


if __name__=='__main__':unittest.main()
