import sys,unittest
from pathlib import Path
import numpy as np
from directional_background import features
class Tests(unittest.TestCase):
 def scene(self):
  rgb=np.full((40,40,3),50,np.uint8);own=np.zeros((40,40),bool);own[15:25,15:25]=True;rgb[own]=0
  arrays=dict(rf=np.zeros((40,40,27),np.float32),ocr=np.ones((40,40,8),np.float32),segPrimary=own.astype(np.float32),segBoundary=np.zeros((40,40),np.float32));arrays['rf'][:,:,15:19]=1
  return rgb,own,arrays
 def test_uniform_exterior(self):
  rgb,own,a=self.scene();x,e=features(rgb,own,own,[[50,50,50],[200,200,200]],20,a)
  self.assertTrue(e['observed']);self.assertEqual(x.shape,(2,24));self.assertEqual(x[0,4],1);self.assertEqual(x[0,9],1);self.assertEqual(x[1,4],0)
 def test_no_joint_owner_abstains(self):
  rgb,own,a=self.scene();a['rf'][:]=0;x,e=features(rgb,own,own,[[50,50,50]],20,a);self.assertFalse(e['observed']);self.assertFalse(x.any())
 def test_candidate_order_only_reorders(self):
  rgb,own,a=self.scene();x,_=features(rgb,own,own,[[50,50,50],[200,200,200]],20,a);y,_=features(rgb,own,own,[[200,200,200],[50,50,50]],20,a);np.testing.assert_array_equal(x,y[::-1])
 def test_enclosing_neighbor_censors(self):
  rgb,own,a=self.scene();context=own.copy();context[14:26,14:26]=True;x,e=features(rgb,own,context,[[50,50,50]],20,a);self.assertFalse(e['observed'])
if __name__=='__main__':unittest.main()
