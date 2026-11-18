import unittest
import numpy as np
from native_colour_neighborhoods import clusters,dominant_neighborhood


class NativeColourNeighborhoodTests(unittest.TestCase):
    def test_nearby_shades_across_cube_boundary_remain_one_observed_paint(self):
        pixels=np.array([[126,126,126]]*20+[[129,129,129]]*20,np.uint8)
        for shift in [0,1]:
            observed=pixels+shift;result=clusters(observed,np.ones(40))
            self.assertEqual(len(result),1);self.assertEqual(result[0]['samples'],40)
            self.assertTrue(any(np.array_equal(result[0]['rgb'],p) for p in observed))

    def test_disjoint_colours_keep_independent_native_support(self):
        pixels=np.array([[230,20,30]]*20+[[30,40,220]]*20,np.uint8)
        result=clusters(pixels,np.ones(40));self.assertEqual(len(result),2)
        self.assertEqual(sum(r['samples'] for r in result),40)

    def test_invalid_or_empty_native_support_does_not_create_colour(self):
        self.assertEqual(clusters([],[]),[])
        with self.assertRaises(ValueError):clusters([[1,2,3]],[float('nan')])

    def test_ambiguous_palette_does_not_create_a_new_source_hypothesis(self):
        first=dict(rgb=[100,100,100],observedMass=.45);second=dict(rgb=[180,180,180],observedMass=.4)
        self.assertIsNone(dominant_neighborhood([first,second]))
        self.assertEqual(dominant_neighborhood([dict(first,observedMass=.6),dict(second,observedMass=.2)])['rgb'],first['rgb'])


if __name__=='__main__':unittest.main()
