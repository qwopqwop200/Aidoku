import unittest
from pathlib import Path
import tempfile

import numpy as np

from evaluate_gt import grouped_splits
from prepare_full_rf import evidence_grids, sample, process, load_case_features


class EvidenceTests(unittest.TestCase):
    def test_transitive_duplicate_sources_stay_together(self):
        rows = [dict(sourceImageSHA256=s, cropSHA256=c, individualPolygonsCrop=[])
                for s, c in [('a', 'first'), ('b', 'shared'), ('c', 'shared')]]
        split = grouped_splits(rows, {'a': 'pixels', 'b': 'pixels', 'c': 'other'})
        self.assertEqual(len(set(split.values())), 1)

    def test_target_metadata_does_not_change_split(self):
        rows = [dict(sourceImageSHA256='a', cropSHA256='pixels', individualPolygonsCrop=[])]
        before = grouped_splits(rows)
        rows[0].update(maskSHA256='different-target', status='ambiguous')
        self.assertEqual(before, grouped_splits(rows))

    def test_rf_native_centres_are_identity(self):
        grid = np.arange(162 * 162, dtype=np.float32).reshape(162, 162)
        actual = sample(grid, [0, 0, 162, 162], 162, 162)
        np.testing.assert_array_equal(grid, actual)

    def test_rf_border_and_half_pixel_bilinear(self):
        grid = np.tile(np.arange(162, dtype=np.float32), (162, 1))
        result = sample(grid, [0, 0, 324, 1], 324, 324)[0]
        self.assertEqual(result[0], 0)
        self.assertEqual(result[1], .25)
        self.assertEqual(result[-1], 161)

    def test_all_queries_and_classes_survive_without_acceptance_threshold(self):
        boxes = np.array([[.25, .5, .5, 1], [.75, .5, .5, 1]], np.float32)
        logits = np.full((2, 5), -2, np.float32)
        logits[1, 4] = 1
        masks = np.zeros((2, 162, 162), np.float32)
        classes, occupancy, grids = evidence_grids(boxes, logits, masks)
        self.assertEqual(len(grids), 15)
        self.assertGreater(grids[0].max(), 0)  # low-score query still contributes
        self.assertGreater(grids[12].max(), grids[0].max())  # fifth class retained
        _, _, permuted = evidence_grids(boxes[::-1], logits[::-1], masks[::-1])
        np.testing.assert_allclose(grids, permuted)

    def test_compact_native_grid_cache_preserves_all_source_features(self):
        rng = np.random.default_rng(4)
        boxes = np.tile(np.array([.5,.5,.4,.4],np.float32),(300,1))
        logits = rng.normal(size=(300,5)).astype(np.float32)
        masks = rng.normal(size=(300,162,162)).astype(np.float32)
        row = dict(id='synthetic',pageSize=[96,64],cropBounds=[0,0,96,64],
                   polygons=[[[10,10],[30,10],[30,50],[10,50]]])
        record = dict(sourceSHA256='synthetic',width=96,height=64)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for mode in ['legacy','compact']:
                out = root/mode; destination = out/'rf-full/crops'; destination.mkdir(parents=True)
                spool = out/'spool'; spool.mkdir()
                for name,values in [('boxes',boxes),('logits',logits),('instance_masks',masks)]:
                    values.tofile(spool/f'synthetic-{name}.f32')
                process(record,[row],spool,destination,compact=mode=='compact')
                self.assertFalse(list(spool.iterdir()))
            a = load_case_features(row,root/'legacy')
            b = load_case_features(row,root/'compact')
            np.testing.assert_array_equal(a,b)


if __name__ == '__main__':
    unittest.main()
