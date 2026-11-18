import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image

import source_runtime
import native_pairs
import affine_pairs
from affine_pairs import fit as affine_fit, transformed_pair, locate
from runtime import predict_complementary_page,predict_band_page
from physical_correction import POLICY
from weight_bands import band_stats
from source_observation import observe_fill
from observed_weight_bands import band_stats as observed_band_stats

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'inpainting_compare'))
import font_weight_runtime


class FreshSourceTests(unittest.TestCase):
    def test_unknown_stem_pixels_are_not_background_evidence(self):
        regular=np.zeros((40,30));heavy=regular.copy()
        regular[8:32,14:16]=1;heavy[6:34,11:19]=1
        observed=np.ones(regular.shape,bool);observed[:20]=False
        damaged=heavy.copy();damaged[~observed]=0
        naive=band_stats(damaged,regular,heavy)
        corrected=observed_band_stats(damaged,regular,heavy,observed)
        self.assertLess(naive[0],.7)
        self.assertAlmostEqual(corrected[0],1.)
        self.assertAlmostEqual(corrected[5],1.)
        self.assertAlmostEqual(corrected[15],.5)

    def test_observation_keeps_known_background_outside_ownership(self):
        rgb=np.array([[[0,0,0],[255,255,255],[255,0,0]]],np.uint8)
        style={'fill':{'rgb':[0,0,0]},'background':{'rgb':[255,255,255]}}
        alpha,observed=observe_fill(rgb,np.zeros((1,3),bool),style)
        np.testing.assert_array_equal(observed,[[False,True,False]])
        self.assertAlmostEqual(alpha[0,1],0.)

    def test_source_band_confirmation_rejects_color_vote_without_added_stem(self):
        class Head:
            def __init__(self,p):self.p=p
            def predict_proba(self,x):return np.tile([1-self.p,self.p],(len(x),1))
        primary={'sourceComplementaryHeads':True,'fillVersion':1,
                 'primary':{'model':Head(.1),'threshold':.5,'rawFeatureCount':866,
                            'featureCount':2598,'physicalCorrection':POLICY},
                 'polarity':{'model':Head(.1),'threshold':.5,'featureCount':2790}}
        bundle={'primary':primary,'bandFeatureCount':112,
                'body':{'model':Head(.9),'threshold':.5,'featureCount':1791},
                'physical':{'model':Head(.9),'threshold':.5,'featureCount':2742},
                'stem':{'model':Head(.1),'threshold':.5,'featureCount':2934,'rawFeatureCount':978},
                'bandPolicy':{'minimumAddedStem':.25,'minimumCommonBody':.5,
                              'minimumGlyphFit':.5,'maximumReconstructionError':.15}}
        bands=np.zeros((3,8,14));bands[:,0,[0,4,5,12,13]]=[.5,.05,.9,.9,1.]
        bands[1,0,0]=-.1
        result=predict_band_page(bundle,np.ones((3,866)),np.ones((3,71)),
                                 [self.packet()['style']]*3,np.zeros((3,48)),
                                 bands.reshape(3,-1),[False,False,True])
        self.assertEqual([r['sourceWeight'] for r in result],['bold','regular','mixed'])
        self.assertEqual([r['renderBold'] for r in result],[True,False,False])
        self.assertEqual([r['confirmedStemRescueApplied'] for r in result],[True,False,False])

    def test_weight_band_estimate_follows_added_stems(self):
        regular=np.zeros((40,30));heavy=regular.copy()
        regular[8:32,14:16]=1;heavy[6:34,11:19]=1
        a=band_stats(regular,regular,heavy)
        b=band_stats(heavy,regular,heavy)
        middle=band_stats((regular+heavy)/2,regular,heavy)
        self.assertAlmostEqual(a[0],0.)
        self.assertAlmostEqual(b[0],1.)
        self.assertAlmostEqual(middle[0],.5)
        self.assertLess(a[3],0.)
        self.assertGreater(b[3],0.)

    def test_missing_common_body_is_distinct_from_added_weight(self):
        regular=np.zeros((40,30));heavy=regular.copy()
        regular[8:32,14:16]=1;heavy[6:34,11:19]=1
        damaged=heavy.copy();damaged[regular>0]=0
        value=band_stats(damaged,regular,heavy)
        self.assertAlmostEqual(value[0],1.)
        self.assertAlmostEqual(value[5],0.)
        self.assertGreater(value[4],0.)

    def test_visible_second_glyph_can_replace_an_occluded_witness(self):
        import cv2
        regular=np.zeros((80,60),np.uint8)
        regular[10:70,14:20]=255;regular[10:16,14:47]=255;regular[35:41,14:40]=255
        heavy=cv2.dilate(regular,np.ones((7,7),np.uint8))
        _,ink=transformed_pair(regular,heavy,56)
        alpha=np.pad(ink,10)
        rgb=np.repeat(np.rint((1-alpha[:,:,None])*255).astype(np.uint8),3,axis=2)
        absent=np.zeros_like(regular);cv2.circle(absent,(30,40),20,255,2)
        pair={'regular':{'heavy':False},'heavy':{'heavy':True}}
        style={'fill':{'rgb':[0,0,0]},'background':{'rgb':[255,255,255]},'outline':{'present':False}}
        def raster(record,char):
            return absent if char=='あ' else heavy if record['heavy'] else regular
        with patch.object(affine_pairs,'anchor_chars',return_value=['あ','い']), \
                patch.object(affine_pairs,'glyph',side_effect=raster):
            value=affine_pairs.measure(rgb,[0,0,rgb.shape[1],rgb.shape[0]],56,'あい',
                                       np.ones(alpha.shape,bool),style,[pair])
        self.assertEqual(value.shape,(48,))
        self.assertGreater(value[0],.99)
        self.assertGreater(value[3],0)

    def test_strong_exact_face_wins_over_regular_heavy_compromise(self):
        regular=np.zeros((80,60),np.uint8)
        regular[10:70,14:20]=255;regular[10:16,14:47]=255;regular[35:41,14:40]=255
        import cv2
        heavy=cv2.dilate(regular,np.ones((7,7),np.uint8))
        a,b=transformed_pair(regular,heavy,56)
        h,w=a.shape
        source=np.zeros((h+20,2*w+30),np.float32)
        source[10:10+h,10:10+w]=(a+b)/2
        source[10:10+h,w+20:2*w+20]=a
        score,ra,rb,x,y=locate(source,a,b)
        self.assertAlmostEqual(score,1.,places=5)
        self.assertEqual((x,y),(w+20,10))
        self.assertGreater(ra,rb)

    def test_affine_refinement_recovers_rotated_dense_glyph(self):
        from physical_templates import font_pairs,bitmap
        pa,ia,pb,ib=font_pairs()[0]
        regular,heavy=bitmap(pa,ia,'願'),bitmap(pb,ib,'願')
        a,b=transformed_pair(regular,heavy,80,.9,4)
        thin=affine_fit(np.pad(a,10),regular,heavy,80)
        thick=affine_fit(np.pad(b,10),regular,heavy,80)
        self.assertGreater(thin[18],.1)
        self.assertGreater(thick[18],.1)
        self.assertLess(thin[3],0)
        self.assertGreater(thick[3],0)

    def test_shared_affine_pose_preserves_actual_weight(self):
        regular=np.zeros((80,60),np.uint8)
        regular[10:70,14:20]=255;regular[10:16,14:47]=255;regular[35:41,14:40]=255
        import cv2
        heavy=cv2.dilate(regular,np.ones((7,7),np.uint8))
        a,b=transformed_pair(regular,heavy,56,1.1,4)
        thin=affine_fit(np.pad(a,10),regular,heavy,56)
        thick=affine_fit(np.pad(b,10),regular,heavy,56)
        self.assertEqual(thin.shape,(24,))
        self.assertGreater(thin[0],.9)
        self.assertGreater(thick[0],.9)
        self.assertLess(thin[3],0)
        self.assertGreater(thick[3],0)

    def test_complementary_rescue_never_overrides_mixed_regular_rendering(self):
        class Head:
            def __init__(self, positive):self.positive=positive
            def predict_proba(self, x):return np.tile([1-self.positive,self.positive],(len(x),1))
        bundle={'sourceComplementaryHeads':True,'fillVersion':1,
                'primary':{'model':Head(.1),'threshold':.5,'rawFeatureCount':866,
                           'featureCount':2598,'physicalCorrection':POLICY},
                'polarity':{'model':Head(.9),'threshold':.5,'featureCount':2790}}
        styles=[self.packet()['style']]*2
        result=predict_complementary_page(bundle,np.ones((2,866)),np.ones((2,71)),
                                          styles,np.zeros((2,48)),[False,True])
        self.assertEqual([r['sourceWeight'] for r in result],['bold','mixed'])
        self.assertEqual([r['renderBold'] for r in result],[True,False])
        self.assertEqual([r['polarityRescueApplied'] for r in result],[True,False])
        bundle['fillVersion']=2
        with self.assertRaisesRegex(ValueError,'version differs'):
            predict_complementary_page(bundle,np.ones((2,866)),np.ones((2,71)),
                                       styles,np.zeros((2,48)),[False,True])

    def test_expanded_pair_prefers_true_body_weight_at_shared_alignment(self):
        regular = np.zeros((80, 50), np.uint8)
        heavy = regular.copy()
        regular[10:70, 22:28] = 255
        heavy[10:70, 16:34] = 255
        from physical_templates import paired_patterns
        a, b = paired_patterns(regular, heavy, 40)
        thin = native_pairs.fit_pair(np.pad(a, 10), regular, heavy, 40)
        thick = native_pairs.fit_pair(np.pad(b, 10), regular, heavy, 40)
        self.assertLess(thin[3], 0)
        self.assertLess(thin[7], 0)
        self.assertGreater(thick[3], 0)
        self.assertGreater(thick[7], 0)
        self.assertGreater(thick[10], thin[10])

    def test_expanded_family_measurement_excludes_colored_outline(self):
        import cv2
        body = np.zeros((100, 60), np.uint8)
        body[15:75, 25:31] = 1
        outline = cv2.dilate(body, np.ones((7, 7), np.uint8)) > 0
        gray = np.full((100, 60, 3), 255, np.uint8)
        gray[body > 0] = 0
        colored = np.full_like(gray, [240, 180, 200])
        colored[outline] = [255, 255, 255]
        colored[body > 0] = [120, 20, 150]
        s1 = {'fill': {'rgb': [0, 0, 0]}, 'outline': {'present': False},
              'background': {'rgb': [255, 255, 255]}}
        s2 = {'fill': {'rgb': [120, 20, 150]}, 'outline': {'present': True, 'rgb': [255, 255, 255]},
              'background': {'rgb': [240, 180, 200]}}
        regular = np.zeros((80, 50), np.uint8)
        regular[10:70, 22:28] = 255
        heavy = cv2.dilate(regular, np.ones((5, 5), np.uint8))
        pairs = [{'regular': {'heavy': False}, 'heavy': {'heavy': True}}] * 4
        with patch.object(native_pairs, 'glyph', side_effect=lambda record, char: heavy if record['heavy'] else regular):
            x = native_pairs.measure(gray, [0, 0, 60, 100], 80, 'あ', outline, s1, pairs)
            y = native_pairs.measure(colored, [0, 0, 60, 100], 80, 'あ', outline, s2, pairs)
            single = native_pairs.measure(gray, [0, 0, 60, 100], 80, 'あ', outline, s1, pairs[:1])
        np.testing.assert_allclose(x, y, atol=1e-7)
        self.assertEqual(single.shape,(32,))
        np.testing.assert_allclose(single,x[:32],atol=1e-7)
        self.assertTrue(x.any())

    def packet(self):
        return dict(rgb=np.full((120, 60, 3), 255, np.uint8),
                    bbox=[0, 0, 60, 120], prior=32., text='あ',
                    ownership=np.ones((120, 60), bool), sourceHash='same-source',
                    style={'fill': {'rgb': [0, 0, 0]},
                           'background': {'rgb': [255, 255, 255]},
                           'outline': {'present': False}})

    def test_context_limit_rejects_whole_page_input(self):
        packet = self.packet()
        packet['bbox'] = [20, 40, 20, 40]
        with self.assertRaisesRegex(ValueError, '15%'):
            source_runtime._validate(packet, 30.)

    def test_batch_cannot_mix_different_pages(self):
        a, b = self.packet(), self.packet()
        b['sourceHash'] = 'other-page'
        with self.assertRaisesRegex(ValueError, 'one source page'):
            source_runtime.measure_page([a, b], [30., 30.], {})

    def test_fresh_signal_reuse_preserves_prior_and_final_em_contract(self):
        packet = self.packet()
        # Extraneous annotations/IDs must never influence inference.
        packet.update(weight={'label': 'bold'}, itemID='not-a-feature')
        direct = {key: float(i) for i, key in enumerate(source_runtime.DIRECT_KEYS)}
        with patch.object(source_runtime, 'measure', return_value=np.arange(597.)) as base, \
                patch.object(source_runtime, 'observe', return_value=direct) as pixel, \
                patch.object(source_runtime, 'paired_measure', return_value=np.zeros(48)) as pair, \
                patch.object(source_runtime, '_legacy_residual', side_effect=AssertionError('must reuse')):
            raw, paired, _, mixed = source_runtime.measure_page(
                [packet], [28.], {}, fresh_font_signals={'style187': np.ones((1, 262))})
        self.assertEqual(raw.shape, (1, 866))
        np.testing.assert_array_equal(raw[0, 597:604], np.arange(7.))
        np.testing.assert_array_equal(raw[0, 604:], 1.)
        self.assertEqual(base.call_args.args[2], 32.)
        self.assertEqual(pixel.call_args.args[2], 32.)
        self.assertEqual(pair.call_args.args[2], 28.)
        self.assertFalse(mixed[0])

    def test_unqualified_mixed_producer_neither_reads_source_nor_changes_item(self):
        item = {'id': 'opaque-id', 'sourceFontWeight': 'regular', 'renderBold': False}
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('no source needed')):
            self.assertEqual(font_weight_runtime.estimate_page([item], '/absent', 'bad'), [])
        self.assertEqual(item['sourceFontWeight'], 'regular')

    def mixed_item(self):
        return dict(id='opaque-id', frame=[0, 0, 90, 160], fontReference=20.,
                    sourcePredictedStyle={'fill': {'rgb': [255, 255, 255]},
                                          'background': {'rgb': [0, 0, 0]},
                                          'outline': {'present': False}})

    def test_mixed_producer_rejects_source_hash_before_decoding(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'bad.png'
            path.write_bytes(b'not an image')
            with self.assertRaisesRegex(ValueError, 'identity differs'):
                font_weight_runtime.estimate_page([self.mixed_item()], path, 'bad')

    def test_mixed_producer_uses_pixels_and_em_without_region_exception(self):
        image = np.zeros((160, 90, 3), np.uint8)
        for y in range(15, 125, 24):
            image[y:y+16, 12:20] = 255
            image[y:y+16, 43:46] = 255
            image[y:y+16, 73:76] = 255
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'source.png'
            Image.fromarray(image).save(path)
            item = self.mixed_item()
            item['renderBold'] = True
            receipts = font_weight_runtime.estimate_page(
                [item], path, hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(item['sourceFontWeight'], 'mixed')
        self.assertFalse(item['renderBold'])
        self.assertEqual([r['weight'] for r in item['sourceWeightRuns']], ['regular', 'regular', 'bold'])
        self.assertTrue(receipts[0]['sourceOnlyFreshInference'])


if __name__ == '__main__':
    unittest.main()
