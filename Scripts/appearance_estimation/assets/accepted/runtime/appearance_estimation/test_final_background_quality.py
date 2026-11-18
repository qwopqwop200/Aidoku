"""Final emitted colour governs admission, independently of raw ranker indices."""
import copy
from pathlib import Path
import tempfile
import unittest
from optimize_appearance import save
from continuous_optimize import background_colour_metrics,background_colour_guard,improves_quality


class FinalBackgroundQualityTests(unittest.TestCase):
    def test_emitted_rgb_is_scored_even_when_ranker_provenance_stays_unchanged(self):
        rows=[dict(itemID='a',evaluationSplit='train',background=dict(rgb=[255,255,255])),
              dict(itemID='b',evaluationSplit='dev',background=dict(rgb=[255,255,255]))]
        pred=[dict(itemID=r['itemID'],backgroundIndex=99,background=dict(rgb=[255,255,255])) for r in rows]
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary);save(path/'predictions-with-width.json',dict(items=pred))
            metrics=background_colour_metrics(path,rows)
            self.assertEqual(metrics['dev']['meanDeltaE'],0.)
            pred[1]['background']['rgb']=[0,0,0]
            save(path/'predictions-with-width.json',dict(items=pred))
            self.assertGreater(background_colour_metrics(path,rows)['dev']['meanDeltaE'],90)

    def test_continuous_improvement_can_break_an_aggregate_score_tie(self):
        before={g:dict(within10=.99,meanDeltaE=2.) for g in ['train','dev']}
        after=copy.deepcopy(before);after['dev']['meanDeltaE']=1.9
        self.assertTrue(background_colour_guard(before,after))
        self.assertTrue(improves_quality(.98,.98,after,before))
        self.assertFalse(improves_quality(.97,.98,after,before))

    def test_dev_mean_gain_cannot_hide_train_damage_or_categorical_loss(self):
        before={g:dict(within10=.99,meanDeltaE=2.) for g in ['train','dev']}
        after=copy.deepcopy(before);after['dev']['meanDeltaE']=1.9;after['train']['meanDeltaE']=2.1
        self.assertFalse(background_colour_guard(before,after))
        after=copy.deepcopy(before);after['dev'].update(meanDeltaE=1.9,within10=.98)
        self.assertFalse(background_colour_guard(before,after))


if __name__=='__main__':unittest.main()
