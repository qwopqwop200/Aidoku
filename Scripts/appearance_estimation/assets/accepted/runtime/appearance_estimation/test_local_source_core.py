import unittest
import numpy as np
from local_source_core import extract
from shadow_template_fit import source_core


class LocalSourceCoreTests(unittest.TestCase):
    def source(self):
        mask=np.zeros((100,170),bool)
        for x in [20,70,120]:mask[25:65,x:x+20]=True
        rgb=np.full((100,170,3),80,np.uint8);rgb[mask]=255
        prediction=dict(fill=dict(rgb=[255,255,255]),outline=dict(present=False,rgb=[0,0,0]),background=dict(rgb=[255,255,255]))
        return rgb,mask,prediction

    def test_mixed_global_background_does_not_erase_visible_local_glyphs(self):
        rgb,mask,prediction=self.source()
        self.assertIsNone(source_core(rgb,mask,prediction))
        core,evidence=extract(rgb,mask,prediction,font_pixels=40)
        np.testing.assert_array_equal(core,mask);self.assertTrue(evidence['usedLocalFallback'])

    def test_homogeneous_source_does_not_create_glyphs_from_a_removal_mask(self):
        rgb,mask,prediction=self.source();rgb[:]=255
        core,evidence=extract(rgb,mask,prediction,font_pixels=40)
        self.assertIsNone(core);self.assertFalse(evidence['usedLocalFallback'])

    def test_boxes_seed_ownership_without_clipping_native_component_extent(self):
        rgb,mask,prediction=self.source()
        polygons=[[[x+5,35],[x+15,35],[x+15,55],[x+5,55]] for x in [20,70,120]]
        core,_=extract(rgb,mask,prediction,polygons,40)
        np.testing.assert_array_equal(core,mask)

    def test_local_support_is_neither_white_specific_nor_rotation_specific(self):
        rgb,mask,prediction=self.source();colour=[230,80,150]
        rgb[mask]=colour;prediction['fill']['rgb']=colour;prediction['background']['rgb']=colour
        first,_=extract(rgb,mask,prediction,font_pixels=40)
        rotated,_=extract(np.rot90(rgb).copy(),np.rot90(mask).copy(),prediction,font_pixels=40)
        np.testing.assert_array_equal(first,mask);np.testing.assert_array_equal(rotated,np.rot90(mask))


if __name__=='__main__':unittest.main()
