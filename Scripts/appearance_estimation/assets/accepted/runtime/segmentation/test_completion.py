"""Independent brute mask counts and OpenCV/native morphology parity."""
import json
import os
import subprocess
import unittest
import tempfile
import copy
from pathlib import Path
from unittest.mock import patch

import cv2
import numpy as np

from hysteresis_completion import union_counts
from multiscale_completion import triple_counts
from pixel_rfdetr_fusion import fit_forest,merge_forests
from export_forest import flatten,collapse_constant_branches
from connected_completion import component_strength
from native_predict import classifier_identity,load_classifier_observation,observation_contract
from evaluate_gt import sha
from boundary_refiner import validate_oof,source_features
from prepare_oof_primary import source_fold
from rf_weak_rescue import sample_points
from prepare_full_rf import sample
from boundary_refiner import sample_case,sample_hard_case
from PIL import Image
import boundary_rf_gate
import boundary_rf_rescue
from boundary_color_gate import source_color_distances
from boundary_color_styles import select_pair
from native_boundary_refiner import build as build_boundary_runtime
from boundary_uniformity import uniform_removed_counts,edge_distances
from boundary_recovery import joint_candidates
from boundary_uniformity_dense import diamond_maximum,rgb_gradient
from train_edge_boundary import edge_features
import verify_color_gate_masks


