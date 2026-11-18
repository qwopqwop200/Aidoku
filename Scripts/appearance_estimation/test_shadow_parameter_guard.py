import copy
import unittest
import tempfile
from pathlib import Path
from continuous_optimize import shadow_parameter_guard,score
from optimize_appearance import save


class ShadowParameterGuardTests(unittest.TestCase):
    def report(self):
        group=dict(colour=dict(within10Count=1,emitted=1),offset=dict(within2PxCount=1,emitted=1))
        return dict(metrics=dict(train=copy.deepcopy(group),dev=copy.deepcopy(group)),knownNegativeRGBEmissions=dict(train=0,dev=0))

    def test_more_colour_hits_cannot_compensate_for_losing_a_valid_offset(self):
        old=self.report();new=copy.deepcopy(old)
        new['metrics']['dev']['colour']=dict(within10Count=2,emitted=2)
        new['metrics']['dev']['offset']['within2PxCount']=0
        self.assertFalse(shadow_parameter_guard(old,new))

    def test_extra_wrong_colours_are_not_accepted_as_better_output_coverage(self):
        old=self.report();new=copy.deepcopy(old);new['metrics']['dev']['colour']['emitted']=2
        self.assertFalse(shadow_parameter_guard(old,new))

    def test_adding_valid_parameters_preserves_the_gate_but_new_negative_emission_does_not(self):
        old=self.report();new=copy.deepcopy(old);new['metrics']['dev']['colour']=dict(within10Count=2,emitted=2)
        self.assertTrue(shadow_parameter_guard(old,new))
        new['knownNegativeRGBEmissions']['train']=1
        self.assertFalse(shadow_parameter_guard(old,new))

    def test_legacy_missing_parameter_report_and_explicit_abstention_use_same_score_scale(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            metric=dict(fill=dict(within10=1),outline=dict(within10=1),background=dict(within10=1),
                outlinePresence=dict(balancedAccuracy=1),shadowPresence=dict(TP=1,FP=0,FN=0))
            save(folder/'BEST.json',dict(metrics=dict(dev=metric)))
            save(folder/'WIDTH-RESULTS.json',dict(selected=dict(dev=dict(withinGTRange=1))))
            baseline=score(folder)
            quality=dict(colour=dict(within10IncludingMissing=0.),offset=dict(within2IncludingMissing=0.))
            save(folder/'SHADOW-PARAMETER-RESULTS.json',dict(metrics=dict(dev=quality)))
            self.assertEqual(score(folder),baseline)
            quality['colour']['within10IncludingMissing']=.5
            save(folder/'SHADOW-PARAMETER-RESULTS.json',dict(metrics=dict(dev=quality)))
            self.assertGreater(score(folder),baseline)


if __name__=='__main__':unittest.main()
