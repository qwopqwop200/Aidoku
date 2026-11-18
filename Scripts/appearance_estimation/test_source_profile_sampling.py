import unittest
import numpy as np
from source_profile_sampling import sample_source,observed_window


class SourceProfileSamplingTests(unittest.TestCase):
    def test_padding_is_not_observed_dark_paint(self):
        rgb=np.full((8,9,3),255,np.uint8)
        x=np.array([[-1,-.1,0,4,8,8.1,9]],np.float32);y=np.full_like(x,3)
        pixels,valid=sample_source(rgb,x,y)
        self.assertEqual(valid.tolist(),[[False,False,True,True,True,False,False]])
        self.assertTrue((pixels==255).all())
        self.assertFalse(observed_window(valid,0,2))
        self.assertFalse(observed_window(valid,0,4))

    def test_boundary_contrast_requires_both_observed_sides(self):
        valid=np.ones((1,7),bool);self.assertTrue(observed_window(valid,0,3))
        valid[0,5]=False;self.assertFalse(observed_window(valid,0,3))
        self.assertFalse(observed_window(valid,0,0))
        self.assertFalse(observed_window(valid,0,6))

    def test_invalid_coordinates_never_become_samples(self):
        x=np.array([[np.nan,np.inf,-np.inf]],np.float32);y=np.zeros_like(x)
        _,valid=sample_source(np.ones((3,3,3),np.uint8),x,y)
        self.assertFalse(valid.any())


if __name__=='__main__':unittest.main()
