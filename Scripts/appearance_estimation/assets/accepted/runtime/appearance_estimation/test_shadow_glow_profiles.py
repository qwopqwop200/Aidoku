import unittest
import numpy as np
import cv2
from scipy.ndimage import distance_transform_edt
from shadow_glow_profiles import estimate,POLICIES,_sector


class NativeGlowTests(unittest.TestCase):
    def source(self,kind='glow'):
        core=np.zeros((210,360),np.uint8)
        for x in [50,130,210,290]:core[85:125,x:x+16]=1
        distance=distance_transform_edt(~core.astype(bool))
        shade=np.exp(-distance/4)*.4
        if kind=='AA':shade=(distance<=1)*.4
        if kind=='crisp':shade=(distance<=5)*.4
        if kind=='none':shade[:]=0
        if kind=='background':shade=.4*(np.sin(np.indices(core.shape)[1]/4)+1)/2
        rgb=np.repeat(np.rint(255*(1-shade))[:,:,None],3,axis=2).astype(np.uint8);rgb[core>0]=0
        pred=dict(fill=dict(rgb=[0,0,0]),outline=dict(present=False,rgb=[255,255,255],widthPx=0),background=dict(rgb=[255,255,255]))
        return rgb,core>0,pred

    def test_symmetric_diffuse_glow_needs_no_displacement_or_colour_bin(self):
        rgb,mask,pred=self.source();e=estimate(rgb,mask,pred,40)
        self.assertTrue(e['identified'],e);self.assertIsNotNone(e['observedRGB']);self.assertIsNone(e['offsetPx']);self.assertIsNone(e['blurRadiusPx']);self.assertIsNone(e['opacity'])

    def test_AA_crisp_ring_and_no_shadow_do_not_become_glow(self):
        for kind in ['AA','crisp','none']:
            rgb,mask,pred=self.source(kind)
            for p in POLICIES:
                with self.subTest(kind=kind,policy=p['name']):self.assertFalse(estimate(rgb,mask,pred,40,policy=p)['identified'])

    def test_background_texture_does_not_pass_external_control(self):
        rgb,mask,pred=self.source('background');self.assertFalse(estimate(rgb,mask,pred,40)['identified'])

    def test_crop_clipping_is_censored(self):
        rgb,mask,pred=self.source();e=estimate(rgb[80:130],mask[80:130],pred,40)
        self.assertFalse(e['identified']);self.assertGreater(e['censoredProfiles'],0)

    def test_raw_detector_does_not_force_main_shadow_presence(self):
        rgb,mask,pred=self.source();pred['shadow']=dict(present=False,rgb=None,offsetPx=None)
        before=repr(pred);e=estimate(rgb,mask,pred,40)
        self.assertTrue(e['identified']);self.assertEqual(repr(pred),before)

    def test_invalid_policy_rejected(self):
        rgb,mask,pred=self.source()
        with self.assertRaises(ValueError):estimate(rgb,mask,pred,40,policy={})

    def test_circular_sector_endpoint_wraps_to_zero_not_three(self):
        a=np.float32(-np.pi/4)
        for angle in [a,np.nextafter(a,np.float32(-np.inf)),np.nextafter(a,np.float32(np.inf))]:
            self.assertIn(_sector(np.cos(angle),np.sin(angle)),[0,3])
        self.assertEqual(_sector(np.float32(1),np.float32(0)),0)
        self.assertEqual(_sector(np.float32(0),np.float32(1)),1)
        self.assertEqual(_sector(np.float32(-1),np.float32(0)),2)
        self.assertEqual(_sector(np.float32(0),np.float32(-1)),3)
        for angle in np.linspace(-np.pi,np.pi,1001,dtype=np.float32):
            self.assertIn(_sector(np.cos(angle),np.sin(angle)),range(4))


if __name__=='__main__':unittest.main()
