import unittest
from continuous_optimize import improves_quality


class PrimaryTiebreakTests(unittest.TestCase):
    def q(self, mean):
        return {g:dict(n=10,within10=1.,meanDeltaE=mean) for g in ('train','dev')}

    def test_equal_score_and_background_admit_actual_primary_mean_gain(self):
        bg=self.q(2.)
        self.assertTrue(improves_quality(.9,.9,bg,bg,self.q(.6),self.q(.7)))

    def test_mean_gain_cannot_override_lower_composite_score(self):
        bg=self.q(2.)
        self.assertFalse(improves_quality(.89,.9,bg,bg,self.q(.6),self.q(.7)))

    def test_mean_gain_cannot_override_background_regression(self):
        self.assertFalse(improves_quality(.9,.9,self.q(2.1),self.q(2.),self.q(.6),self.q(.7)))

    def test_missing_primary_or_no_improvement_does_not_accept_tie(self):
        bg=self.q(2.)
        self.assertFalse(improves_quality(.9,.9,bg,bg))
        self.assertFalse(improves_quality(.9,.9,bg,bg,self.q(.7),self.q(.7)))

    def test_training_mean_regression_blocks_tiebreak(self):
        bg=self.q(2.);old=self.q(.7);new=self.q(.6);new['train']['meanDeltaE']=.8
        self.assertFalse(improves_quality(.9,.9,bg,bg,new,old))


if __name__=='__main__':unittest.main()