class CompletionTests(unittest.TestCase):
    def test_mask_reference_uses_authenticated_boundary_votes_and_rejects_mixed_base(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);(root/'native-masks').mkdir()
            rgb=np.zeros((3,3,3),np.uint8);rgb.tofile(root/'rgb')
            p=np.zeros((3,3),np.float32);q=p.copy();q[1,1]=1
            base=np.zeros((3,3),np.uint8)
            expected=np.zeros((3,3),np.uint8);expected[1,1]=255
            expected.tofile(root/'native-masks/case.u8')
            row=dict(id='case',rgb=str(root/'rgb'),height=3,width=3,fontPixels=8)
            model=dict(threshold=.5,completion=dict(unionNative=False,kernel='square',
                       minimumRadiusPixels=1,maximumRadiusPixels=1,radiusFontScale=0))
            with patch.object(verify_color_gate_masks,'_MODEL',model), \
                 patch.object(verify_color_gate_masks,'_PRIMARY',('primary',64,'binary-p')), \
                 patch.object(verify_color_gate_masks,'_BOUNDARY',('boundary',48,'binary-q',root)), \
                 patch.object(verify_color_gate_masks,'observation_contract',return_value={'source':'fixed'}), \
                 patch.object(verify_color_gate_masks,'load_classifier_observation',side_effect=[(p,base),(q,base)]) as loader:
                self.assertEqual(verify_color_gate_masks.verify((row,root,root,root,root)),9)
                self.assertEqual(loader.call_args.args[1]['primaryClassifierSHA256'],'primary')
            with patch.object(verify_color_gate_masks,'_MODEL',model), \
                 patch.object(verify_color_gate_masks,'_PRIMARY',('primary',64,'binary-p')), \
                 patch.object(verify_color_gate_masks,'_BOUNDARY',('boundary',48,'binary-q',root)), \
                 patch.object(verify_color_gate_masks,'observation_contract',return_value={}), \
                 patch.object(verify_color_gate_masks,'load_classifier_observation',side_effect=[(p,base),(q,base+1)]):
                with self.assertRaisesRegex(ValueError,'boundary observation mismatch'):
                    verify_color_gate_masks.verify((row,root,root,root,root))

    def test_new_edge_features_are_source_only_and_color_offset_invariant(self):
        rng=np.random.default_rng(75)
        rgb=rng.integers(20,100,(13,17,3),dtype=np.uint8)
        a=edge_features(rgb,37.2);b=edge_features(rgb+np.array([10,20,30],np.uint8),37.2)
        np.testing.assert_array_equal(a,b)
        self.assertEqual(a.shape,(13*17,5));self.assertTrue(np.isfinite(a).all())
        self.assertTrue(np.all((a>=0)&(a<=1)))
        for font in [1,64,1024]:
            solid=edge_features(np.full((2,7,3),[35,75,125],np.uint8),font)
            np.testing.assert_array_equal(solid[:,:3],1)
            np.testing.assert_array_equal(solid[:,3:],0)

    def test_diamond_maxima_equal_direct_distance_thresholds(self):
        rng=np.random.default_rng(3)
        for height,width in [(1,1),(2,7),(15,19)]:
            solid=np.zeros((height,width,3),np.uint8);rectangle=solid.copy();rectangle[:,width//2:]=[32,128,64]
            for rgb in [solid,rectangle,rng.integers(0,256,(height,width,3),dtype=np.uint8)]:
                gradient=rgb_gradient(rgb)
                for distance in [1,2,3,7,65535]:
                    maximum=diamond_maximum(gradient,distance)
                    for contrast in [1,8,16,32,37,128,255]:
                        np.testing.assert_array_equal(maximum<contrast,edge_distances(rgb,contrast)>=distance)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_BOUNDARY_BINARY'),'Set native contextual boundary replay')
    def test_recovery_uses_immutable_pre_uniformity_seeds_and_native_support(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);rgb=np.zeros((5,9,3),np.uint8);rgb[1,1,0]=25;rgb.tofile(root/'rgb')
            p=np.full((5,9),.01,np.float32);q=np.zeros((5,9),np.float32)
            p[2,2]=.25;q[2,2]=.2;p[2,6]=q[2,6]=1;p.tofile(root/'p');q.tofile(root/'q')
            native=np.full((5,9),255,np.uint8);native[2,3]=0;native.tofile(root/'base')
            uniform=dict(contrastThreshold=255,distanceFontScale=.05,minimumDistancePixels=2,maximumPrimaryProbability=.5,maximumBoundaryProbability=.3,preserveConsensusNeighbors=False,consensusRadius=1,primarySeedThreshold=.5,boundarySeedThreshold=.3)
            recovery=dict(primarySeedThreshold=.25,boundarySeedThreshold=.1,radius=1,requireNativeSupport=False,maximumEdgeDistancePixels=-1,edgeContrastThreshold=16,colorTolerance=0)
            model=dict(schema=1,featureCount=55,sourceFeatureVariant='pixel-boundary-full-rf-v1',sourceModelSHA256='1'*64,primarySourceModelSHA256='0'*64,threshold=.5,trees=[[dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]],completion=dict(unionNative=False,radiusFontScale=0,minimumRadiusPixels=0,maximumRadiusPixels=0,weakThreshold=.1),boundaryEvidenceGate=dict(primaryThreshold=0,boundaryThreshold=0,includeNativeSupport=False,uniformityGate=uniform,recoveryGate=recovery))
            message=dict(rgb=str(root/'rgb'),primary=str(root/'p'),boundaryProbabilities=str(root/'q'),nativeMask=str(root/'base'),coarseRF='',fullRF='',width=9,height=5,fontPixels=12,output=str(root/'output'))
            for required in [False,True]:
                recovery['requireNativeSupport']=required;(root/'model').write_text(json.dumps(model))
                subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                expected=np.zeros((5,9),np.uint8);expected[1:4,1:4]=255;expected[1:4,5:8]=255
                expected[1,1]=expected[2,2]=0
                if required:expected[2,3]=0
                np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8).reshape(5,9),expected)
            recovery['radius']=4;(root/'model').write_text(json.dumps(model))
            rejected=subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True)
            self.assertNotEqual(rejected.returncode,0)

    def test_joint_recovery_removal_equals_exhaustive_disjoint_counts(self):
        rng=np.random.default_rng(821);base=np.array([[1000,500,100]]*3,np.int64)
        for _ in range(20):
            remove=rng.integers(0,101,(3,17,2));remove[:,:,0]%=21;remove[:,0]=0
            add=rng.integers(0,101,(3,13,2));add[:,:,0]%=31;add[:,0]=0
            result=joint_candidates(base,remove,add,2985,1000)
            self.assertIsNotNone(result);_,_,actual=result
            expected=-1
            for u in range(remove.shape[1]):
                for g in range(add.shape[1]):
                    counts=base.copy()
                    for split in range(3):
                        counts[split,0]+=add[split,g,0]-remove[split,u,0]
                        counts[split,1]+=add[split,g,1]-remove[split,u,1]
                        counts[split,2]+=remove[split,u,0]-add[split,g,0]
                    if counts[:,0].sum()<2985 or counts[2,0]<1000:continue
                    total=counts.sum(0);expected=max(expected,total[0]/total.sum())
            total=actual.sum(0)
            self.assertAlmostEqual(total[0]/total.sum(),expected,places=14)

    def test_joint_search_enforces_test_iou_without_hiding_aggregate_gain(self):
        baseline=np.array([[100,100,1],[100,100,1],[100,10,1]],np.int64)
        removed=np.zeros((3,2,2),np.int64)
        removed[:2,1,1]=90;removed[2,1,0]=1
        added=np.zeros((3,1,2),np.int64)
        unrestricted=joint_candidates(baseline,removed,added,299,99)
        self.assertEqual(unrestricted[0],1)
        guarded=joint_candidates(baseline,removed,added,299,99,100/111)
        self.assertEqual(guarded[0],0)
        self.assertIsNone(joint_candidates(baseline,removed,added,299,99,1))

    def test_pruned_recovery_search_matches_brute_force_with_test_guard(self):
        rng=np.random.default_rng(412)
        baseline=np.array([[1000,500,100]]*3,np.int64)
        for _ in range(20):
            removed=rng.integers(0,20,(3,9,2));removed[:,0]=0
            added=rng.integers(0,30,(3,11,2));added[:,0]=0
            guarded=joint_candidates(baseline,removed,added,2980,1000,.625)
            self.assertIsNotNone(guarded)
            expected=-1
            for u in range(removed.shape[1]):
                for g in range(added.shape[1]):
                    delta=added[:,g]-removed[:,u]
                    values=baseline+np.stack([delta[:,0],delta[:,1],-delta[:,0]],axis=1)
                    total=values.sum(0)
                    if total[0]<2980 or values[2,0]<1000 or values[2,0]/values[2].sum()<.625:continue
                    expected=max(expected,total[0]/total.sum())
            actual=guarded[2].sum(0)
            self.assertAlmostEqual(actual[0]/actual.sum(),expected,places=14)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_BOUNDARY_BINARY'),'Set native contextual boundary replay')
    def test_native_uniformity_features_match_rgb_edges_and_bounded_distance(self):
        rng=np.random.default_rng(17)
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch)
            for height,width in [(1,1),(2,7),(31,41)]:
                cases=[np.zeros((height,width,3),np.uint8),rng.integers(0,256,(height,width,3),dtype=np.uint8)]
                rectangle=np.zeros((height,width,3),np.uint8);rectangle[height//4:3*height//4,width//4:3*width//4]=[32,64,128];cases.append(rectangle)
                np.zeros((height,width),np.float32).tofile(root/'p');np.zeros((height,width),np.uint8).tofile(root/'base')
                for rgb in cases:
                    rgb.tofile(root/'rgb')
                    for threshold in [1,16,48,255]:
                        message=dict(rgb=str(root/'rgb'),primary=str(root/'p'),nativeMask=str(root/'base'),coarseRF='',fullRF='',width=width,height=height,fontPixels=12,output=str(root/'features'),uniformityContrastThreshold=threshold)
                        subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],'--uniformity-features'],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                        np.testing.assert_array_equal(np.fromfile(root/'features',np.int32).reshape(height,width),edge_distances(rgb,threshold))

    @unittest.skipUnless(os.environ.get('SEGMENTATION_BOUNDARY_BINARY'),'Set native contextual boundary replay')
    def test_uniform_gate_protects_consensus_without_recursive_expansion(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);np.zeros((5,7,3),np.uint8).tofile(root/'rgb');np.zeros((5,7),np.uint8).tofile(root/'base')
            p=np.full((5,7),.01,np.float32);q=p.copy();p[2,2]=q[2,2]=1;p[2,5]=1;p.tofile(root/'p');q.tofile(root/'q')
            uniform=dict(contrastThreshold=16,distanceFontScale=.05,minimumDistancePixels=2,maximumPrimaryProbability=.1,maximumBoundaryProbability=.1,preserveConsensusNeighbors=True,consensusRadius=1,primarySeedThreshold=.5,boundarySeedThreshold=.3)
            model=dict(schema=1,featureCount=55,sourceFeatureVariant='pixel-boundary-full-rf-v1',sourceModelSHA256='1'*64,primarySourceModelSHA256='0'*64,threshold=.5,trees=[[dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]],completion=dict(unionNative=False,radiusFontScale=0,minimumRadiusPixels=0,maximumRadiusPixels=0,weakThreshold=0),boundaryEvidenceGate=dict(primaryThreshold=0,boundaryThreshold=0,includeNativeSupport=False,uniformityGate=uniform))
            message=dict(rgb=str(root/'rgb'),primary=str(root/'p'),boundaryProbabilities=str(root/'q'),nativeMask=str(root/'base'),coarseRF='',fullRF='',width=7,height=5,fontPixels=12,output=str(root/'output'))
            for protected in [False,True]:
                uniform['preserveConsensusNeighbors']=protected;(root/'model').write_text(json.dumps(model))
                subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                expected=np.zeros((5,7),np.uint8);expected[2,2]=expected[2,5]=255
                if protected:expected[1:4,1:4]=255
                np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8).reshape(5,7),expected)
            message['fontPixels']=1e30
            subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            self.assertTrue(np.all(np.fromfile(root/'output',np.uint8)==255))
            uniform['contrastThreshold']=0;(root/'model').write_text(json.dumps(model))
            rejected=subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True)
            self.assertNotEqual(rejected.returncode,0)

    def test_uniformity_histograms_equal_explicit_source_masks(self):
        rng=np.random.default_rng(918)
        for shape in [(1,1),(2,7),(19,23)]:
            p=rng.integers(0,65,shape,dtype=np.uint8);q=rng.integers(0,49,shape,dtype=np.uint8)
            d=rng.integers(0,25,shape);target=rng.random(shape)>.5;mask=rng.random(shape)>.4
            scales=[.025,.1,.5];primary=[1,15,63];boundary=[0,7,47]
            for font in [1,11.3,91.7]:
                counts=uniform_removed_counts(p,q,d,target,mask,font,scales,primary,boundary)
                index=0
                for scale in scales:
                    for pv in primary:
                        for qv in boundary:
                            removed=mask&(p<=pv)&(q<=qv)&(d>=max(2,int(np.ceil(font*scale))))
                            np.testing.assert_array_equal(counts[index],[np.count_nonzero(removed&target),np.count_nonzero(removed&~target)])
                            index+=1

    def test_uniform_edge_distance_has_no_invented_crop_border_edges(self):
        self.assertTrue(np.all(edge_distances(np.zeros((2,7,3),np.uint8),16)==65534))
        rgb=np.zeros((5,7,3),np.uint8);rgb[:,3:]=255
        expected=np.tile([2,1,0,0,1,2,3],(5,1))
        np.testing.assert_array_equal(edge_distances(rgb,16),expected)

    def test_frozen_boundary_vote_producer_is_not_rebuilt_in_place(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);(root/'FROZEN-CLASSIFIER-PRODUCER.json').write_text('{}')
            with patch('native_boundary_refiner.subprocess.check_output',return_value=b'test compiler'),patch('native_boundary_refiner.subprocess.run') as compile_call:
                with self.assertRaisesRegex(RuntimeError,'Frozen boundary producer'):
                    build_boundary_runtime(root)
                compile_call.assert_not_called()

    def test_style_frontiers_keep_the_exhaustive_two_policy_optimum(self):
        rng=np.random.default_rng(54);baseline=np.array([[1000,500,5]]*3,np.int64)
        for _ in range(20):
            first=np.zeros((21,3,2),np.int64);second=np.zeros((18,3,2),np.int64)
            for data in [first,second]:
                data[1:,:,0]=rng.integers(0,4,(len(data)-1,3))
                data[1:,:,1]=rng.integers(0,9,(len(data)-1,3))
            (a,b,delta),_=select_pair(first,second,baseline,12,5)
            expected=-1
            for left in first:
                for right in second:
                    loss=left+right
                    if loss[:,0].sum()>12 or loss[2,0]>5:continue
                    tp=3000-int(loss[:,0].sum());fp=1500-int(loss[:,1].sum());fn=15+int(loss[:,0].sum())
                    expected=max(expected,tp/(tp+fp+fn))
            actual=(3000-int(delta[:,0].sum()))/(4515-int(delta[:,1].sum()))
            self.assertAlmostEqual(actual,expected,places=14)

    def test_color_distance_matches_bounded_brute_force_at_crop_edges(self):
        rng=np.random.default_rng(823)
        for height,width in [(1,1),(2,7),(13,19)]:
            rgb=rng.integers(0,256,(height,width,3),dtype=np.uint8)
            for seeds in [np.zeros((height,width),bool),rng.random((height,width))>.7]:
                positions=np.arange(height*width)
                for radius,actual in zip([1,2,3],source_color_distances(rgb,seeds,positions)):
                    for index in positions:
                        y,x=divmod(int(index),width);expected=256
                        for sy in range(max(0,y-radius),min(height,y+radius+1)):
                            for sx in range(max(0,x-radius),min(width,x+radius+1)):
                                if seeds[sy,sx]:expected=min(expected,int(np.max(np.abs(rgb[y,x].astype(int)-rgb[sy,sx].astype(int)))))
                        self.assertEqual(actual[index],expected)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_BOUNDARY_BINARY'),'Set native contextual boundary replay')
    def test_native_color_corroboration_requires_nearby_classifier_seed_and_matching_rgb(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);rgb=np.full((5,5,3),[70,90,110],np.uint8);rgb[2,3,2]=135;rgb.tofile(root/'rgb')
            p=np.zeros((5,5),np.float32);p[2,2]=1;p[2,3]=.125;p.tofile(root/'p')
            np.zeros((5,5),np.uint8).tofile(root/'base');np.zeros((5,5,4),np.float32).tofile(root/'coarse');np.zeros((5,5,27),np.float32).tofile(root/'full')
            tree=[dict(feature=0,threshold=.5,left=1,right=2,positive=-1),dict(feature=-1,threshold=0,left=-1,right=-1,positive=0),dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]
            model=dict(schema=1,featureCount=55,sourceFeatureVariant='pixel-boundary-full-rf-v1',sourceModelSHA256='1'*64,
                primarySourceModelSHA256='0'*64,threshold=.5,trees=[tree],completion=dict(unionNative=False,radiusFontScale=0,minimumRadiusPixels=2,maximumRadiusPixels=2,kernel='square'),
                boundaryEvidenceGate=dict(primaryThreshold=.5,boundaryThreshold=.5,includeNativeSupport=False,
                    colorCorroboration=dict(radius=1,tolerance=24,primarySeedThreshold=.5,boundarySeedThreshold=.3)))
            (root/'model').write_text(json.dumps(model));message=dict(rgb=str(root/'rgb'),primary=str(root/'p'),nativeMask=str(root/'base'),coarseRF=str(root/'coarse'),fullRF=str(root/'full'),width=5,height=5,fontPixels=8,output=str(root/'output'),probabilityOutput=str(root/'observed'))
            subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            expected=np.zeros((5,5),np.uint8);expected[1:4,1:4]=255;expected[2,3]=0
            np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8).reshape(5,5),expected)
            votes=np.zeros((5,5),np.float32);votes[2,2]=1
            np.testing.assert_array_equal(np.fromfile(root/'observed',np.float32).reshape(5,5),votes)
            model['boundaryEvidenceGate']['chromaticOverride']=dict(minimumChroma=64,primaryThreshold=.5,
                boundaryThreshold=.5,includeNativeSupport=False,colorCorroboration=dict(radius=1,tolerance=25,
                    primarySeedThreshold=.5,boundarySeedThreshold=.3))
            (root/'model').write_text(json.dumps(model))
            subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            alternate=expected.copy();alternate[2,3]=255
            np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8).reshape(5,5),alternate)
            del model['boundaryEvidenceGate']['chromaticOverride'];(root/'model').write_text(json.dumps(model))
            message.update(boundaryProbabilities=str(root/'observed'),coarseRF='/unreadable/coarse',fullRF='/unreadable/full')
            cached=subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            self.assertTrue(json.loads(cached.stdout)['boundaryObservationReused'])
            np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8).reshape(5,5),expected)
            votes[0,0]=np.nan;votes.tofile(root/'observed')
            invalid=subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True)
            self.assertNotEqual(invalid.returncode,0)
            model['boundaryEvidenceGate']['colorCorroboration']['radius']=4
            (root/'model').write_text(json.dumps(model));rejected=subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True)
            self.assertNotEqual(rejected.returncode,0)

    def test_boundary_rf_histograms_match_explicit_pixel_decisions(self):
        rng=np.random.default_rng(193)
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);shape=(13,19)
            pv=rng.integers(0,65,shape);qv=rng.integers(0,49,shape)
            pv[:4,:]=rng.integers(0,8,(4,19));qv[:4,:]=rng.integers(0,8,(4,19))
            p=pv.astype(np.float32)/64;q=qv.astype(np.float32)/48
            support=rng.choice(boundary_rf_gate.RF_BINS[:-1],shape)
            mask=rng.random(shape)>.25;target=rng.random(shape)>.5
            (root/'full-rf-dev-probabilities').mkdir();(root/'python-research-all').mkdir();(root/'native-masks').mkdir()
            np.savez(root/'full-rf-dev-probabilities/a.npz',probability=q.astype(np.float16))
            (mask.astype(np.uint8)*255).tofile(root/'python-research-all/a.u8')
            (mask.astype(np.uint8)*255).tofile(root/'native-masks/a.u8')
            Image.fromarray(target.astype(np.uint8)*255).save(root/'gt.png')
            row=dict(id='a',width=shape[1],height=shape[0],split='train',target=str(root/'gt.png'),targetSHA256=sha(root/'gt.png'))
            receipt={'contract':{'observation':{}}}
            for module in [boundary_rf_gate,boundary_rf_rescue]:
                with patch.object(module,'read',return_value=receipt),patch.object(module,'load_classifier_observation',return_value=(p,np.zeros(shape,np.uint8))),patch.object(module,'owner_text_sfx_support',side_effect=lambda row,base,pos:support.ravel()[pos]):
                    if module is boundary_rf_gate:
                        _,counts,h=module.measure((row,root,root,root,root))
                    else:
                        _,counts,h=module.measure((row,root,root,root,root,root,'rf'))
                for a,b in [(1,1),(2,3),(8,8)]:
                    for k in [0,1,5,10,14]:
                        threshold=boundary_rf_gate.RF_BINS[k]
                        if module is boundary_rf_gate:
                            tp,fp=h[:,:a,:b,:k].sum(axis=(1,2,3))
                            actual=counts+[-tp,-fp,tp]
                            explicit=mask&((pv>=a)|(qv>=b)|(support>=threshold))
                        else:
                            tp,fp=h[:,a:,b:,k:].sum(axis=(1,2,3))
                            actual=counts+[tp,fp,-tp]
                            explicit=mask|((pv>=a)&(qv>=b)&(support>=threshold))
                        expected=[np.count_nonzero(explicit&target),np.count_nonzero(explicit&~target),np.count_nonzero(~explicit&target)]
                        np.testing.assert_array_equal(actual,expected)

    def test_hard_sampling_retains_source_features_and_samples_both_classes(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch)
            target=np.zeros((40,40),np.uint8);target[:20]=255
            Image.fromarray(target).save(root/'target.png')
            features=np.arange(1600,dtype=np.float32)[:,None]
            probability=np.full((40,40),.11,np.float32)
            row=dict(id='a',split='train',target=str(root/'target.png'),rgb='source',rf='rf',
                width=40,height=40,polygons=[],fontPixels=12)
            calls=[]
            def source(inputs,*args):
                calls.append(inputs)
                return features,['sourceIndex'],probability
            payload=(row,root,root,0,root,True)
            with patch('boundary_refiner.source_features',side_effect=source):
                ordinary,ordinary_y,_=sample_case(payload)
                hard,y,_=sample_hard_case((*payload,128))
                renamed=dict(row,id='unrelated-identity',status='ignored')
                again,again_y,_=sample_hard_case((renamed,*payload[1:],128))
            self.assertGreater(np.count_nonzero(y==1),np.count_nonzero(ordinary_y==1))
            self.assertGreater(np.count_nonzero(y==0),np.count_nonzero(ordinary_y==0))
            np.testing.assert_array_equal(y,target.ravel()[hard[:,0].astype(int)]>0)
            np.testing.assert_array_equal(hard,again)
            np.testing.assert_array_equal(y,again_y)
            self.assertTrue(all('target' not in c and 'split' not in c and 'status' not in c for c in calls))

    @unittest.skipUnless(os.environ.get('SEGMENTATION_BOUNDARY_BINARY'),'Set native contextual boundary replay')
    def test_contextual_features_match_opencv_at_tiny_crops_and_large_windows(self):
        rng=np.random.default_rng(71)
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch)
            for h,w,font in [(1,1,241),(2,7,19),(17,19,64)]:
                rgb=rng.integers(0,256,(h,w,3),dtype=np.uint8);rgb.tofile(root/'rgb')
                p=rng.integers(0,65,(h,w)).astype(np.float32)/64;p.tofile(root/'p')
                base=(rng.random((h,w))>.5).astype(np.uint8);base.tofile(root/'base')
                coarse=rng.integers(0,256,(h,w,4),dtype=np.uint8)
                np.savez(root/'rf.npz',support=coarse);(coarse.astype(np.float32)/255).tofile(root/'coarse')
                full=rng.random((h,w,27)).astype(np.float16).astype(np.float32);full.tofile(root/'full')
                row=dict(id='synthetic',rgb=str(root/'rgb'),rf=str(root/'rf.npz'),width=w,height=h,polygons=[],fontPixels=font)
                with patch('boundary_refiner._PRIMARY',('model',64,'binary')),patch('boundary_refiner.observation_contract',return_value={}),patch('boundary_refiner.load_classifier_observation',return_value=(p,base)),patch('boundary_refiner.load_case_features',return_value=full):
                    expected,_,_=source_features(row,root,root,rich=True)
                message=dict(rgb=str(root/'rgb'),primary=str(root/'p'),nativeMask=str(root/'base'),
                    coarseRF=str(root/'coarse'),fullRF=str(root/'full'),width=w,height=h,fontPixels=font,output=str(root/'features'))
                subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],'--features'],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                actual=np.fromfile(root/'features',np.float32).reshape(-1,55)
                np.testing.assert_allclose(actual,expected,rtol=0,atol=1e-6)
                subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],'--edge-context-features'],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                actual=np.fromfile(root/'features',np.float32).reshape(-1,60)
                expected=np.concatenate([expected,edge_features(rgb,font)],axis=1)
                np.testing.assert_allclose(actual,expected,rtol=0,atol=1e-6)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_BOUNDARY_BINARY'),'Set native contextual boundary replay')
    def test_edge_model_dispatches60_features_and_requires_primary_pair(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch)
            for name,data in [('rgb',np.zeros((5,7,3),np.uint8)),('p',np.zeros((5,7),np.float32)),
                              ('base',np.zeros((5,7),np.uint8)),('coarse',np.zeros((5,7,4),np.float32)),('full',np.zeros((5,7,27),np.float32))]:data.tofile(root/name)
            tree=[dict(feature=55,threshold=.5,left=1,right=2,positive=-1),dict(feature=-1,threshold=0,left=-1,right=-1,positive=0),dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]
            model=dict(schema=1,featureCount=60,sourceFeatureVariant='pixel-boundary-rgb-edges-rf-v2',sourceModelSHA256='1'*64,primarySourceModelSHA256='0'*64,threshold=.5,trees=[tree])
            (root/'model').write_text(json.dumps(model));message=dict(rgb=str(root/'rgb'),primary=str(root/'p'),nativeMask=str(root/'base'),coarseRF=str(root/'coarse'),fullRF=str(root/'full'),width=7,height=5,fontPixels=12,output=str(root/'output'))
            command=[os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')]
            subprocess.run(command,input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            self.assertTrue(np.all(np.fromfile(root/'output',np.uint8)==255))
            del model['primarySourceModelSHA256'];(root/'model').write_text(json.dumps(model))
            invalid=subprocess.run(command,input=json.dumps(message)+'\n',capture_output=True,text=True)
            self.assertNotEqual(invalid.returncode,0)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_BOUNDARY_BINARY'),'Set native contextual boundary replay')
    def test_expansion_gate_keeps_pixels_supported_by_either_classifier(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);rgb=np.zeros((8,8,3),np.uint8);rgb[:,:4,0]=255;rgb.tofile(root/'rgb')
            p=np.zeros((8,8),np.float32);p[:,4]=.125;p.tofile(root/'p')
            np.zeros((8,8),np.uint8).tofile(root/'base');np.zeros((8,8,4),np.float32).tofile(root/'coarse')
            np.zeros((8,8,27),np.float32).tofile(root/'full')
            tree=[dict(feature=2,threshold=.5,left=1,right=2,positive=-1),
                dict(feature=-1,threshold=0,left=-1,right=-1,positive=0),dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]
            model=dict(schema=1,featureCount=55,sourceFeatureVariant='pixel-boundary-full-rf-v1',sourceModelSHA256='1'*64,
                primarySourceModelSHA256='0'*64,threshold=.5,trees=[tree],
                completion=dict(unionNative=False,radiusFontScale=0,minimumRadiusPixels=2,maximumRadiusPixels=2,kernel='square'))
            (root/'model').write_text(json.dumps(model))
            message=dict(rgb=str(root/'rgb'),primary=str(root/'p'),nativeMask=str(root/'base'),coarseRF=str(root/'coarse'),
                fullRF=str(root/'full'),width=8,height=8,fontPixels=8,output=str(root/'output'))
            for gate,width in [(False,6),(True,5)]:
                message['constrainExpansion']=gate
                subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                expected=np.zeros((8,8),np.uint8);expected[:,:width]=255
                np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8).reshape(8,8),expected)
            base=np.zeros((8,8),np.uint8);base[:,5]=255;base.tofile(root/'base')
            message['constrainExpansion']=True
            for include_native in [False,True]:
                model['boundaryEvidenceGate']=dict(primaryThreshold=.25,boundaryThreshold=.5,includeNativeSupport=include_native)
                (root/'model').write_text(json.dumps(model))
                subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                expected=np.zeros((8,8),np.uint8);expected[:,:4]=255
                if include_native:expected[:,5]=255
                np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8).reshape(8,8),expected)
            model['boundaryEvidenceGate']['primaryThreshold']=-.1
            (root/'model').write_text(json.dumps(model))
            rejected=subprocess.run([os.environ['SEGMENTATION_BOUNDARY_BINARY'],str(root/'model')],input=json.dumps(message)+'\n',capture_output=True,text=True)
            self.assertNotEqual(rejected.returncode,0)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_RF_RESCUE_BINARY'),'Set native RF rescue replay')
    def test_native_rf_rescue_requires_both_independent_signals(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch)
            (root/'policy').write_text(json.dumps(dict(probabilityThreshold=.1171875,supportThreshold=.15)))
            np.array([255,0,0,0,0,0],np.uint8).tofile(root/'mask')
            np.array([0,.125,.125,.1,.25,1],np.float32).tofile(root/'p')
            np.array([0,.2,.1,.9,.5,.2],np.float32).tofile(root/'rf')
            message=dict(mask=str(root/'mask'),probabilities=str(root/'p'),support=str(root/'rf'),
                width=3,height=2,output=str(root/'output'))
            command=[os.environ['SEGMENTATION_RF_RESCUE_BINARY'],str(root/'policy')]
            result=subprocess.run(command,input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            np.testing.assert_array_equal(np.fromfile(root/'output',np.uint8),[255,255,0,0,255,255])
            self.assertEqual(json.loads(result.stdout)['added'],3)
            np.array([0,.2,np.nan,.9,.5,.2],np.float32).tofile(root/'rf')
            rejected=subprocess.run(command,input=json.dumps(message)+'\n',capture_output=True,text=True)
            self.assertNotEqual(rejected.returncode,0)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_LIVE_RESCUE_BINARY'),'Set updated live segmentation replay')
    def test_live_source_path_uses_text_and_sfx_rf_channels_without_bbox_clipping(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);np.zeros((8,8,3),np.uint8).tofile(root/'rgb')
            np.zeros((8,8,4),np.float32).tofile(root/'coarse')
            full=np.zeros((8,8,27),np.float32)
            full[:,:4,15]=.5;full[:,:4,16]=.5
            full[6:,:,17]=.7;full[6:,:,18]=.3
            full.tofile(root/'full')
            positive=[dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]
            negative=[dict(feature=-1,threshold=0,left=-1,right=-1,positive=0)]
            model=dict(schema=1,featureCount=62,threshold=12.5/64,trees=[positive]+[negative]*7,
                sourceModelSHA256='0'*64,sourceFeatureVariant='pixel-full-rf-v2',
                completion=dict(unionNative=False,radiusFontScale=0,minimumRadiusPixels=0,maximumRadiusPixels=0,weakThreshold=8.5/64))
            (root/'model').write_text(json.dumps(model))
            message=dict(rgb=str(root/'rgb'),coarseRF=str(root/'coarse'),fullRF=str(root/'full'),width=8,height=8,
                polygons=[[[2,2],[5,2],[5,5],[2,5]]],fontPixels=8,output=str(root/'plain'))
            command=[os.environ['SEGMENTATION_LIVE_RESCUE_BINARY'],str(root/'model')]
            subprocess.run(command,input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            self.assertFalse(np.fromfile(root/'plain',np.uint8).any())
            message.update(output=str(root/'rescued'),weakRescue=dict(probabilityThreshold=7.5/64,supportThreshold=.15))
            subprocess.run(command,input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
            expected=np.zeros((8,8),np.uint8);expected[:,:4]=255;expected[6:,:]=255
            np.testing.assert_array_equal(np.fromfile(root/'rescued',np.uint8).reshape(8,8),expected)

    def test_sparse_rf_sampling_matches_dense_original_coordinates(self):
        rng=np.random.default_rng(58);grid=rng.normal(size=(162,162)).astype(np.float32)
        bounds=[13,27,85,104];width,height=317,541
        dense=sample(grid,bounds,width,height)
        y,x=np.indices(dense.shape);x=x.ravel()[::13];y=y.ravel()[::13]
        actual=sample_points(grid,x+bounds[0],y+bounds[1],width,height)
        np.testing.assert_array_equal(actual,dense[y,x])

    def test_oof_keeps_duplicate_sources_out_of_their_teacher(self):
        rows=[dict(id='a1',split='train',sourceGroup='a'),dict(id='a2',split='train',sourceGroup='a'),
              dict(id='b',split='train',sourceGroup='b'),dict(id='c',split='train',sourceGroup='c'),
              dict(id='test',split='test',sourceGroup='unseen')]
        receipt=dict(foldByItem={'a1':0,'a2':0,'b':1,'c':2})
        protocol=dict(folds=[dict(fold=f,excludedGroups=[g],trainingGroups=[s for s in ['a','b','c'] if s!=g])
                             for f,g in enumerate(['a','b','c'])])
        validate_oof(dict(items=rows),receipt,protocol)
        broken=copy.deepcopy(protocol);broken['folds'][0]['trainingGroups'].append('a')
        with self.assertRaises(ValueError):validate_oof(dict(items=rows),receipt,broken)
        self.assertEqual(source_fold('same decoded pixels'),source_fold('same decoded pixels'))

    def test_context_features_do_not_read_target_or_identity(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);rgb=np.arange(5*7*3,dtype=np.uint8).reshape(5,7,3);rgb.tofile(root/'rgb')
            np.savez(root/'rf.npz',support=np.zeros((5,7,4),np.uint8))
            row=dict(id='first',rgb=str(root/'rgb'),rf=str(root/'rf.npz'),width=7,height=5,polygons=[],fontPixels=8)
            p=np.linspace(0,1,35,dtype=np.float32).reshape(5,7);native=(p>.5).astype(np.uint8)
            with patch('boundary_refiner._PRIMARY',('model',64,'binary')),patch('boundary_refiner.observation_contract',return_value={}),patch('boundary_refiner.load_classifier_observation',return_value=(p,native)):
                before,names,_=source_features(row,root,root)
                row.update(id='different',target='/unreadable/target.png',status='changed')
                after,_,_=source_features(row,root,root)
                with patch('boundary_refiner.load_case_features',return_value=np.zeros((5,7,27),np.float32)):
                    rich,rich_names,_=source_features(row,root,root,rich=True)
            self.assertEqual(before.shape,(35,22));self.assertEqual(len(names),22)
            self.assertEqual(rich.shape,(35,55));self.assertEqual(len(rich_names),55)
            self.assertTrue(np.isfinite(rich).all())
            np.testing.assert_array_equal(before,after)

    def test_classifier_identity_ignores_policy_but_binds_tree_votes(self):
        with tempfile.TemporaryDirectory() as scratch:
            path=Path(scratch)/'model.json'
            d=dict(trees=[[[0,.5,1,2,-1],[-1,0,-1,-1,0],[-1,0,-1,-1,1]]],
                featureCount=35,sourceFeatureVariant='pixel-coarse-rf-v1',sourceModelSHA256='0'*64,threshold=.5,completion=None)
            path.write_text(json.dumps(d));before=classifier_identity(path)
            d.update(threshold=.1,completion=dict(radiusFontScale=.05));path.write_text(json.dumps(d))
            self.assertEqual(before,classifier_identity(path))
            d['trees'][0][2][-1]=0;path.write_text(json.dumps(d))
            self.assertNotEqual(before,classifier_identity(path))

    def test_classifier_observations_reject_modified_inputs_and_archives(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);(root/'rgb').write_bytes(b'abcdef');(root/'rf').write_bytes(b'rf')
            row=dict(rgb=str(root/'rgb'),rf=str(root/'rf'),width=2,height=1,polygons=[[[0,0],[1,0],[1,1]]],fontPixels=4)
            contract=observation_contract(row,root,'classifier','binary',False)
            archive=root/'cache.npz'
            np.savez_compressed(archive,votes=np.array([[1,7]],np.uint8),nativeBase=np.array([[0,255]],np.uint8))
            archive.with_suffix('.json').write_text(json.dumps(dict(contract=contract,archiveSHA256=sha(archive))))
            self.assertIsNotNone(load_classifier_observation(archive,contract,64))
            (root/'rgb').write_bytes(b'changed pixels')
            changed=observation_contract(row,root,'classifier','binary',False)
            self.assertIsNone(load_classifier_observation(archive,changed,64))
            archive.write_bytes(b'corrupt')
            self.assertIsNone(load_classifier_observation(archive,contract,64))

    @unittest.skipUnless(os.environ.get('SEGMENTATION_NATIVE_BINARY'),'Set native replay for source-observation parity')
    def test_native_cached_classifier_replays_new_policy_exactly(self):
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);rgb=np.zeros((8,8,3),np.uint8);rgb[:4]=[200,20,30];rgb[4:]=[20,30,200]
            rgb.tofile(root/'rgb');np.zeros((8,8,4),np.float32).tofile(root/'rf')
            tree=[dict(feature=0,threshold=.4,left=1,right=2,positive=-1),
                  dict(feature=-1,threshold=0,left=-1,right=-1,positive=0),
                  dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]
            model=dict(schema=1,featureCount=35,threshold=.75,trees=[tree,tree],sourceModelSHA256='0'*64,
                sourceFeatureVariant='pixel-coarse-rf-v1',completion=None)
            message=dict(rgb=str(root/'rgb'),coarseRF=str(root/'rf'),fullRF=None,width=8,height=8,
                polygons=[[[1,1],[6,1],[6,6],[1,6]]],fontPixels=8)
            def run(model,message):
                (root/'model').write_text(json.dumps(model))
                result=subprocess.run([os.environ['SEGMENTATION_NATIVE_BINARY'],str(root/'model')],
                    input=json.dumps(message)+'\n',capture_output=True,text=True,check=True)
                return json.loads(result.stdout)
            outputs=[]
            for radius in [1,0]:
                model['completion']=dict(unionNative=False,radiusFontScale=0,minimumRadiusPixels=radius,
                    maximumRadiusPixels=radius,kernel='ellipse')
                fresh=dict(message,output=str(root/'fresh'),captureProbabilities=str(root/'probabilities'),captureNativeBase=str(root/'base'))
                self.assertFalse(run(model,fresh)['classifierObservationReused'])
                cached=dict(message,output=str(root/'cached'),probabilities=str(root/'probabilities'),nativeBase=str(root/'base'))
                self.assertTrue(run(model,cached)['classifierObservationReused'])
                self.assertEqual((root/'fresh').read_bytes(),(root/'cached').read_bytes())
                outputs.append((root/'fresh').read_bytes())
            self.assertNotEqual(*outputs)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_FOREST_BINARY'),'Set portable native forest replay for codec parity')
    def test_compact_and_keyed_native_tree_encodings_match_opencv(self):
        rng=np.random.default_rng(73)
        x=rng.normal(size=(96,62)).astype(np.float32);y=(x[:,0]>0).astype(np.int32)
        with tempfile.TemporaryDirectory() as scratch:
            root=Path(scratch);model=fit_forest(x,y,4,5,4,117)
            model.save(str(root/'opencv.json'))
            document=json.loads((root/'opencv.json').read_text())['opencv_ml_rtrees']
            trees=[flatten(t,62) for t in document['trees']]
            expected=model.getVotes(x,0)[1:,1].astype(np.float32)/4
            x.tofile(root/'features.f32')
            for compact,prune in [(False,False),(True,False),(False,True),(True,True)]:
                data=dict(schema=1,featureCount=62,threshold=.5,sourceModelSHA256='0'*64,
                    sourceFeatureVariant='pixel-full-rf-v2',completion=None,
                    trees=[collapse_constant_branches(t) for t in trees] if prune else trees)
                if compact:data['trees']=[[[n[k] for k in ['feature','threshold','left','right','positive']] for n in t] for t in data['trees']]
                (root/'native.json').write_text(json.dumps(data))
                subprocess.run([os.environ['SEGMENTATION_FOREST_BINARY'],str(root/'native.json'),str(root/'features.f32'),str(root/'votes.f32')],check=True,capture_output=True)
                np.testing.assert_array_equal(np.fromfile(root/'votes.f32',np.float32),expected)

    def test_connected_support_drops_isolated_weak_pixels(self):
        votes=np.zeros((5,9),np.uint8)
        votes[1,1:4]=[30,8,4];votes[3,6:8]=[4,7]
        score=component_strength(votes,4,48)
        self.assertTrue(np.all(score[1,1:4]==30))
        self.assertTrue(np.all(score[3,6:8]==7))
        self.assertEqual(score[0,0],0)

    def test_parallel_forest_merge_preserves_every_tree_vote(self):
        rng=np.random.default_rng(81)
        x=rng.normal(size=(240,8)).astype(np.float32);y=(x[:,0]+x[:,1]>0).astype(np.int32)
        with tempfile.TemporaryDirectory() as scratch:
            paths=[];models=[]
            for i in range(3):
                model=fit_forest(x,y,2,3+i,4,16+i);models.append(model)
                path=Path(scratch)/f'{i}.json';model.save(str(path));paths.append(path)
            merged=merge_forests(paths,Path(scratch)/'merged.json',allow_mixed_training=True)
            actual=merged.getVotes(x,0)
            np.testing.assert_array_equal(actual[0],models[0].getVotes(x,0)[0])
            np.testing.assert_array_equal(actual[1:],sum(m.getVotes(x,0)[1:] for m in models))

    def test_only_constant_vote_subtrees_collapse(self):
        nodes=[dict(feature=0,threshold=.5,left=1,right=2,positive=-1),
               dict(feature=-1,threshold=0,left=-1,right=-1,positive=1),
               dict(feature=-1,threshold=0,left=-1,right=-1,positive=1)]
        result=collapse_constant_branches(nodes)
        self.assertEqual(len(result),1);self.assertEqual(result[0]['positive'],1)
        nodes[2]['positive']=0
        self.assertEqual(collapse_constant_branches(nodes),nodes)

    def test_three_scale_histogram_equals_three_explicit_masks(self):
        rng=np.random.default_rng(16)
        v=rng.integers(0,49,(17,21),dtype=np.uint8);gt=rng.random(v.shape)>.5
        near=cv2.dilate(v,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(3,3)))
        far=cv2.dilate(v,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(7,7)))
        w,n,f=np.meshgrid([1,4,12,48],[1,10,24,48],[1,19,32,48])
        w,n,f=w.ravel(),n.ravel(),f.ravel()
        counts=triple_counts(v,near,far,gt,w,n,f,48)
        for i in range(len(w)):
            mask=(v>=w[i])|(near>=n[i])|(far>=f[i])
            self.assertEqual(tuple(int(c[i]) for c in counts),(np.count_nonzero(mask&gt),np.count_nonzero(mask&~gt),np.count_nonzero(~mask&gt)))

    def test_gated_histograms_equal_explicit_masks(self):
        rng=np.random.default_rng(294)
        weak,strong,fringe=np.meshgrid([1,4,12,24,48],[2,10,19,48],[0,1,3,8])
        valid=fringe<=weak
        weak,strong,fringe=weak[valid],strong[valid],fringe[valid]
        for shape in [(1,1),(2,7),(43,61)]:
            votes=rng.integers(0,49,shape,dtype=np.uint8)
            for target in [rng.random(shape)>.7,np.zeros(shape,bool),np.ones(shape,bool)]:
                for radius in [1,2,8]:
                    expanded=cv2.dilate(votes,np.ones((2*radius+1,2*radius+1),np.uint8))
                    counts=union_counts(votes,expanded,target,weak,strong,48,fringe)
                    for i in range(len(weak)):
                        mask=(votes>=weak[i])|((expanded>=strong[i])&(votes>=fringe[i]))
                        expected=(np.count_nonzero(mask&target),np.count_nonzero(mask&~target),np.count_nonzero(~mask&target))
                        self.assertEqual(tuple(int(c[i]) for c in counts),expected)

    @unittest.skipUnless(os.environ.get('SEGMENTATION_NATIVE_BINARY'),'Set compiled native replay for runtime parity')
    def test_native_matches_opencv_at_crop_edges_and_large_radii(self):
        rng=np.random.default_rng(512)
        messages=[];expected=[]
        for shape in [(1,1),(2,7),(43,61)]:
            seed=(rng.random(shape)>.85).astype(np.uint8)*255
            seed[0,0]=255
            for radius in [0,1,2,3,8,16]:
                for name,kind in [('square',cv2.MORPH_RECT),('ellipse',cv2.MORPH_ELLIPSE),('cross',cv2.MORPH_CROSS)]:
                    messages.append(dict(seed=seed.ravel().tolist(),height=shape[0],width=shape[1],radius=radius,kernel=name))
                    expected.append(cv2.dilate(seed,cv2.getStructuringElement(kind,(2*radius+1,2*radius+1))).ravel())
        result=subprocess.run([os.environ['SEGMENTATION_NATIVE_BINARY'],'--expansion-parity'],
            input=''.join(json.dumps(m)+'\n' for m in messages),capture_output=True,text=True,check=True)
        actual=result.stdout.splitlines()
        self.assertEqual(len(actual),len(expected))
        for line,wanted in zip(actual,expected):
            np.testing.assert_array_equal(json.loads(line),wanted)


if __name__=='__main__':
    unittest.main()
