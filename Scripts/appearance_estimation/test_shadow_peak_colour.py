import unittest
from shadow_peak_colour import estimate


class ShadowPeakColourTests(unittest.TestCase):
    def source(self):
        profiles=[];components=[]
        for identity in range(6):
            components.append(dict(sourceComponent=identity,eligible=30))
            for _ in range(20):profiles.append(dict(sourceComponent=identity,rgb=[130,125,125]))
            for _ in range(4):profiles.append(dict(sourceComponent=identity,rgb=[80,74,75]))
        return profiles,components

    def test_repeated_dark_paint_is_not_replaced_by_the_brighter_penumbra_median(self):
        profiles,components=self.source();result=estimate(profiles,components)
        self.assertTrue(result['identified']);self.assertEqual(result['observedRGB'],[80,74,75])
        self.assertIsNone(result['intrinsicRGB'])

    def test_dark_contaminant_on_one_component_cannot_define_a_shared_shadow_colour(self):
        profiles,components=self.source()
        for p in profiles:
            if p['sourceComponent']==0:p['rgb']=[0,0,0]
        result=estimate(profiles,components);self.assertFalse(result['identified'])

    def test_different_validation_paint_cannot_be_selected_using_fit_colour(self):
        profiles,components=self.source()
        for p in profiles:
            if p['sourceComponent']%2 and p['rgb']==[80,74,75]:p['rgb']=[30,40,100]
        self.assertFalse(estimate(profiles,components)['identified'])

    def test_repeated_colour_on_one_fit_and_one_distinct_validation_component_is_observable(self):
        profiles=[]
        for identity in [0,1]:
            profiles.extend(dict(sourceComponent=identity,rgb=[80,74,75]) for _ in range(16))
            profiles.extend(dict(sourceComponent=identity,rgb=[130,125,125]) for _ in range(80))
        result=estimate(profiles,[dict(sourceComponent=i,eligible=100) for i in [0,1]])
        self.assertTrue(result['identified']);self.assertEqual(result['observedRGB'],[80,74,75])
        with self.assertRaises(ValueError):estimate(profiles,[dict(sourceComponent=0,eligible=100)]*2)


if __name__=='__main__':unittest.main()
