import unittest
from pathlib import Path
import hashlib

import numpy as np
import directional_ink

from directional_ink_rules import apply_page, measure_source_page
from features import render_policy


class DirectionalRuleTests(unittest.TestCase):
    def test_rule_cannot_silently_use_changed_measurement_code(self):
        with self.assertRaisesRegex(ValueError, 'different measurement'):
            measure_source_page([], [], dict(mode='color', measurementSHA256='obsolete'))

    def test_source_packet_is_measured_without_annotation_or_identity_fields(self):
        rgb = np.full((100, 100, 3), 255, np.uint8)
        rgb[20:80, 20:30] = 0
        packet = dict(rgb=rgb, ownership=np.ones((100, 100), bool),
                      style=dict(fill=dict(rgb=[0, 0, 0]), background=dict(rgb=[255, 255, 255])))
        policy = dict(mode='color', measurementSHA256=hashlib.sha256(Path(directional_ink.__file__).read_bytes()).hexdigest())
        result = measure_source_page([packet], [60.], policy)
        self.assertEqual(len(result), 1)
        self.assertGreater(result[0]['color']['groups']['verticalStems']['count'], 32)

    def test_mixed_remains_regular_and_requires_many_source_rays(self):
        def observation(width, rays=600):
            groups = dict(verticalStems=dict(count=rays, quantiles=[width]*4),
                          horizontalStems=dict(count=rays, quantiles=[.08]*4),
                          diagonalStems=dict(count=rays, quantiles=[width]*4))
            return dict(color=dict(components=10, groups=groups))
        policy = dict(mode='color', direction='diagonalStems', quantile=3,
                      minimumWidthEm=.18, minimumDirectionContrast=1.75,
                      minimumPageRelative=1.25, existingScoreField='none',
                      minimumDirectionalRays=512)
        predictions = [render_policy(label) for label in ('mixed', 'regular', 'regular', 'regular', 'regular')]
        result = apply_page([observation(.2), observation(.2), observation(.2, 100),
                             observation(.08), observation(.08)], predictions, policy)
        self.assertEqual(result[0]['sourceWeight'], 'mixed')
        self.assertFalse(result[0]['renderBold'])
        self.assertEqual(result[1]['sourceWeight'], 'bold')
        self.assertEqual(result[2]['sourceWeight'], 'regular')
        self.assertEqual(result[3]['sourceWeight'], 'regular')


if __name__ == '__main__':
    unittest.main()
