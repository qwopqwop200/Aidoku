import unittest
from shadow_background_normalization import estimate,estimate_observed


class BackgroundNormalizedShadowTests(unittest.TestCase):
    def source(self):
        profiles=[];components=[]
        for identity in range(6):
            components.append(dict(sourceComponent=identity,eligible=30))
            for _ in range(8):profiles.append(dict(sourceComponent=identity,conditionalBlackAttenuation=.7))
        return profiles,components

    def test_same_attenuation_uses_source_background_without_fabricating_intrinsic_parameters(self):
        profiles,components=self.source();result=estimate(profiles,components,[250,230,200])
        self.assertTrue(result['identified']);self.assertEqual(result['rgb'],[75,69,60])
        self.assertIsNone(result['opacity']);self.assertIsNone(result['intrinsicRGB'])

    def test_different_validation_attenuation_prevents_a_shared_colour(self):
        profiles,components=self.source()
        for p in profiles:
            if p['sourceComponent']%2:p['conditionalBlackAttenuation']=.3
        self.assertFalse(estimate(profiles,components,[250,230,200])['identified'])

    def test_observed_core_is_a_native_sample_not_the_canonical_background_composite(self):
        profiles=[];components=[]
        for identity in range(6):
            components.append(dict(sourceComponent=identity,eligible=30))
            profiles.extend(dict(sourceComponent=identity,rgb=[175,161,140],conditionalBlackAttenuation=.3) for _ in range(20))
            profiles.extend(dict(sourceComponent=identity,rgb=[75,69,60],conditionalBlackAttenuation=.7) for _ in range(8))
        result=estimate_observed(profiles,components,[200,200,200])
        self.assertTrue(result['identified']);self.assertEqual(result['rgb'],[75,69,60])
        self.assertEqual(result['normalization']['rgb'],[60,60,60]);self.assertTrue(result['nativeActualSample'])


if __name__=='__main__':unittest.main()
