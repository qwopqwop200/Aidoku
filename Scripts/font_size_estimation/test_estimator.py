import unittest
import math,pickle,sys,tempfile,hashlib
from pathlib import Path
from unittest.mock import patch
import numpy as np
from estimator import features,harmonize,harmonize_with_witness,predict_matrix,context_features,prediction_groups,signed_log_features,relative_log_features
from ownership_features import ownership_features,page_mask
from technical_ocr_metrics import technical_metrics
from sparse_peer import body_count_from_metrics,correct_sparse_peers
from morphology_features import grouped_body_features,FEATURE_COUNT
from font_metric_features import font_metric_features,glyph_measurement,default_font_paths


class EstimatorTests(unittest.TestCase):
    def test_extended_template_range_recovers_text_below_an_overestimated_prior(self):
        import cv2
        from template_features import template_features,glyph_bitmap,EM
        paths=default_font_paths();bitmap=glyph_bitmap(paths[0],'あ');actual_size=20.
        ink=cv2.resize(bitmap,(round(bitmap.shape[1]*actual_size/EM),round(bitmap.shape[0]*actual_size/EM)),interpolation=cv2.INTER_AREA)
        rgb=np.zeros((100,100,3),np.uint8);h,w=ink.shape;rgb[30:30+h,30:30+w]=ink[:,:,None]
        original=template_features(rgb,[0,0,100,100],80.,'あ',paths,refine=True)
        extended=template_features(rgb,[0,0,100,100],80.,'あ',paths,refine=True,
                                   coarse_scales=(.2,.25,.3,.4,.55,.7,.85,1.,1.3,1.5,2.))
        self.assertGreaterEqual(original[12],.4)
        self.assertLess(extended[12],.3)
        self.assertLess(abs(80*extended[12]-actual_size),1.5)

    def test_native_template_policy_preserves_source_resolution_and_more_glyphs(self):
        from template_features import template_features
        paths=default_font_paths();rgb=np.full((800,100,3),127,np.uint8)
        own=np.ones((800,100),bool);shapes=[]
        def observed(mask,*args,**kwargs):
            shapes.append(mask.shape)
            return None
        with patch('template_features.best_template_match',side_effect=observed):
            legacy=template_features(rgb,[0,0,100,800],40,'あいうえ',paths,ownership=own)
            legacy_calls=len(shapes)
            self.assertEqual(set(shapes),{(480,60)})
            shapes.clear()
            native=template_features(rgb,[0,0,100,800],40,'あいうえ',paths,ownership=own,
                                     max_target_side=1600,glyph_limit=4)
            self.assertEqual(set(shapes),{(800,100)})
            self.assertEqual(len(shapes),2*legacy_calls)
        np.testing.assert_array_equal(legacy[-2:],[1.,1.])
        np.testing.assert_array_equal(native[-2:],[1.,1.])
        self.assertEqual(native.shape,(66,))

    def test_template_measurement_policy_rejects_unusable_settings(self):
        from template_features import template_features
        rgb=np.zeros((40,40,3),np.uint8)
        for size in [0,float('nan'),float('inf')]:
            with self.assertRaisesRegex(ValueError,'resolution'):
                template_features(rgb,[0,0,40,40],40,'あ',['unused']*4,max_target_side=size)
        for limit in [0,9,1.5,True]:
            with self.assertRaisesRegex(ValueError,'glyph limit'):
                template_features(rgb,[0,0,40,40],40,'あ',['unused']*4,glyph_limit=limit)
        for scales in [(),(.4,),(.4,.2),(.2,.2),(.2,float('nan'))]:
            with self.assertRaisesRegex(ValueError,'scale range'):
                template_features(rgb,[0,0,40,40],40,'あ',['unused']*4,coarse_scales=scales)

    def test_bound_ocr_can_support_clustering_when_predicted_body_is_empty(self):
        from source_clusters import apply_source_clustering
        class Certain:
            def predict_proba(self, features):return np.tile([0.,1.],(len(features),1))
        bundle=dict(sourceClustering=dict(model=Certain(),threshold=.5,span=1.5,allowEmptyBodyWithBoundOCR=True))
        evidence=np.zeros((2,291));evidence[:,230]=1.;evidence[:,144]=1.;evidence[:,161]=1.
        np.testing.assert_array_equal(apply_source_clustering(bundle,np.array([40.,44.]),['a','a'],np.zeros((2,156)),evidence),[42.,42.])
        evidence[1,144]=0.
        np.testing.assert_array_equal(apply_source_clustering(bundle,np.array([40.,44.]),['a','a'],np.zeros((2,156)),evidence),[40.,44.])

    def test_numeric_closeness_cannot_override_incompatible_source_evidence(self):
        from source_clusters import merge_glyphs
        source=np.array([[1.,.05],[.05,1.]]);numeric=np.ones((2,2))
        np.testing.assert_array_equal(merge_glyphs([40.,41.],numeric,.5,2.,source_affinity=source,min_source_affinity=.3),[40.,41.])

    def test_larger_scale_gap_requires_stronger_independent_source_support(self):
        from source_clusters import merge_glyphs
        source=np.array([[1.,.65],[.65,1.]])
        np.testing.assert_array_equal(merge_glyphs([40.,52.],source,.5,2.,source_affinity=source,min_source_affinity=.1,source_gap_slope=.8),[40.,52.])
        np.testing.assert_array_equal(merge_glyphs([40.,44.],source,.5,2.,source_affinity=source,min_source_affinity=.1,source_gap_slope=.8),[42.,42.])
        with self.assertRaisesRegex(ValueError,'source affinity'):merge_glyphs([40.,44.],source,.5,2.,source_gap_slope=float('nan'))

    def test_source_cluster_templates_do_not_require_a_size_correction_policy(self):
        from source_evidence import measure_evidence
        from physical_consensus import apply_source_evidence
        bundle=dict(sourceClustering=dict(threshold=.5),physicalReferenceFonts=[])
        signal=np.ones(66)
        with patch('source_evidence.verified_fonts',return_value=['reference']*4),patch('template_features.template_features',return_value=signal) as template:
            actual=measure_evidence(bundle,None,[0,0,20,20],20.,'source',np.ones((20,20),bool))
        np.testing.assert_array_equal(actual,signal);template.assert_called_once()
        np.testing.assert_array_equal(apply_source_evidence(bundle,np.array([20.]),[20.],['a'],signal[None,:]),[20.])

    def test_render_bridge_collects_cluster_evidence_without_physical_correction(self):
        from PIL import Image
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'inpainting_compare'))
        from font_size_runtime import estimate_page
        with tempfile.TemporaryDirectory() as t:
            image=Path(t)/'source.png';mask=Path(t)/'mask.png';model=Path(t)/'model.pkl'
            Image.fromarray(np.full((100,100,3),127,np.uint8)).save(image);Image.fromarray(np.full((100,100),255,np.uint8)).save(mask)
            source_sha=hashlib.sha256(image.read_bytes()).hexdigest()
            with model.open('wb') as f:pickle.dump(dict(featureVersion=4,model=None,logScale=0.,harmonizationRatio=1.,finalClustering=dict(quantum=1.),sourceClustering=dict(threshold=.5)),f)
            meta=dict(predictedMask=True,GTMaskUsed=False,sourceSHA256=source_sha,width=100,height=100,maskPath=str(mask),maskSHA256=hashlib.sha256(mask.read_bytes()).hexdigest())
            item=dict(id='one',frame=[20,20,40,60],fontReference=30.,text='translated-only')
            with patch('estimator.features',return_value=np.zeros(156)),patch('source_clusters.measure_cluster_evidence',return_value=np.ones(291)) as measured,patch('source_clusters.apply_source_clustering',return_value=np.array([31.])):
                estimate_page([item],image,source_sha,model,source_texts={'one':'original-only'},mask_metadata=meta,source_confidences={'one':.8},source_roles={'one':'dialogue'})
            measured.assert_called_once();self.assertEqual(measured.call_args.args[4],'original-only');self.assertEqual(item['fontReference'],31.)

    def test_glyph_community_uses_whole_group_support_and_one_final_size(self):
        from source_clusters import merge_glyphs
        # One weak pair must not prevent a coherent three-glyph community.
        affinity=np.array([[1.,.9,.9,0.],[.9,1.,.2,0.],[.9,.2,1.,0.],[0.,0.,0.,1.]])
        values=np.array([40.,44.,48.,80.])
        np.testing.assert_array_equal(merge_glyphs(values,affinity,.5,1.5),[44.,44.,44.,80.])
        np.testing.assert_array_equal(values,[40.,44.,48.,80.])
        order=np.array([2,3,0,1])
        np.testing.assert_array_equal(merge_glyphs(values[order],affinity[np.ix_(order,order)],.5,1.5),np.array([44.,44.,44.,80.])[order])

    def test_glyph_community_does_not_chain_across_different_sizes(self):
        from source_clusters import merge_glyphs
        affinity=np.ones((3,3));values=[40.,50.,64.]
        out=merge_glyphs(values,affinity,.5,1.5)
        self.assertNotEqual(out[0],out[2])
        with self.assertRaisesRegex(ValueError,'policy'):merge_glyphs(values,affinity,float('nan'),1.5)

    def test_source_communities_require_bound_evidence_and_page_separation(self):
        from source_clusters import apply_source_clustering, EVIDENCE_COUNT
        class Certain:
            def predict_proba(self, features):
                return np.tile([0.,1.],(len(features),1))
        bundle=dict(sourceClustering=dict(model=Certain(),threshold=.5,span=1.5))
        values=np.array([40.,44.,60.,44.]);native=np.zeros((4,156));evidence=np.zeros((4,EVIDENCE_COUNT))
        evidence[:,230]=1.;evidence[:,233]=20.
        np.testing.assert_array_equal(apply_source_clustering(bundle,values,['a','a','a','b'],native,evidence),[44.,44.,44.,44.])
        evidence[1]=0.
        np.testing.assert_array_equal(apply_source_clustering(bundle,values,['a','a','a','b'],native,evidence),[50.,44.,50.,44.])
        np.testing.assert_array_equal(apply_source_clustering(bundle,values,['a']*4,native,None),values)

    def test_glyph_body_uses_owned_outline_when_fill_matches_background(self):
        import cv2
        from glyph_body_features import glyph_body_features
        rgb=np.full((60,60,3),[100,140,180],np.uint8)
        cv2.rectangle(rgb,(18,15),(42,45),(255,255,255),3)
        own=rgb.min(axis=2)>220;before=rgb.copy()
        body=glyph_body_features(rgb,[18,15,25,31],30,own)
        self.assertEqual(body.shape,(56,));self.assertGreater(body[45],20.)
        self.assertEqual(body[55],1.)
        np.testing.assert_array_equal(rgb,before)
        np.testing.assert_array_equal(glyph_body_features(rgb,[18,15,25,31],30,np.zeros((60,60),bool)),np.zeros(56))

    def test_final_clustering_runs_after_physical_evidence_once(self):
        bundle=dict(featureVersion=1,model=None,logScale=0.,harmonizationRatio=1.,physicalConsensus=dict(consensus='concordant',threshold=.75,agreement=.05,strength=.25,clip=.05),finalClustering=dict(quantum=1.))
        signals=np.zeros((3,66));bank=signals[:,:64].reshape(3,4,16)
        bank[:2,:,0:3]=1.2;bank[:2,:,3]=.9;signals[:2,-2:]=1.
        X=np.zeros((3,45));priors=[50.]*3;groups=['a']*3
        early=predict_matrix(bundle,X,priors,groups,source_evidence=signals,finalize=False)
        self.assertNotEqual(early[0],early[2])
        np.testing.assert_array_equal(predict_matrix(bundle,X,priors,groups,source_evidence=signals),[52.,52.,52.])

    def test_final_font_cluster_cannot_split_after_partial_physical_correction(self):
        from font_clusters import finalize_sizes
        before=np.array([50.,50.,50.,90.,50.]);proposed=np.array([51.,51.,50.,90.,50.])
        np.testing.assert_array_equal(finalize_sizes(before,proposed,['a','a','a','a','b'],quantum=1.),[51.,51.,51.,90.,50.])
        np.testing.assert_array_equal(before,[50.,50.,50.,90.,50.])
        order=np.array([4,2,0,3,1]);groups=np.array(['a','a','a','a','b'])
        np.testing.assert_array_equal(finalize_sizes(before[order],proposed[order],groups[order],quantum=1.),np.array([51.,51.,51.,90.,50.])[order])

    def test_final_font_cluster_uses_one_canonical_before_pixel_rounding(self):
        from font_clusters import finalize_sizes
        result=finalize_sizes([50.,50.],[50.49,50.51],['a','a'],quantum=1.)
        self.assertEqual(result[0],result[1]);self.assertEqual(result[0],round(result[0]))
        with self.assertRaisesRegex(ValueError,'font sizes'):finalize_sizes([0.],[1.],['a'])

    def test_measurement_plan_skips_impossible_cohorts_without_losing_members(self):
        from physical_consensus import measurement_plan
        bundle=dict(physicalConsensus=dict(consensus='concordant'))
        before=np.array([50.,50.,50.,80.,50.,50.]);groups=['a','a','a','a','b','b']
        plan=measurement_plan(bundle,before,groups,['あい','うえ','あ','かき','あい','!'])
        np.testing.assert_array_equal(plan,[True,True,True,False,False,False])
        np.testing.assert_array_equal(measurement_plan({},before,groups,['あい']*6),np.zeros(6,bool))

    def test_physical_policy_is_optional_and_applies_after_base_estimation(self):
        policy=dict(consensus='concordant',threshold=.75,agreement=.05,strength=.25,clip=.05)
        bundle=dict(featureVersion=1,model=None,logScale=0.,harmonizationRatio=1.,physicalConsensus=policy)
        X=np.zeros((2,45));priors=np.array([50.,50.]);groups=['same']*2;signals=np.zeros((2,66));bank=signals[:,:64].reshape(2,4,16)
        bank[:,:,0:3]=1.2;bank[:,:,3]=.9;signals[:,-2:]=1.
        old=predict_matrix(bundle,X,priors,groups)
        np.testing.assert_array_equal(old,priors)
        np.testing.assert_allclose(predict_matrix(bundle,X,priors,groups,source_evidence=signals),50*1.2**.25)
        np.testing.assert_array_equal(predict_matrix(bundle,X,priors,groups,source_evidence=np.zeros((2,66))),old)
        with self.assertRaisesRegex(ValueError,'physical font evidence'):predict_matrix(bundle,X,priors,groups,source_evidence=np.zeros((2,65)))

    def test_physical_source_binding_rejects_gt_masks_and_mismatched_fonts(self):
        from source_evidence import predicted_mask,verified_fonts,measure_evidence
        with self.assertRaisesRegex(ValueError,'predicted ownership'):predicted_mask(dict(GTMaskUsed=True,predictedMask=True),'a',[20,20])
        with self.assertRaisesRegex(ValueError,'identity'):predicted_mask(dict(GTMaskUsed=False,predictedMask=True,sourceSHA256='wrong',width=20,height=20),'a',[20,20])
        self.assertIsNone(measure_evidence(dict(physicalConsensus=True),None,None,None,'',None))
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'font';p.write_bytes(b'identity-control')
            with self.assertRaisesRegex(ValueError,'font identity'):verified_fonts(tuple([(str(p),'wrong')]*4))

    def test_render_bridge_uses_bound_source_text_and_never_translation(self):
        from PIL import Image
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'inpainting_compare'))
        from font_size_runtime import estimate_page
        with tempfile.TemporaryDirectory() as t:
            image=Path(t)/'source.png';mask=Path(t)/'predicted.png';model=Path(t)/'model.pkl'
            Image.fromarray(np.full((100,100,3),127,np.uint8)).save(image);Image.fromarray(np.full((100,100),255,np.uint8)).save(mask)
            source_sha=hashlib.sha256(image.read_bytes()).hexdigest()
            policy=dict(consensus='concordant',threshold=.75,agreement=.05,strength=.25,clip=.05)
            with model.open('wb') as f:pickle.dump(dict(featureVersion=1,model=None,logScale=0.,harmonizationRatio=1.,physicalConsensus=policy,physicalReferenceFonts=[]),f)
            item=dict(id='one',frame=[20,20,40,60],fontReference=30.,text='translated-only')
            with patch('estimator.features',return_value=np.zeros(45)),patch('source_evidence.measure_evidence') as measured:
                estimate_page([dict(item)],image,source_sha,model);measured.assert_not_called()
            meta=dict(predictedMask=True,GTMaskUsed=False,sourceSHA256=source_sha,width=100,height=100,maskPath=str(mask),maskSHA256=hashlib.sha256(mask.read_bytes()).hexdigest())
            with patch('estimator.features',return_value=np.zeros(45)),patch('source_evidence.measure_evidence',return_value=np.zeros(66)) as measured:
                output=dict(item);second=dict(item,id='two');receipt=estimate_page([output,second],image,source_sha,model,source_texts={'one':'source-only','two':'source-only'},mask_metadata=meta)
            self.assertEqual(measured.call_args.args[4],'source-only');self.assertEqual(output['text'],'translated-only');self.assertFalse(receipt[0]['physicalCorrectionApplied'])

    def test_owned_templates_ignore_unrelated_pixels_even_when_downsampled(self):
        import cv2
        from template_features import template_features,glyph_bitmap,EM
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        bitmap=glyph_bitmap(paths[0],'あ');prior=80.
        ink=cv2.resize(bitmap,(round(bitmap.shape[1]*prior/EM),round(bitmap.shape[0]*prior/EM)),interpolation=cv2.INTER_AREA)
        rgb=np.zeros((650,650,3),np.uint8);h,w=ink.shape;rgb[250:250+h,250:250+w]=ink[:,:,None]
        own=np.zeros((650,650),bool);own[230:350,230:350]=True;before=rgb.copy()
        first=template_features(rgb,[0,0,650,650],prior,'あ',paths,refine=True,ownership=own)
        np.testing.assert_array_equal(rgb,before)
        rgb[~own]=255
        np.testing.assert_array_equal(template_features(rgb,[0,0,650,650],prior,'あ',paths,refine=True,ownership=own),first)

    def test_empty_ownership_is_explicitly_unavailable_and_geometry_is_checked(self):
        from template_features import template_features
        rgb=np.full((40,40,3),127,np.uint8);paths=['unused']*4
        np.testing.assert_array_equal(template_features(rgb,[0,0,40,40],40,'あ',paths,ownership=np.zeros((40,40),bool)),np.zeros(66))
        with self.assertRaisesRegex(ValueError,'geometry'):template_features(rgb,[0,0,40,40],40,'あ',paths,ownership=np.ones((39,40),bool))

    def test_full_ownership_preserves_the_original_matching_contract(self):
        import cv2
        from template_features import template_features,glyph_bitmap,EM
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        bitmap=glyph_bitmap(paths[0],'あ');prior=60.
        ink=cv2.resize(bitmap,(round(bitmap.shape[1]*prior/EM),round(bitmap.shape[0]*prior/EM)),interpolation=cv2.INTER_AREA)
        rgb=np.zeros((100,100,3),np.uint8);h,w=ink.shape;rgb[20:20+h,20:20+w]=ink[:,:,None]
        plain=template_features(rgb,[0,0,100,100],prior,'あ',paths,refine=True)
        np.testing.assert_array_equal(template_features(rgb,[0,0,100,100],prior,'あ',paths,refine=True,ownership=np.ones((100,100),bool)),plain)

    def test_affine_template_separates_horizontal_compression_from_em(self):
        import cv2
        from template_features import template_features,glyph_bitmap,EM
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        bitmap=glyph_bitmap(paths[0],'あ');prior=80.;factor=.925;aspect=.8
        ink=cv2.resize(bitmap,(round(bitmap.shape[1]*prior*factor*aspect/EM),round(bitmap.shape[0]*prior*factor/EM)),interpolation=cv2.INTER_AREA)
        rgb=np.zeros((140,140,3),np.uint8);h,w=ink.shape;rgb[30:30+h,30:30+w]=ink[:,:,None]
        uniform=template_features(rgb,[0,0,140,140],prior,'あ',paths,refine=True)
        affine=template_features(rgb,[0,0,140,140],prior,'あ',paths,refine=True,affine=True)
        self.assertLess(abs(affine[12]-factor),.03)
        self.assertLess(abs(affine[12]-factor),abs(uniform[12]-factor))
        self.assertGreater(affine[13],.9)
        with self.assertRaisesRegex(ValueError,'requires refinement'):template_features(rgb,[0,0,140,140],prior,'あ',paths,affine=True)

    def test_reference_glyph_transform_keeps_height_em_and_rotates_without_clipping(self):
        from template_features import transformed_glyph
        bitmap=np.zeros((256,256),np.uint8);bitmap[20:236,70:186]=255
        original=transformed_glyph(bitmap,80,1.)
        narrow=transformed_glyph(bitmap,80,1.,.8)
        self.assertEqual(narrow.shape,(80,64));self.assertEqual(original.shape,(80,80))
        rotated=transformed_glyph(bitmap,80,1.,1.,10.)
        self.assertGreater(rotated.shape[0],80);self.assertGreater(rotated.shape[1],80)
        self.assertLess(abs(float(rotated.sum()/original.sum())-1),.02)
        with self.assertRaisesRegex(ValueError,'transform'):transformed_glyph(bitmap,80,1.,0.)

    def test_local_template_refinement_recovers_an_off_grid_scale(self):
        import cv2
        from template_features import template_features,glyph_bitmap,EM
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        bitmap=glyph_bitmap(paths[0],'あ');prior=80.;factor=.925
        ink=cv2.resize(bitmap,(round(bitmap.shape[1]*prior*factor/EM),round(bitmap.shape[0]*prior*factor/EM)),interpolation=cv2.INTER_AREA)
        rgb=np.zeros((130,130,3),np.uint8);h,w=ink.shape;rgb[25:25+h,25:25+w]=ink[:,:,None]
        coarse=template_features(rgb,[0,0,130,130],prior,'あ',paths)
        fine=template_features(rgb,[0,0,130,130],prior,'あ',paths,refine=True)
        self.assertLess(abs(fine[12]-factor),.026)
        self.assertLess(abs(fine[12]-factor),abs(coarse[12]-factor))
        self.assertGreaterEqual(fine[13]+1e-7,coarse[13])

    def test_template_plateau_uses_centre_and_refinement_stays_local(self):
        from template_features import refine_template_match
        mask=np.ones((200,300),np.float32);bitmap=np.ones((20,20),np.uint8)
        shapes=[]
        def tied(local,bitmap,unit,factor):
            shapes.append(local.shape);return .8,(1,1),(10,10)
        with patch('template_features.best_template_match',side_effect=tied):
            score,factor,margin=refine_template_match(mask,bitmap,40,(.8,1.,(100,80),(20,25)))
        self.assertEqual(score,.8);self.assertEqual(margin,0.)
        self.assertTrue(.98<factor<1.02)
        self.assertTrue(all(h<=41 and w<=36 for h,w in shapes))

    def test_physical_template_recovers_a_known_glyph_scale(self):
        import cv2
        from template_features import template_features,glyph_bitmap,EM
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        bitmap=glyph_bitmap(paths[0],'あ');prior=64.;factor=.85
        ink=cv2.resize(bitmap,(round(bitmap.shape[1]*prior*factor/EM),round(bitmap.shape[0]*prior*factor/EM)),interpolation=cv2.INTER_AREA)
        rgb=np.zeros((100,100,3),np.uint8);h,w=ink.shape
        rgb[20:20+h,20:20+w]=ink[:,:,None]
        value=template_features(rgb,[0,0,100,100],prior,'あ',paths)
        self.assertEqual(value.shape,(66,));self.assertAlmostEqual(value[12],factor)
        self.assertGreater(value[13],.9)

    def test_physical_template_ignores_pixels_outside_the_target(self):
        from template_features import template_features
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        rgb=np.full((70,90,3),127,np.uint8);bbox=[20,20,40,40]
        blank=template_features(rgb,bbox,40,'',paths);np.testing.assert_array_equal(blank,np.zeros(66))
        before=template_features(rgb,bbox,40,'あ',paths)
        rgb[:,:19]=0;rgb[:,61:]=255
        np.testing.assert_array_equal(template_features(rgb,bbox,40,'あ',paths),before)

    def test_reference_font_ratios_recover_known_glyph_em(self):
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        glyph=np.asarray(glyph_measurement(paths[0],'あ'));native=np.zeros(156)
        expected=np.repeat(glyph[[2,3,4]],3)
        native[96:105]=expected;native[120:129]=expected
        before=native.copy();value=font_metric_features('ああ',native,paths)
        self.assertEqual(value.shape,(146,))
        np.testing.assert_allclose(value[18:36],np.ones(18))
        np.testing.assert_array_equal(value[-2:],[1.,1.]);np.testing.assert_array_equal(native,before)

    def test_reference_metrics_are_order_invariant_and_normalize_unicode(self):
        try:paths=default_font_paths()
        except ValueError as error:self.skipTest(str(error))
        native=np.zeros(156)
        np.testing.assert_array_equal(font_metric_features('あいあ',native,paths),font_metric_features('いああ',native,paths))
        np.testing.assert_array_equal(font_metric_features('ゔ',native,paths),font_metric_features('う\u3099',native,paths))

    def test_reference_metrics_have_explicit_missing_text_and_glyph_signals(self):
        native=np.zeros(156);paths=['unused']*4
        np.testing.assert_array_equal(font_metric_features('',native,paths),np.zeros(146))
        with patch('font_metric_features.glyph_measurement',return_value=None):
            value=font_metric_features('あ',native,paths)
        np.testing.assert_array_equal(value[:-2],np.zeros(144));np.testing.assert_array_equal(value[-2:],[1.,0.])
        with self.assertRaisesRegex(ValueError,'156'):font_metric_features('',np.zeros(155),paths)

    def test_grouped_bodies_join_nearby_strokes_in_the_right_direction(self):
        rgb=np.full((100,100,3),127,np.uint8)
        rgb[30:50,30:40]=0;rgb[30:50,46:56]=0
        value=grouped_body_features(rgb,[0,0,100,100],40)
        self.assertEqual(len(value),FEATURE_COUNT)
        # Small closing keeps strokes separate; larger horizontal/square joins
        # them, while vertical closing cannot bridge a horizontal gap.
        self.assertAlmostEqual(value[0],20/40)
        self.assertAlmostEqual(value[48],26/40)
        self.assertAlmostEqual(value[56],20/40)
        self.assertAlmostEqual(value[64],26/40)

    def test_grouped_bodies_preserve_blank_and_widely_separated_glyphs(self):
        rgb=np.full((100,100,3),127,np.uint8)
        np.testing.assert_array_equal(grouped_body_features(rgb,[0,0,100,100],40),np.zeros(FEATURE_COUNT))
        rgb[30:50,10:20]=0;rgb[30:50,70:80]=0;before=rgb.copy()
        value=grouped_body_features(rgb,[0,0,100,100],40)
        np.testing.assert_allclose(value[:72].reshape(9,8)[:,:3],.5)
        np.testing.assert_array_equal(rgb,before)

    def test_grouped_bodies_are_crop_bound_and_keep_boundary_evidence(self):
        rgb=np.full((100,140,3),127,np.uint8);rgb[20:40,20:30]=0
        original=grouped_body_features(rgb,[20,20,40,40],40)
        rgb[:,:15]=0;rgb[:,70:]=255
        np.testing.assert_array_equal(grouped_body_features(rgb,[20,20,40,40],40),original)
        self.assertEqual(original[7],1.)
        with self.assertRaisesRegex(ValueError,'prior'):grouped_body_features(rgb,[20,20,40,40],0)

    def test_raw_output_preserves_source_while_context_stays_normalized(self):
        from types import SimpleNamespace
        observed=[]
        def head(x):
            observed.append(x.copy());return np.zeros(len(x))
        bundle=dict(featureVersion=4,model=None,logScale=0.,harmonizationRatio=1.12,
                    contextModel=SimpleNamespace(predict=head),contextStrength=1.,contextClip=.3,contextFinalRatio=1.)
        matrix=np.zeros((2,156));priors=np.array([50.,54.]);groups=['same']*2
        legacy=predict_matrix(bundle,matrix,priors,groups)
        bundle['contextRawWeight']=1.
        np.testing.assert_allclose(predict_matrix(bundle,matrix,priors,groups),priors)
        np.testing.assert_array_equal(observed[0],observed[1])
        np.testing.assert_allclose(legacy,[52.,52.])
        bundle['contextRawWeight']=.5
        np.testing.assert_allclose(predict_matrix(bundle,matrix,priors,groups),np.sqrt(52*priors))
        bundle['contextRawWeight']=float('nan')
        with self.assertRaisesRegex(ValueError,'raw weight'):predict_matrix(bundle,matrix,priors,groups)

    def test_raw_context_appends_displacements_without_mutating_inputs(self):
        matrix=np.zeros((2,156));pred=np.array([52.,52.]);prior=np.array([50.,54.]);raw=prior.copy();groups=['same']*2
        old=context_features(matrix,pred,prior,groups)
        current=context_features(matrix,pred,prior,groups,raw)
        self.assertEqual(current.shape,(2,173))
        np.testing.assert_array_equal(current[:,:171],old)
        np.testing.assert_allclose(current[:,171],np.log(raw/pred),atol=1e-12)
        np.testing.assert_array_equal(current[:,172],np.zeros(2))
        np.testing.assert_array_equal(pred,[52.,52.]);np.testing.assert_array_equal(raw,prior)
        np.testing.assert_array_equal(matrix,np.zeros((2,156)))
        with self.assertRaisesRegex(ValueError,'raw font context'):context_features(matrix,pred,prior,groups,[0,54])

    def test_second_consensus_does_not_chain_separate_source_scales(self):
        from types import SimpleNamespace
        bundle=dict(featureVersion=1,model=None,logScale=0.,harmonizationRatio=1.12,contextModel=SimpleNamespace(predict=lambda x:np.zeros(len(x))),contextStrength=1.,contextClip=.3,contextFinalRatio=1.12)
        X=np.zeros((3,45));priors=[50.,54.,58.];groups=['same']*3
        np.testing.assert_allclose(predict_matrix(bundle,X,priors,groups),[52.,52.,52.])
        bundle['contextWitness']='corrected-raw';np.testing.assert_allclose(predict_matrix(bundle,X,priors,groups),[52.,52.,58.])
        bundle['contextWitnessRatio']=1.2;np.testing.assert_allclose(predict_matrix(bundle,X,priors,groups),[52.,52.,52.])

    def test_new_source_correction_can_rejoin_previously_separate_scales(self):
        from types import SimpleNamespace
        bundle=dict(featureVersion=1,model=None,logScale=0.,harmonizationRatio=1.12,contextModel=SimpleNamespace(predict=lambda x:np.array([0.,0.,math.log(53/58)])),contextStrength=1.,contextClip=.3,contextFinalRatio=1.12,contextWitness='corrected-raw')
        np.testing.assert_allclose(predict_matrix(bundle,np.zeros((3,45)),[50.,54.,58.],['same']*3),[52.,52.,52.])

    def test_witness_consensus_is_order_invariant_when_proposals_tie(self):
        proposals=np.array([50.,50.,54.]);witness=np.array([45.,55.,56.]);order=np.array([1,0,2]);groups=['same']*3
        direct=harmonize_with_witness(proposals,witness,groups,1.12);permuted=harmonize_with_witness(proposals[order],witness[order],groups,1.12);np.testing.assert_allclose(permuted,direct[order])
        np.testing.assert_array_equal(harmonize([50,51],['same']*2,1.12),[50.5,50.5])

    def test_sparse_source_count_is_an_integer_after_ratio_reconstruction(self):
        for text in ['あい','あいう','あいうえ']:
            self.assertEqual(body_count_from_metrics(technical_metrics(text,.9,[50,100],30)),float(len(text)))

    def test_sparse_peer_correction_is_simultaneous_and_absent_evidence_is_identity(self):
        policy=dict(maximumSparseCount=2.,minimumAnchorCount=4.,minimumConfidence=.7,maximumPriorRatio=1.08,minimumPeers=2,maximumPeerSpread=1.12,maximumMoveRatio=1.4,strength=1.)
        values=[47.,61.,62.];priors=[61.,60.,62.];groups=['same']*3;counts=[2.,8.,10.];confidence=[.95]*3
        result=correct_sparse_peers(values,priors,groups,counts,confidence,policy);np.testing.assert_allclose(result,[61.5,61.,62.])
        order=np.array([2,0,1]);shuffled=correct_sparse_peers(np.array(values)[order],np.array(priors)[order],np.array(groups)[order],np.array(counts)[order],np.array(confidence)[order],policy);np.testing.assert_allclose(shuffled,result[order])
        np.testing.assert_array_equal(correct_sparse_peers(values,priors,groups,[np.nan]*3,confidence,policy),values)
        np.testing.assert_array_equal(correct_sparse_peers([61.]*3,priors,groups,counts,confidence,policy),[61.]*3)

    def test_relative_log_head_transform_ignores_absolute_prior_scale(self):
        native=np.array([[math.log(30),2.,-1.,0.],[math.log(60),2.,-1.,0.]])
        result=relative_log_features(native);np.testing.assert_array_equal(result[0],result[1]);self.assertNotEqual(native[0,0],native[1,0]);self.assertTrue(np.isfinite(result).all())
        np.testing.assert_allclose(signed_log_features(np.array([[-2.,0.,2.]])),[[-math.log(3),0.,math.log(3)]])

    def test_technical_ocr_metrics_exclude_word_identity_and_preserve_units(self):
        a=technical_metrics('あい',.9,[60,120],30);b=technical_metrics('うえ',.9,[60,120],30)
        self.assertEqual(len(a),18);np.testing.assert_array_equal(a,b)
        np.testing.assert_allclose(a,technical_metrics('あい',.9,[120,240],60))
        np.testing.assert_array_equal(technical_metrics('が',.9,[60,120],30),technical_metrics('か\u3099',.9,[60,120],30))

    def test_technical_ocr_metrics_handle_empty_source_and_missing_confidence(self):
        value=technical_metrics('',None,[60,120],30);self.assertTrue(np.isfinite(value).all());self.assertEqual(value[15],0.);self.assertEqual(value[16],0.)

    def test_predicted_ownership_excludes_background_noise_without_editing_rgb(self):
        mask=np.zeros((80,80),bool);mask[25:45,25:45]=True
        a=np.full((80,80,3),255,np.uint8);a[mask]=0;b=a.copy();b[~mask]=[240,120,170];before=a.copy()
        first=ownership_features(a,mask,[0,0,80,80],30);second=ownership_features(b,mask,[0,0,80,80],30)
        self.assertEqual(len(first),308);self.assertEqual(first[156],1.)
        np.testing.assert_array_equal(first[158:],second[158:]);np.testing.assert_array_equal(a,before)

    def test_empty_ownership_support_preserves_native_measurements(self):
        rgb=np.full((60,60,3),255,np.uint8);rgb[20:40,20:40]=0;value=ownership_features(rgb,np.zeros((60,60),bool),[0,0,60,60],25)
        np.testing.assert_array_equal(value[:156],features(rgb,[0,0,60,60],25,version=4));self.assertFalse(value[156:].any())
        with self.assertRaisesRegex(ValueError,'geometry'):ownership_features(rgb,np.zeros((50,50),bool),[0,0,60,60],25)

    def test_prediction_mask_hash_and_dimensions_are_enforced(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as t:
            path=Path(t)/'prediction.png';Image.fromarray(np.zeros((12,16),np.uint8)).save(path);digest=hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(page_mask(str(path),digest,16,12).shape,(12,16))
            with self.assertRaisesRegex(ValueError,'identity'):page_mask(str(path),'bad',16,12)
            with self.assertRaisesRegex(ValueError,'dimensions'):page_mask(str(path),digest,12,16)

    def test_harmonization_does_not_chain_emphasis(self):
        sizes=harmonize([50.,54.,58.],['same']*3,1.12)
        self.assertEqual(sizes.tolist(),[52.,52.,58.])

    def test_scale_consensus_keeps_a_shared_size_and_distinct_emphasis(self):
        values=harmonize([50.,54.,58.],['same']*3,1.12,'log_mean')
        self.assertAlmostEqual(values[0],math.sqrt(50*54));self.assertEqual(values[0],values[1]);self.assertEqual(values[2],58.)
        with self.assertRaisesRegex(ValueError,'consensus'):harmonize([50.],['a'],1.12,'unknown')

    def test_trimmed_consensus_is_order_and_scale_invariant(self):
        p=np.array([50.,51.,52.,53.,54.]);groups=['same']*5
        native=harmonize(p,groups,1.12,'trimmed_log_mean');scaled=harmonize(p[::-1]*2,groups,1.12,'trimmed_log_mean')
        np.testing.assert_allclose(scaled/2,native)

    def test_inference_features_do_not_need_labels_or_ids(self):
        rgb=np.full((80,80,3),255,np.uint8);rgb[20:40,20:30]=0;rgb[43:63,20:30]=0
        measured=features(rgb,[10,10,45,60],24)
        self.assertTrue(np.isfinite(measured).all());self.assertGreater(len(measured),30)

    def test_foreground_in_context_does_not_change_target_features(self):
        a=np.full((80,80,3),255,np.uint8);a[25:45,30:40]=0;b=a.copy();b[:15]=0
        np.testing.assert_array_equal(features(a,[20,20,40,40],20),features(b,[20,20,40,40],20))

    def test_identity_model_preserves_native_units(self):
        b=dict(featureVersion=1,model=None,logScale=0.,harmonizationRatio=1.)
        np.testing.assert_equal(predict_matrix(b,np.zeros((2,1)),[20,70],['a','b']),[20,70])

    def test_nonfinite_prior_rejected(self):
        with self.assertRaises(ValueError):features(np.zeros((8,8,3),np.uint8),[0,0,8,8],float('nan'))

    def test_old_measurement_prefixes_remain_exact(self):
        rgb=np.full((130,80,3),255,np.uint8)
        for y in [10,40,70,100]:rgb[y:y+20,20:40]=0
        old=features(rgb,[0,0,80,130],30,version=1)
        second=features(rgb,[0,0,80,130],30,version=2)
        current=features(rgb,[0,0,80,130],30,version=3)
        core=features(rgb,[0,0,80,130],30,version=4)
        oriented=features(rgb,[0,0,80,130],30,version=5)
        self.assertEqual((len(old),len(second),len(current)),(45,96,132))
        np.testing.assert_array_equal(old,current[:45]);np.testing.assert_array_equal(second,current[:96])
        self.assertEqual(len(core),156);np.testing.assert_array_equal(core[:96],second)
        self.assertEqual(len(oriented),196);np.testing.assert_array_equal(oriented[:156],core)

    def test_oriented_body_measurement_survives_rotation(self):
        import cv2
        values=[]
        for angle in [0,30]:
            rgb=np.full((128,128,3),[100,150,100],np.uint8)
            polygon=cv2.boxPoints(((64.,64.),(40.,20.),angle)).round().astype(np.int32)
            cv2.fillConvexPoly(rgb,polygon,(255,255,255));values.append(features(rgb,[0,0,128,128],32,version=5))
        # White-body oriented long side stays near 40px despite bbox inflation.
        self.assertLess(abs(values[0][176]-values[1][176]),.1)
        self.assertGreater(abs(values[0][120]-values[1][120]),.1)

    def test_white_body_measurement_does_not_expand_with_colored_outline(self):
        values=[]
        for halo in [3,8]:
            rgb=np.full((80,80,3),[230,180,140],np.uint8)
            rgb[30-halo:50+halo,30-halo:50+halo]=[250,110,0];rgb[30:50,30:50]=255
            values.append(features(rgb,[0,0,80,80],30,version=4))
        np.testing.assert_allclose(values[0][120:129],values[1][120:129])
        self.assertGreater(values[0][120],0)

    def test_train_derived_bounds_can_recover_a_bad_prior(self):
        bundle=dict(featureVersion=3,model=None,logScale=math.log(.3),harmonizationRatio=1.,correctionBounds=[-1.5,1.])
        value=predict_matrix(bundle,np.zeros((1,132)),[100],['a'])[0]
        self.assertAlmostEqual(value,30)

    def test_context_is_order_invariant_and_has_no_cross_page_influence(self):
        X=np.arange(12).reshape(4,3);values=np.array([50.,55.,45.,200.]);prior=[50]*4;groups=np.array(['page']*3+['other']);order=np.array([2,0,3,1]);original=context_features(X,values,prior,groups)
        shuffled=context_features(X[order],values[order],np.array(prior)[order],groups[order]);np.testing.assert_allclose(shuffled,original[order])
        changed=values.copy();changed[3]=20
        np.testing.assert_allclose(context_features(X,changed,prior,groups)[:3],original[:3])

    def test_identical_source_packets_get_separate_context(self):
        rows=[dict(sourceImageSHA256='a',page='one'),dict(sourceImageSHA256='a',page='two')]
        self.assertNotEqual(*prediction_groups(rows))

    def test_context_correction_is_bounded_and_preserves_emphasis(self):
        from types import SimpleNamespace
        bundle=dict(featureVersion=2,model=None,logScale=0.,harmonizationRatio=1.12,
                    contextModel=SimpleNamespace(predict=lambda x:np.full(len(x),10.)),contextStrength=.5,contextClip=.15,contextFinalRatio=1.06)
        values=predict_matrix(bundle,np.zeros((2,96)),[50.,100.],['same','same'])
        np.testing.assert_allclose(values,[50*np.exp(.15),100*np.exp(.15)])
        self.assertAlmostEqual(values[1]/values[0],2.)

    def test_scale_auxiliary_blends_in_relative_log_units(self):
        from types import SimpleNamespace
        observed=[]
        def auxiliary(x):
            observed.append(x.shape[1]);return np.full(len(x),math.log(1.44))
        bundle=dict(featureVersion=2,model=None,logScale=0.,harmonizationRatio=1.,
                    auxiliaryModel=SimpleNamespace(predict=auxiliary),auxiliaryWeight=.5,auxiliaryFeatureIndices=[1,2])
        values=predict_matrix(bundle,np.zeros((2,96)),[50.,100.],['a','b'])
        np.testing.assert_allclose(values,[60.,120.]);self.assertEqual(observed,[2])
        bundle['auxiliaryWeight']=1.5
        with self.assertRaisesRegex(ValueError,'mixture weight'):predict_matrix(bundle,np.zeros((2,96)),[50.,100.],['a','b'])

    def test_extended_color_context_preserves_the_frozen_base_input_contract(self):
        from types import SimpleNamespace
        observed=[]
        def base(x):observed.append(('base',x.shape[1]));return np.zeros(len(x))
        def head(x):observed.append(('head',x.shape[1]));return np.zeros(len(x))
        bundle=dict(featureVersion=4,model=SimpleNamespace(predict=base),modelFeatureCount=96,logScale=0.,harmonizationRatio=1.,
                    contextModel=SimpleNamespace(predict=head),contextBaseFeatureCount=156,contextStrength=.5,contextClip=.15,contextFinalRatio=1.)
        np.testing.assert_equal(predict_matrix(bundle,np.zeros((2,156)),[50.,100.],['a','a']),[50.,100.])
        self.assertEqual(observed,[('base',96),('head',171)])
        observed.clear();bundle.update(featureVersion=5,contextBaseFeatureCount=196)
        np.testing.assert_equal(predict_matrix(bundle,np.zeros((2,196)),[50.,100.],['a','a']),[50.,100.])
        self.assertEqual(observed,[('base',96),('head',211)])

    def test_experimental_context_mixture_is_convex_in_log_size(self):
        from types import SimpleNamespace
        def variant(scale,count):
            return dict(model=SimpleNamespace(predict=lambda x:np.full(len(x),math.log(scale))),featureCount=count,strength=1.,clip=.3,finalRatio=1.,weight=.5)
        bundle=dict(featureVersion=4,model=None,logScale=0.,harmonizationRatio=1.,contextEnsemble=[variant(1.2,96),variant(.8,156)],ensembleFinalRatio=1.)
        values=predict_matrix(bundle,np.zeros((2,156)),[50.,100.],['a','b'])
        np.testing.assert_allclose(values,np.array([50.,100.])*math.sqrt(.96))
        bundle['contextEnsemble'][0]['weight']=1.
        with self.assertRaisesRegex(ValueError,'mixture weights'):predict_matrix(bundle,np.zeros((2,156)),[50.,100.],['a','b'])

    def test_render_bridge_preserves_geometry_and_uses_bounded_crop(self):
        from PIL import Image
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'inpainting_compare'))
        from font_size_runtime import estimate_page
        with tempfile.TemporaryDirectory() as t:
            image=Path(t)/'source.png';Image.fromarray(np.full((200,300,3),255,np.uint8)).save(image)
            before=hashlib.sha256(image.read_bytes()).hexdigest();model=Path(t)/'model.pkl'
            with model.open('wb') as f:pickle.dump(dict(featureVersion=1,model=None,logScale=math.log(1.2),harmonizationRatio=1.),f)
            item=dict(id='transport-only',frame=[100,70,40,60],fontReference=30,text='unchanged')
            with patch('estimator.features',return_value=np.zeros(45)) as measured:
                receipt=estimate_page([item],image,'a'*64,model)
            self.assertEqual(measured.call_args.args[0].shape[:2],(78,52))
            self.assertAlmostEqual(item['fontReference'],36);self.assertEqual(item['frame'],[100,70,40,60]);self.assertEqual(item['text'],'unchanged')
            self.assertFalse(receipt[0]['GTFontLabelsUsed']);self.assertEqual(before,hashlib.sha256(image.read_bytes()).hexdigest())


if __name__=='__main__':unittest.main()
