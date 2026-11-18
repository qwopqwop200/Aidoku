import unittest
import numpy as np
import cv2
from shadow_direction_evidence import measure


class RepeatedShadowDirectionTests(unittest.TestCase):
    def source(self,halo=False):
        core=np.zeros((100,170),np.uint8)
        for x in [20,70,120]:core[25:65,x:x+20]=1
        fringe=cv2.dilate(core,np.ones((9,9),np.uint8)) if halo else cv2.warpAffine(core,np.float32([[1,0,5],[0,1,5]]),(170,100))
        rgb=np.full((100,170,3),255,np.uint8);rgb[fringe>0]=160;rgb[core>0]=0
        return rgb,(fringe|core)>0

    def prediction(self):
        return dict(fill=dict(rgb=[0,0,0]),outline=dict(present=False,rgb=[255,255,255],widthPx=0),
            background=dict(rgb=[255,255,255]))

    def test_repeated_displacement_survives_rotation_without_claiming_magnitude(self):
        rgb,mask=self.source();prediction=self.prediction()
        first=measure(rgb,mask,prediction,40,[160,160,160])
        turned=measure(np.rot90(rgb).copy(),np.rot90(mask).copy(),prediction,40,[160,160,160])
        self.assertTrue(first['identified']);self.assertTrue(turned['identified'])
        np.testing.assert_allclose(turned['directionUnitXY'],[first['directionUnitXY'][1],-first['directionUnitXY'][0]],atol=.03)
        self.assertIsNone(first['offsetPx']);self.assertIsNone(first['intrinsicRGB'])

    def test_symmetric_background_halo_does_not_become_directional_shadow(self):
        rgb,mask=self.source(halo=True)
        result=measure(rgb,mask,self.prediction(),40,[160,160,160])
        self.assertFalse(result['identified'])

    def test_disjoint_observed_fill_colours_share_one_native_ownership_union(self):
        rgb,mask=self.source();rgb[25:65,120:140]=[220,20,30]
        prediction=self.prediction()
        without=measure(rgb,mask,prediction,40,[160,160,160])
        prediction['fill']['colors']=[[0,0,0],[220,20,30],[220,20,30]]
        combined=measure(rgb,mask,prediction,40,[160,160,160])
        self.assertFalse(without['identified']);self.assertTrue(combined['identified'])
        self.assertEqual(combined['observedFillHypotheses'],2)
        self.assertEqual(prediction['fill']['rgb'],[0,0,0])


if __name__=='__main__':unittest.main()
