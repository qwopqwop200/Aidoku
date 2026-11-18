import copy
import unittest
from source_shadow_presence import apply,calibrate,restore_baseline,emitted_metrics


class SourceShadowPresenceTests(unittest.TestCase):
    def prediction(self,identity,probability,support=False):
        return dict(itemID=identity,shadow=dict(present=True,probability=probability,sourceObservation=dict(displacement=dict(identified=support))))

    def source(self):
        rows=[];predictions=[]
        for group in ['train','dev']:
            for kind,label,probability,support in [('weak',True,.35,True),('strong',True,.99,False),('noise',False,.6,False)]:
                identity=group+kind;rows.append(dict(itemID=identity,evaluationSplit=group,shadow=dict(present=label)))
                predictions.append(self.prediction(identity,probability,support))
        return rows,predictions

    def test_structure_retains_weak_true_shadow_while_uncorroborated_confidence_is_filtered(self):
        rows,pred=self.source();report=calibrate(rows,pred)
        self.assertEqual(report['threshold'],.7)
        for p in pred:apply(p,report['threshold'])
        self.assertEqual([p['shadow']['present'] for p in pred],[True,True,False]*2)

    def test_recalibration_reads_raw_baseline_and_does_not_collapse_threshold_after_filtering(self):
        rows,pred=self.source();threshold=calibrate(rows,pred)['threshold']
        for p in pred:apply(p,threshold)
        self.assertEqual(calibrate(rows,pred)['threshold'],threshold)
        for p in pred:restore_baseline(p)
        self.assertTrue(all(p['shadow']['present'] for p in pred))

    def test_emitted_metrics_count_final_flags_instead_of_raw_baseline(self):
        rows,pred=self.source()
        for p in pred:apply(p,.7)
        self.assertEqual(emitted_metrics(rows,pred)['dev']['FP'],0)
        self.assertEqual(calibrate(rows,pred)['baseline']['dev']['FP'],1)

    def test_presence_refinement_cannot_create_a_source_shadow_rejected_by_base_model(self):
        p=self.prediction('absent',.2,True);p['shadow']['present']=False
        apply(p,.7);self.assertFalse(p['shadow']['present'])


if __name__=='__main__':unittest.main()
