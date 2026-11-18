import copy
import unittest
import numpy as np
from source_fill_palette import augment,attach,VERSION
from paint_palette_metrics import predicted_colours


class FixedClassifier:
    def predict_proba(self,x):return np.array([[.01,.99],[.1,.9],[.99,.01]])


class SourceFillPaletteTests(unittest.TestCase):
    def inputs(self):
        packet=dict(version='source-palette-rf-seg-geometry-v2',colors=[[0,0,0],[220,20,30],[250,250,250]],features=np.zeros((3,209)).tolist())
        prediction=dict(fill=dict(rgb=[0,0,0]),outline=dict(rgb=[250,250,250],present=True,probability=.9),background=dict(rgb=[250,250,250]),
            pixelRoleEvidence=dict(roles=dict(fill=dict(observedColours=[dict(rgb=[1,1,1],observedMass=.9),dict(rgb=[50,50,50],observedMass=.1)]))))
        model=dict(version=VERSION,sourceFeatureVersion=packet['version'],classifier=FixedClassifier(),threshold=.85,pruneThreshold=0,mergeDelta=10,limit=12)
        return packet,prediction,model

    def test_added_secondary_colour_never_removes_prior_palette_or_changes_scalar(self):
        packet,pred,model=self.inputs();before=copy.deepcopy(pred);selected=augment(packet,pred,model)
        self.assertEqual(selected[:2],before['pixelRoleEvidence']['roles']['fill']['observedColours'])
        self.assertEqual(selected[2]['rgb'],[220,20,30]);self.assertEqual(len(selected),3)
        attach(packet,pred,model)
        self.assertEqual(pred['fill']['rgb'],before['fill']['rgb'])
        self.assertEqual(pred['pixelRoleEvidence'],before['pixelRoleEvidence'])
        self.assertEqual(predicted_colours(pred),[dict(rgb=c['rgb']) for c in selected])

    def test_rejected_pruning_and_wrong_source_contract_are_not_silently_admitted(self):
        packet,pred,model=self.inputs()
        for change in [dict(pruneThreshold=.01),dict(requiresPixelRoleSupport=True),dict(sourceFeatureVersion='old')]:
            with self.assertRaises(ValueError):augment(packet,pred,dict(model,**change))

    def test_explicit_noop_keeps_all_prior_colours(self):
        packet,pred,model=self.inputs();result=augment(packet,pred,dict(model,threshold=1.1,classifier=None))
        self.assertEqual(result,pred['pixelRoleEvidence']['roles']['fill']['observedColours'])


if __name__=='__main__':unittest.main()
