import unittest
import cv2
import numpy as np
from outline_layer_discovery import correct_primary,measure,refresh_conditioned_background
from test_outline_layers import render


class ContextualRanker:
    def predict_proba(self,x):
        values=x[:,-1].astype(float)
        return np.column_stack([1-values,values])


class PrimaryContourTests(unittest.TestCase):
    def test_background_context_uses_corrected_outline_candidate(self):
        packet=dict(colors=[[10,10,10],[240,240,240],[140,80,40]],features=np.zeros((3,2)).tolist(),pair=np.zeros((3,3,6)).tolist())
        old=dict(fillIndex=0,outlineIndex=1,backgroundIndex=1,background=dict(rgb=packet['colors'][1]))
        corrected=dict(fillIndex=0,outlineIndex=2,backgroundIndex=1,background=dict(rgb=packet['colors'][1]))
        model=dict(conditionedBackground=True,background=ContextualRanker())
        result=refresh_conditioned_background(corrected,old,packet,model)
        self.assertEqual(result['backgroundIndex'],2)
        self.assertEqual(result['background']['rgb'],packet['colors'][2])
        self.assertEqual(old['backgroundIndex'],1)

    def test_inner_brown_ring_precedes_white_halo(self):
        core=np.zeros((150,300),np.uint8)
        cv2.putText(core,'ABC',(15,105),cv2.FONT_HERSHEY_SIMPLEX,2.7,1,9,cv2.LINE_8)
        first=cv2.dilate(core,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(5,5)))
        second=cv2.dilate(first,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(5,5)))
        fill=[255,230,140];brown=[145,90,45];white=[253,251,250];pink=[230,180,210]
        rgb=np.full((150,300,3),pink,np.uint8);rgb[second>0]=white;rgb[first>0]=brown;rgb[core>0]=fill
        pred=dict(fill=dict(rgb=fill),outline=dict(rgb=white,present=True),outlineIndex=1,background=dict(rgb=pink))
        packet=dict(colors=[fill,white,brown,pink],fontPixels=90)
        before=rgb.copy();result=correct_primary(rgb,second>0,pred,packet)
        self.assertEqual(result['outline']['rgb'],brown)
        self.assertEqual(result['outlineIndex'],2)
        self.assertEqual(result['outline']['rankerRGB'],white)
        self.assertEqual(pred['outline']['rgb'],white)
        np.testing.assert_array_equal(before,rgb)

    def test_primary_only_path_matches_full_profile_extraction(self):
        rgb,mask,p,colors=render();packet=dict(colors=colors,fontPixels=90)
        full=measure(rgb,mask,p,90,colors);fast=measure(rgb,mask,p,90,colors,primary_only=True)
        self.assertEqual(full.get('primaryContourProposal'),fast.get('primaryContourProposal'))
        self.assertEqual(full['eligibleProfiles'],fast['eligibleProfiles'])

    def test_known_white_then_blue_order_is_preserved(self):
        rgb,mask,p,colors=render();p['outlineIndex']=1
        result=correct_primary(rgb,mask,p,dict(colors=colors,fontPixels=90))
        self.assertEqual(result['outline']['rgb'],p['outline']['rgb'])
        self.assertNotIn('colorDecision',result['outline'])


if __name__=='__main__':unittest.main()
