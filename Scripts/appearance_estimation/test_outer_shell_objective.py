"""Missing layer audits and extra incorrect output cannot inflate objective."""
import tempfile
from pathlib import Path
import unittest
from continuous_optimize import score
from optimize_appearance import save


class OrderedLayerObjectiveTests(unittest.TestCase):
    def test_actual_colour_width_matches_improve_score_but_invented_layers_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory)
            metric=dict(fill=dict(within10=1),outline=dict(within10=1),background=dict(within10=1),
                        outlinePresence=dict(balancedAccuracy=1),shadowPresence=dict(TP=1,FP=0,FN=0))
            save(folder/'BEST.json',dict(metrics=dict(dev=metric)))
            save(folder/'WIDTH-RESULTS.json',dict(selected=dict(dev=dict(withinGTRange=1))))
            missing=score(folder)
            layer=dict(expectedMultilayer=5,emittedMultilayer=0,orderedColourAndApproximateWidthMatches=0)
            save(folder/'ORDERED-LAYER-RESULTS.json',dict(metrics=dict(dev=layer)))
            self.assertEqual(score(folder),missing)
            layer.update(emittedMultilayer=1,orderedColourAndApproximateWidthMatches=1)
            save(folder/'ORDERED-LAYER-RESULTS.json',dict(metrics=dict(dev=layer)))
            one=score(folder);self.assertGreater(one,missing)
            layer.update(emittedMultilayer=2,orderedColourAndApproximateWidthMatches=2)
            save(folder/'ORDERED-LAYER-RESULTS.json',dict(metrics=dict(dev=layer)))
            two=score(folder);self.assertGreater(two,one)
            layer['emittedMultilayer']=8
            save(folder/'ORDERED-LAYER-RESULTS.json',dict(metrics=dict(dev=layer)))
            self.assertLess(score(folder),two)


if __name__=='__main__':unittest.main()
