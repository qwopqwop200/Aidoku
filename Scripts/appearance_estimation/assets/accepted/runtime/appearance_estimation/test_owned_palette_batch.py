import copy
import unittest
from test_owned_palette_integration import actual
import source_gradient_contour as stage
from apply_gradient_contour import assert_rgb_only, assert_document_rgb_only

class OwnedPaletteBatchTests(unittest.TestCase):
    def test_native_observation_and_warm_document_have_only_owned_changes(self):
        args=actual();out,_=stage.refine(*args)
        assert_rgb_only(args[4],out)
        assert_document_rgb_only(dict(items=[args[4]],metadata='same'),dict(items=[out],metadata='same'))
        assert_document_rgb_only(dict(items=[out]),dict(items=[out]))

    def test_unowned_palette_mutation_is_rejected(self):
        args=actual();out=copy.deepcopy(args[4]);out['fill']['colors'].append([1,2,3])
        with self.assertRaises(ValueError):assert_rgb_only(args[4],out)

    def test_forged_previous_palette_and_primary_changes_are_rejected(self):
        args=actual();out,_=stage.refine(*args)
        bad=copy.deepcopy(out);bad['fill']['colors'][0]=[1,2,3]
        with self.assertRaises(ValueError):assert_rgb_only(args[4],bad)
        bad=copy.deepcopy(out);bad['fill'][stage.PALETTE_TAG]['previousColors'].append([1,2,3]);bad['fill']['colors'].insert(-1,[1,2,3])
        with self.assertRaises(ValueError):assert_rgb_only(args[4],bad)

    def test_self_consistent_palette_without_native_evidence_is_rejected(self):
        args=actual();out,_=stage.refine(*args)
        bad=copy.deepcopy(out);bad['fill'][stage.PALETTE_TAG].pop('sourceEvidence')
        with self.assertRaises(ValueError):assert_rgb_only(args[4],bad)
        bad=copy.deepcopy(out);tag=bad['fill'][stage.PALETTE_TAG]
        tag['addedRGB'].append([1,2,3]);bad['fill']['colors'].append([1,2,3])
        with self.assertRaises(ValueError):assert_rgb_only(args[4],bad)

    def test_native_witness_must_equal_the_loaded_source_rgb(self):
        from owned_palette import validate_additions
        args=actual();out,_=stage.refine(*args);tag=out['fill'][stage.PALETTE_TAG]
        validate_additions(tag['sourceEvidence'],tag['addedRGB'],rgb=args[0])
        altered=args[0].copy();xy=tag['sourceEvidence']['groups'][0]['selected']['exactRGBWitnessXY']
        altered[xy[1],xy[0]]=[0,0,0]
        with self.assertRaises(ValueError):validate_additions(tag['sourceEvidence'],tag['addedRGB'],rgb=altered)

    def test_precision_gain_cannot_hide_one_new_false_native_colour(self):
        from continuous_optimize import native_palette_guard
        def metric(valid,total,covered):return dict(validColours=valid,emittedColours=total,coveredColours=covered)
        base=dict(train=metric(100,110,90),dev=metric(2318,2497,830))
        candidate=dict(train=metric(100,110,90),dev=metric(2331,2511,832))
        self.assertFalse(native_palette_guard(dict(fillPaletteMetrics=dict(baseline=base,selected=candidate))))
        candidate['dev']=metric(2319,2498,832)
        self.assertTrue(native_palette_guard(dict(fillPaletteMetrics=dict(baseline=base,selected=candidate))))

if __name__=='__main__':unittest.main()
