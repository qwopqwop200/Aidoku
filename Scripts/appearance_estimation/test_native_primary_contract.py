"""Portable late-primary regression tests without external GT or source crops."""
import copy
import unittest
from unittest.mock import patch
import numpy as np
import source_native_primary_quality as quality


class Model:
    def predict(self,x):
        return np.array([.2,0.,0.])


class NativePrimaryContractTests(unittest.TestCase):
    def setUp(self):
        self.rgb=np.full((8,8,3),10,np.uint8)
        self.mask=np.ones((8,8),bool)
        self.prediction=dict(fill=dict(rgb=[20]*3,colors=[[20]*3,[30]*3,[30]*3]),marker='unchanged')
        self.bundle=dict(model=Model(),featureNames=['feature'])
        self.options=[dict(nativeRGB=[10]*3,evidence=dict(nativeXY=[0,0])) for _ in range(3)]

    def attach(self,prediction):
        with patch.object(quality,'validate_artifacts',return_value=self.bundle), \
             patch.object(quality,'extract_candidates',return_value=self.options), \
             patch.object(quality,'pair_features',return_value=dict(feature=0)):
            return quality.attach(self.rgb,self.mask,dict(polygons=[]),prediction)

    def test_secondary_order_multiplicity_and_cardinality_are_exact(self):
        old=copy.deepcopy(self.prediction);out,evidence=self.attach(self.prediction)
        self.assertTrue(evidence['applied'])
        self.assertEqual(out['fill']['colors'],[[10]*3,[30]*3,[30]*3])
        self.assertEqual(out['marker'],old['marker'])
        self.assertEqual(self.prediction,old)

    def test_warm_replay_and_exact_restore(self):
        out,_=self.attach(self.prediction);warm,_=self.attach(out)
        self.assertEqual(out,warm)
        with patch.object(quality,'validate_artifacts',return_value=self.bundle):
            self.assertEqual(quality.restore_baseline(out),self.prediction)

    def test_no_change_has_no_extra_palette_or_provenance(self):
        self.options=[dict(nativeRGB=[20]*3,evidence=dict(nativeXY=[0,0])) for _ in range(3)]
        out,report=self.attach(self.prediction)
        self.assertEqual(out,self.prediction)
        self.assertFalse(report['applied'])

    def test_tampered_warm_primary_or_secondary_is_rejected(self):
        out,_=self.attach(self.prediction)
        with patch.object(quality,'validate_artifacts',return_value=self.bundle):
            for field,value in [('rgb',[11]*3),('colors',[[10]*3,[31]*3,[30]*3])]:
                bad=copy.deepcopy(out);bad['fill'][field]=value
                with self.assertRaises(ValueError):quality.restore_baseline(bad)

    def test_source_rgb_witness_is_verified(self):
        out,_=self.attach(self.prediction);tag=out['fill'][quality.TAG]
        with patch.object(quality,'validate_artifacts',return_value=self.bundle):
            quality.validate(tag,self.rgb)
            other=self.rgb.copy();other[7,7]=11
            with self.assertRaises(ValueError):quality.validate(tag,other)

    def test_wrong_original_primary_slot_is_rejected(self):
        self.prediction['fill']['colors'][0]=[19]*3
        with self.assertRaises(ValueError):self.attach(self.prediction)


if __name__=='__main__':unittest.main()
