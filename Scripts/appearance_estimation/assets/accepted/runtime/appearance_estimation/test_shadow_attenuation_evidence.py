import unittest
import cv2
import numpy as np
from shadow_attenuation_evidence import estimate,POLICIES


def shift(a,dx,dy):
    out=np.zeros_like(a);h,w=a.shape;y0,y1=max(0,dy),min(h,h+dy);x0,x1=max(0,dx),min(w,w+dx)
    if y1>y0 and x1>x0:out[y0:y1,x0:x1]=a[y0-dy:y1-dy,x0-dx:x1-dx]
    return out


class SourceAttenuationTests(unittest.TestCase):
    def source(self,kind='shift'):
        core=np.zeros((180,300),np.uint8)
        for x in [40,100,160,220]:core[60:110,x:x+18]=1
        if kind=='halo':shade=cv2.dilate(core,np.ones((11,11),np.uint8)).astype(float)
        elif kind=='reverse-validation':
            shade=shift(core,5,3).astype(float)
            for x in [100,220]:
                shade[:,x-12:x+35]=shift(core,-5,-3)[:,x-12:x+35]
        else:shade=shift(core,5,3).astype(float)
        if kind=='blur':shade=cv2.GaussianBlur(shade,(7,7),1)
        rgb=np.rint(255*(1-.3*shade[:,:,None])*np.ones((1,1,3))).astype(np.uint8);rgb[core>0]=0
        return rgb,core>0

    def prediction(self):return dict(fill=dict(rgb=[0,0,0]),outline=dict(present=False,rgb=[255,255,255],widthPx=0),background=dict(rgb=[255,255,255]))

    def test_component_fit_recovers_offset_without_any_colour_candidate(self):
        rgb,mask=self.source();r=estimate(rgb,mask,self.prediction(),40)
        self.assertTrue(r['identified'],r);self.assertEqual(r['offsetPx'],[5,3]);self.assertEqual(r['validationComponents'],2)
        self.assertIsNone(r['intrinsicRGB']);self.assertIsNone(r['opacity']);self.assertIsNone(r['blurRadiusPx'])

    def test_blur_is_nuisance_not_reported_intrinsic_parameter(self):
        rgb,mask=self.source('blur');r=estimate(rgb,mask,self.prediction(),40)
        self.assertTrue(r['identified'],r);self.assertEqual(r['offsetPx'],[5,3]);self.assertIsNone(r['blurRadiusPx'])

    def test_symmetric_halo_abstains_for_every_frozen_policy(self):
        rgb,mask=self.source('halo')
        for p in POLICIES:
            with self.subTest(policy=p['name']):self.assertFalse(estimate(rgb,mask,self.prediction(),40,policy=p)['identified'])

    def test_direction_that_does_not_repeat_on_independent_components_abstains(self):
        rgb,mask=self.source('reverse-validation');self.assertFalse(estimate(rgb,mask,self.prediction(),40)['identified'])

    def test_crop_exterior_is_censored_not_synthesized(self):
        rgb,mask=self.source();rgb=rgb[55:115];mask=mask[55:115];r=estimate(rgb,mask,self.prediction(),40)
        self.assertFalse(r['identified']);self.assertEqual(r['censoredComponents'],4)

    def test_unknown_policy_and_invalid_geometry_rejected(self):
        rgb,mask=self.source()
        with self.assertRaises(ValueError):estimate(rgb,mask,self.prediction(),float('nan'))
        with self.assertRaises(ValueError):estimate(rgb,mask,self.prediction(),40,policy={})


if __name__=='__main__':unittest.main()
