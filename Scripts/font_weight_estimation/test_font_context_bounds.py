import unittest
from unittest.mock import patch

import numpy as np
from font_context_bounds import refine_page


class ConstantProbability:
    def __init__(self,probability):self.probability=probability
    def predict_proba(self,x):return np.tile([1-self.probability,self.probability],(len(x),1))


class CorroboratedConfidenceTests(unittest.TestCase):
    def fixture(self):
        bundle=dict(sourceBandHeads=True,primary=dict(primary=dict(threshold=.5),
            polarity=dict(model=ConstantProbability(.9),featureCount=2790)),
            stem=dict(model=ConstantProbability(.8),rawFeatureCount=978,featureCount=2934,threshold=.5),
            referencePairs=[],referenceInkPairs=[])
        packet=dict(rgb=np.zeros((8,8,3),np.uint8),bbox=[0,0,8,8],ownership=np.ones((8,8),bool),style={},text='a')
        observed=dict(raw=np.zeros((1,866)),fill71=np.zeros((1,71)),bands=np.zeros((1,112)))
        prior=dict(sourceWeight='regular',renderBold=False,boldScore=.1,polarityRescueScore=.1,
                   stemRescueScore=.1,addedStemConfirmed=False)
        return bundle,[packet],np.array([20.]),dict(angles131=np.zeros(1)),observed,[prior]

    def test_high_sampled_confidence_without_pixel_proof_cannot_promote(self):
        values=self.fixture()
        with patch('font_context_bounds.measure_fill',return_value=np.zeros(71)):
            result=refine_page(*values)
        self.assertEqual(result[0]['sourceWeight'],'regular')
        self.assertEqual(result[0]['polarityRescueScore'],.1)
        self.assertFalse(result[0]['renderBold'])

    def test_sampled_stem_confidence_requires_central_band_proof(self):
        values=self.fixture();values[-1][0]['addedStemConfirmed']=True
        with patch('font_context_bounds.measure_fill',return_value=np.zeros(71)), \
                patch('weight_bands.measure',return_value=np.zeros(112)):
            result=refine_page(*values)
        self.assertEqual(result[0]['sourceWeight'],'bold')
        self.assertTrue(result[0]['sourceEmStemBoundRescueApplied'])
        self.assertEqual(values[-1][0]['sourceWeight'],'regular')

    def test_reference_proof_receives_envelope_but_published_score_remains_nominal(self):
        values=self.fixture();values[0]['referenceInkPolicy']=dict(existingScoreField='polarityRescueScore',minimumExistingScore=.5)
        values[0]['referenceInkAdditionalPolicies']=[dict(existingScoreField='polarityRescueScore',minimumExistingScore=.05)]
        def proof(packets,ems,priors,pairs,policy):
            self.assertEqual(priors[0]['polarityRescueScore'],.9)
            return [dict(priors[0],sourceWeight='bold',renderBold=True,registeredInkRescueApplied=True)]
        with patch('font_context_bounds.measure_fill',return_value=np.zeros(71)), \
                patch('reference_ink_source.infer_page',side_effect=proof):
            result=refine_page(*values)
        self.assertEqual(result[0]['sourceWeight'],'bold')
        self.assertEqual(result[0]['polarityRescueScore'],.1)
        self.assertEqual(result[0]['sourcePolaritySampledUpperConfidence'],.9)

    def test_peer_uncertainty_cannot_open_reference_gate_from_zero_nominal_support(self):
        values=self.fixture();values[-1][0]['polarityRescueScore']=0.
        values[0]['referenceInkPolicy']=dict(existingScoreField='polarityRescueScore',minimumExistingScore=.05)
        with patch('font_context_bounds.measure_fill',return_value=np.zeros(71)), \
                patch('reference_ink_source.infer_page') as proof:
            result=refine_page(*values)
        proof.assert_not_called()
        self.assertEqual(result[0]['sourceWeight'],'regular')


if __name__=='__main__':unittest.main()
