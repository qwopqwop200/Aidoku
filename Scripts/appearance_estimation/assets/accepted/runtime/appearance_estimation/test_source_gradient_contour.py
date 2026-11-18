"""Gradient interiors identify a bounded contour without colour or page lookups."""
import copy
import tempfile
from pathlib import Path
import unittest
import cv2
import numpy as np
from native_gradient_contour import measure
from source_gradient_contour import refine,make_policy,validate_policy,MODEL_NAMES
from pixel_role_estimation import features
from optimize_appearance import evaluate_predictions


class KnownFillRoles:
    classes_=np.arange(4)
    def predict_proba(self,x):return np.tile([.99,.005,.005,0.],(len(x),1))


class SourceGradientContourTests(unittest.TestCase):
    def source(self,ring=True,gradient=True,mixed=False,soft=False):
        rgb=np.full((100,240,3),[235,180,205],np.uint8);body=np.zeros((100,240),np.uint8);group=[]
        for i,x in enumerate([20,75,130,185]):
            rgb[10:90,x:x+30]=255
            if ring:rgb[13:87,x+3:x+27]=[30,110,45] if mixed and i%2 else [140,95,45]
            for y in range(15,85):
                t=(y-15)/69;c=np.array([255,255,235])*(1-t)+np.array([255,220,65])*t if gradient else [255,220,65]
                rgb[y,x+5:x+25]=np.rint(c);body[y,x+5:x+25]=1
            group.append(dict(seedXY=[x+15,70]))
        if soft:
            blur=cv2.GaussianBlur(body.astype(np.float32),(0,0),3)
            shadow=np.rint(255*(1-.8*blur)).astype(np.uint8)
            exterior=body==0;rgb[exterior]=np.repeat(shadow[:,:,None],3,axis=2)[exterior]
        return rgb,[group],body

    def arguments(self,gradient=True):
        rgb,_,body=self.source(gradient=gradient);mask=np.any(rgb!=[235,180,205],axis=2)
        h,w=mask.shape;arrays=dict(rf=np.zeros((h,w,27),np.float32),segPrimary=mask.astype(np.float32),segBoundary=mask.astype(np.float32),ocr=np.ones((h,w,8),np.float32))
        arrays['rf'][:,:,15:17]=1
        geometry=dict(polygons=[],fontPixels=70)
        prediction=dict(fillIndex=0,outlineIndex=1,backgroundIndex=2,
            fill=dict(rgb=[255,220,65],colors=[[255,220,65]]),
            outline=dict(present=True,rgb=[200]*3,probability=.9,widthPx=2.7,widthRangePx=[1.5,3.9]),
            background=dict(rgb=[235,180,205],colors=[[235,180,205],[255]*3]),
            shadow=dict(present=False,rgb=None))
        _,names=features(rgb,mask,arrays['rf'],arrays['segPrimary'],arrays['segBoundary'],arrays['ocr'],geometry,prediction,[0])
        model=dict(classifier=KnownFillRoles(),probabilityThreshold=.8,featureNames=names)
        return rgb,mask,arrays,geometry,prediction,model,{}

    def test_source_native_brown_band_is_recovered_in_all_directions(self):
        rgb,groups,_=self.source();out=measure(rgb,groups,70)
        self.assertTrue(out['identified']);self.assertEqual(out['rgb'],[140,95,45])
        self.assertGreaterEqual(out['proposals'][0]['opposingComponents'],2)

    def test_light_outline_and_soft_shadow_do_not_create_dark_contour(self):
        for source in [self.source(ring=False),self.source(ring=False,soft=True)]:
            self.assertFalse(measure(source[0],source[1],70)['identified'])

    def test_conflicting_contour_hues_abstain(self):
        rgb,groups,_=self.source(mixed=True);self.assertFalse(measure(rgb,groups,70)['identified'])

    def test_runtime_only_changes_outline_rgb_and_own_evidence_and_is_idempotent(self):
        args=self.arguments();before=copy.deepcopy(args[4]);result,evidence=refine(*args)
        self.assertTrue(evidence['applied']);self.assertEqual(result['outline']['rgb'],[140,95,45])
        stripped=copy.deepcopy(result);stripped['outline']['rgb']=before['outline']['rgb'];del stripped['outline']['gradientContourCorrection']
        self.assertEqual(stripped,before)
        warm=list(args);warm[4]=result;self.assertEqual(refine(*warm)[0],result)

    def test_unknown_rf_ownership_or_solid_fill_cannot_trigger_recovery(self):
        args=list(self.arguments());args[2]['rf'][:]=0;self.assertEqual(refine(*args)[0],args[4])
        args=list(self.arguments(gradient=False));self.assertEqual(refine(*args)[0],args[4])

    def test_fp16_source_payload_and_fp32_replay_produce_identical_evidence(self):
        args=list(self.arguments());raw=args[2]['rf'].astype(np.float16);raw[:,:,15]=np.float16(.271);raw[:,:,16]=np.float16(.339)
        args[2]['rf']=raw.astype(np.float32);wide=refine(*args)
        half=list(args);half[2]={**args[2],'rf':raw}
        self.assertEqual(refine(*half),wide)

    def test_paired_policy_rejects_changed_models_or_source_implementation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for name in MODEL_NAMES:(root/name).write_bytes(name.encode())
            policy=make_policy(root);validate_policy(policy,policy['modelIdentities'])
            with self.assertRaises(ValueError):validate_policy(policy,{**policy['modelIdentities'],'model.pkl':'stale'})
            broken=copy.deepcopy(policy);broken['helperSHA256']['source_gradient_core.py']='stale'
            with self.assertRaises(ValueError):validate_policy(broken,policy['modelIdentities'])

    def test_actual_emitted_colour_is_scored_outside_original_palette(self):
        rows=[];pred=[];packets=[]
        for group in ['train','dev','test']:
            row=dict(evaluationSplit=group,fill=dict(rgb=[255]*3),outline=dict(present=True,rgb=[140,95,45]),background=dict(rgb=[255]*3),shadow=dict(present=False))
            rows.append(row);pred.append(dict(fillIndex=0,outlineIndex=0,backgroundIndex=0,fill=dict(rgb=[255]*3),outline=dict(present=True,rgb=[140,95,45]),background=dict(rgb=[255]*3),shadow=dict(present=False)))
            packets.append(dict(colors=[[200]*3]))
        report=evaluate_predictions(rows,packets,pred)
        self.assertEqual(report['dev']['outline']['within10'],1.)
        self.assertEqual(report['dev']['outline']['candidateCeilingWithin10'],0.)


if __name__=='__main__':unittest.main()
