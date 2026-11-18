import unittest
import numpy as np

from features import page_context, render_policy, stroke_summary
from pixel_rules import observe,infer_page
from line_weights import analyze
from physical_templates import bitmap,font_pairs,paired_patterns,match_pair
from fill_body import measure as measure_fill
from optimized_features.fill_alpha import predicted_fill_alpha
from physical_correction import white_body_bold
from physical_correction import POLICY
from runtime import predict_page
from pointwise_strokes import paired_stats
from line_weights import source_palette_qualifies


class WeightEvidenceTests(unittest.TestCase):
    def test_mixed_source_never_bolds_entire_translation(self):
        policy=render_policy('mixed')
        self.assertFalse(policy['renderBold'])
        self.assertEqual(policy['renderWeight'],'regular')
        self.assertTrue(policy['requiresTranslationSpanAlignment'])
        self.assertTrue(render_policy('bold')['renderBold'])
        self.assertFalse(render_policy('regular')['renderBold'])

    def test_thick_body_is_measured_independently_of_canvas_size(self):
        thin=np.zeros((80,80),np.uint8);thin[10:70,34:38]=1
        thick=np.zeros((80,80),np.uint8);thick[10:70,31:41]=1
        self.assertGreater(stroke_summary(thick,60)[2],stroke_summary(thin,60)[2])

    def test_page_context_is_permutation_equivariant(self):
        x=np.array([[1.,2.],[3.,1.],[7.,4.]])
        perm=[2,0,1]
        np.testing.assert_allclose(page_context(x)[perm],page_context(x[perm]))

    def test_pixel_rule_uses_source_strokes_without_a_classifier(self):
        image=np.full((120,60,3),255,np.uint8)
        image[12:42,24:32]=0;image[60:90,24:32]=0
        observation=observe(image,[0,0,60,120],32)
        self.assertGreater(observation['glyphCount'],0)
        self.assertGreater(observation['bodyThickness'],0)
        policy={'absoluteThickness':0.01,'relativeFloor':0.01,'relativeRatio':1.,'minGlyphs':1,'minQuality':0.,'maxHollow':1.}
        self.assertEqual(infer_page([observation],policy),[True])
        policy['absoluteThickness']=10.;policy['relativeFloor']=10.
        self.assertEqual(infer_page([observation],policy),[False])

    def test_mixed_line_detector_needs_no_region_exception(self):
        image=np.zeros((160,90,3),np.uint8)
        for y in range(15,125,24):
            image[y:y+16,12:20]=255
            image[y:y+16,43:46]=255
            image[y:y+16,73:76]=255
        result=analyze(image,[0,0,90,160],20)
        self.assertEqual(result['sourceWeight'],'mixed')
        self.assertEqual([r['weight'] for r in result['styleRuns']],['regular','regular','bold'])
        self.assertFalse(result['renderPolicy']['renderBold'])

    def test_physical_pair_distinguishes_weight_at_shared_location(self):
        pa,ia,pb,ib=font_pairs()[0]
        regular=bitmap(pa,ia,'あ');heavy=bitmap(pb,ib,'あ')
        patterns=paired_patterns(regular,heavy,32)
        a=match_pair([np.pad(patterns[0],8)],regular,heavy,32)
        b=match_pair([np.pad(patterns[1],8)],regular,heavy,32)
        self.assertGreater(a[1],a[2])
        self.assertGreater(b[2],b[1])

    def test_source_fill_excludes_bright_outline(self):
        import cv2
        glyph=np.zeros((80,40),np.uint8);glyph[10:35,16:22]=1;glyph[45:70,16:22]=1
        outline=cv2.dilate(glyph,np.ones((5,5),np.uint8))>0
        rgb=np.full((80,40,3),[240,170,180],np.uint8);rgb[outline]=255;rgb[glyph>0]=[120,20,150]
        style={'fill':{'rgb':[120,20,150]},'outline':{'present':True,'rgb':[255,255,255],'widthPx':2},'background':{'rgb':[240,170,180]},'shadow':{'present':False}}
        alpha=predicted_fill_alpha(rgb,[0,0,40,80],outline,style)
        self.assertGreater(float(alpha[glyph>0].mean()),.99)
        self.assertLess(float(alpha[outline&(glyph==0)].mean()),.01)
        value=measure_fill(rgb,[0,0,40,80],30,outline,style)
        self.assertEqual(value.shape,(71,))
        self.assertTrue(np.isfinite(value).all())

    def test_white_physical_correction_rejects_thin_handwriting(self):
        style={'fill':{'rgb':[255,255,255]},'background':{'rgb':[0,0,0]},'outline':{'present':False}}
        evidence=np.zeros((3,2,8));evidence[1,0,5]=1;evidence[2,0,5]=1
        evidence[1,0,3]=0.;evidence[2,0,0]=.7;evidence[2,0,3]=.12
        self.assertTrue(white_body_bold(style,evidence.ravel()))
        evidence[1,0,3]=-.2
        self.assertFalse(white_body_bold(style,evidence.ravel()))

    def test_tight_localization_does_not_discard_owned_body_strokes(self):
        rgb=np.full((80,40,3),255,np.uint8);rgb[12:42,10:20]=0
        own=np.zeros((80,40),bool);own[12:42,10:20]=True
        style={'fill':{'rgb':[0,0,0]},'outline':{'present':False},'background':{'rgb':[255,255,255]},'shadow':{'present':False}}
        value=measure_fill(rgb,[10,12,10,30],30,own,style)
        self.assertGreater(value[2],.1)

    def test_runtime_mixed_signal_overrides_binary_bold(self):
        class Head:
            def predict_proba(self,x):return np.tile([.1,.9],(len(x),1))
        bundle={'model':Head(),'threshold':.5,'rawFeatureCount':2,'featureCount':6,'physicalCorrection':POLICY}
        styles=[{'fill':{'rgb':[0,0,0]},'background':{'rgb':[255,255,255]}}]*2
        result=predict_page(bundle,np.ones((2,2)),styles,np.zeros((2,48)),source_mixed=[False,True])
        self.assertEqual([r['sourceWeight'] for r in result],['bold','mixed'])
        self.assertEqual([r['renderBold'] for r in result],[True,False])

    def test_pointwise_boundary_displacement_is_zero_for_identical_glyphs(self):
        reference=np.zeros((50,50),np.float32);reference[10:40,20:25]=1
        value=paired_stats(reference,reference,40)
        np.testing.assert_allclose(value[:19],0,atol=1e-7)
        self.assertAlmostEqual(value[20],1.)

    def test_pointwise_boundary_displacement_detects_added_stroke(self):
        import cv2
        reference=np.zeros((50,50),np.float32);reference[10:40,20:25]=1
        thick=cv2.dilate(reference,np.ones((3,3),np.uint8))
        value=paired_stats(thick,reference,40)
        self.assertGreater(value[2],0)
        self.assertGreater(value[7],0)
        self.assertGreater(value[12],0)

    def test_mixed_gate_requires_known_clean_source_palette(self):
        self.assertFalse(source_palette_qualifies(None))
        self.assertFalse(source_palette_qualifies({'fill':{'rgb':[255,255,255]},'background':{'rgb':[0,0,0]}}))
        style={'fill':{'rgb':[255,255,255]},'background':{'rgb':[0,0,0]},'outline':{'present':False}}
        self.assertTrue(source_palette_qualifies(style))
        style['outline']['present']=True
        self.assertFalse(source_palette_qualifies(style))


if __name__=='__main__':unittest.main()
