import unittest
import numpy as np
import forest_width_consensus as consensus


class Tree:
    n_features_in_=712
    def __init__(self,value):self.value=value
    def predict(self,x,check_input=True):return np.full(len(x),self.value)


class Forest:
    n_features_in_=712
    estimators_=[Tree(5.) for _ in range(192)]


def policy():
    return dict(version=consensus.VERSION,configuration=consensus.CONFIG,
        helperSHA256=consensus.helper_sha256(),sourceFeatureCount=712,sourceOnly=True,GTAtInference=False)


class WidthConsensusTests(unittest.TestCase):
    def test_extreme_minority_votes_do_not_move_constant_core(self):
        values=np.r_[np.full(20,-100.),np.full(152,5.),np.full(20,1000.)][:,None]
        self.assertEqual(consensus.aggregate(values).tolist(),[5.])

    def test_literal_frozen_mixture_and_tree_permutation(self):
        rng=np.random.default_rng(451);values=rng.normal(5,2,(192,9));ordered=np.sort(values,axis=0)
        expected=.5*ordered[38:-38].mean(0)+.5*np.quantile(values,.6,axis=0)
        np.testing.assert_allclose(consensus.aggregate(values),expected,rtol=0,atol=1e-14)
        np.testing.assert_array_equal(consensus.aggregate(values[::-1]),consensus.aggregate(values))

    def test_batch_invariance_and_no_input_mutation(self):
        rng=np.random.default_rng(452);values=rng.uniform(1,10,(192,8));copy=values.copy()
        full=consensus.aggregate(values);single=np.concatenate([consensus.aggregate(values[:,i:i+1]) for i in range(8)])
        np.testing.assert_array_equal(full,single);np.testing.assert_array_equal(values,copy)

    def test_policy_and_source_schema_fail_closed(self):
        model=Forest();p=policy();np.testing.assert_array_equal(consensus.predict(model,np.zeros((2,712)),p),[5.,5.])
        for key,value in [('version','unknown'),('sourceFeatureCount',711),('helperSHA256','0'*64)]:
            bad={**p,key:value}
            with self.assertRaises(ValueError):consensus.predict(model,np.zeros((2,712)),bad)
        with self.assertRaises(ValueError):consensus.predict(model,np.zeros((2,711)),p)

    def test_invalid_vote_arrays(self):
        for values in [np.zeros((2,3)),np.zeros((192,0)),np.zeros(192),np.full((192,1),np.nan)]:
            with self.assertRaises(ValueError):consensus.aggregate(values)


if __name__=='__main__':unittest.main()
