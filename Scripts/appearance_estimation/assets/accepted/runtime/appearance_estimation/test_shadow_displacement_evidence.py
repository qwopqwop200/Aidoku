import unittest
import numpy as np
import cv2
from shadow_displacement_evidence import estimate,shifted


class ComponentDisplacementTests(unittest.TestCase):
    def source(self,halo=False):
        core=np.zeros((100,170),np.uint8)
        for x in [20,70,120]:core[25:65,x:x+20]=1
        fringe=cv2.dilate(core,np.ones((11,11),np.uint8)) if halo else shifted(core,5,5)
        rgb=np.full((100,170,3),255,np.uint8);rgb[fringe>0]=160;rgb[core>0]=0
        return rgb,(fringe|core)>0

    def prediction(self):
        return dict(fill=dict(rgb=[0,0,0]),outline=dict(present=False,rgb=[255,255,255],widthPx=0),background=dict(rgb=[255,255,255]))

    def test_displacement_selected_on_some_components_repeats_on_the_others(self):
        rgb,mask=self.source();result=estimate(rgb,mask,self.prediction(),40,[160,160,160])
        self.assertTrue(result['identified']);self.assertEqual(result['offsetPx'],[5,5])
        self.assertEqual(result['validationComponents'],1);self.assertAlmostEqual(result['sourceValidationF1'],1.)

    def test_symmetric_colour_border_cannot_win_against_its_opposite_control(self):
        rgb,mask=self.source(halo=True);result=estimate(rgb,mask,self.prediction(),40,[160,160,160])
        self.assertFalse(result['identified']);self.assertIsNone(result['offsetPx'])

    def test_unobserved_exterior_cannot_be_used_as_negative_shadow_evidence(self):
        core=np.zeros((150,70),np.uint8)
        for y in [20,65,110]:core[y:y+20,0:20]=1
        fringe=shifted(core,5,5);rgb=np.full((150,70,3),255,np.uint8)
        rgb[fringe>0]=160;rgb[core>0]=0
        result=estimate(rgb,(fringe|core)>0,self.prediction(),40,[160,160,160])
        self.assertFalse(result['identified']);self.assertEqual(result['censoredComponents'],3)

    def test_shift_never_wraps_pixels_from_the_opposite_crop_edge(self):
        source=np.zeros((5,5),bool);source[2,4]=True
        self.assertFalse(shifted(source,1,0).any())


if __name__=='__main__':unittest.main()
