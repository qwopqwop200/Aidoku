"""No-build numeric specification + source wiring guards for Swift crop helper.

This does not claim Swift execution; NativeSourceCropBudgetTests.swift runs the
actual helper when the parent next performs its permitted compiled test batch.
"""
import math
from pathlib import Path
import unittest

from Scripts.tests.test_minimal_source_constructor_contract import body

ROOT = Path(__file__).resolve().parents[2]
FACTORY = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSourceInputFactory.swift"


def crop_spec(box, page, budget=1_500_000):
    x, y, w, h = box
    if x < 0 or y < 0 or x + w > page[0] or y + h > page[1]:
        right, bottom = min(x + w, page[0]), min(y + h, page[1])
        x, y = max(0, x), max(0, y)
        w, h = right - x, bottom - y
        if w <= 0 or h <= 0:
            raise ValueError("outside page")

    def padded(fraction):
        left, top = max(0, math.floor(x - w * fraction)), max(0, math.floor(y - h * fraction))
        right = min(page[0], math.ceil(x + w + w * fraction))
        bottom = min(page[1], math.ceil(y + h + h * fraction))
        return left, top, right - left, bottom - top

    def fits(crop):
        return crop[2] > 0 and crop[3] > 0 and crop[2] <= budget // crop[3]

    ordinary = padded(0.15)
    if fits(ordinary):
        return ordinary
    base = padded(0)
    if not fits(base):
        raise ValueError((base[2], base[3], budget))
    lower, upper, best = 0.0, 0.15, base
    for _ in range(64):
        middle = lower + (upper - lower) / 2
        if middle == lower or middle == upper:
            break
        candidate = padded(middle)
        if fits(candidate):
            lower, best = middle, candidate
        else:
            upper = middle
    return best


class SourceCropBudgetContract(unittest.TestCase):
    def test_both_factory_routes_call_the_same_helper(self):
        source = FACTORY.read_text()
        for marker in ("static func makeMinimal(", "static func make(source:"):
            method = body(source, marker)
            self.assertIn("try sourceCrop(box:", method)
            self.assertIn("bbox:localVisibleBox(box,crop:crop)", "".join(method.split()))
            self.assertNotIn("box.insetBy(", method)
        helper = body(source, "static func sourceCrop(")
        self.assertIn("if fits(ordinary) { return ordinary }", helper)
        self.assertIn("sourceCropBudgetExceeded", helper)
        self.assertIn("for _ in 0..<64", helper)
        self.assertNotIn("sourceFontSize", helper)

    def test_reported_exact_numeric_geometry(self):
        box = (0.54397215406202193 * 2160, 0.056144712272797818 * 2880,
               0.42375294324572615 * 2160, 0.36952053132912388 * 2880)
        x, y, w, h = crop_spec(box, (2160, 2880))
        self.assertLessEqual(w * h, 1_500_000)
        self.assertLessEqual(x, box[0])
        self.assertLessEqual(y, box[1])
        self.assertGreaterEqual(x + w, box[0] + box[2])
        self.assertGreaterEqual(y + h, box[1] + box[3])

    def test_normal_page_clipping_exact_budget_and_overlarge_base(self):
        self.assertEqual(crop_spec((8.25, 80, 20, 40), (100, 100)), (5, 77, 27, 23))
        self.assertEqual(crop_spec((100, 200, 100, 250), (2160, 2880)), (85, 162, 130, 326))
        self.assertEqual(crop_spec((0, 0, 900, 1000), (2160, 2880)), (0, 0, 1035, 1150))
        self.assertEqual(crop_spec((500, 500, 1000, 1500), (3000, 3000)), (500, 500, 1000, 1500))
        with self.assertRaisesRegex(ValueError, "1001, 1500, 1500000"):
            crop_spec((500, 500, 1001, 1500), (3000, 3000))

    def test_integral_search_against_dense_monotone_reference(self):
        for box, page in [((0.2, 0.3, 1100.4, 1100.5), (1300, 1300)),
                          ((100.25, 200.75, 915.3, 1064.2), (2160, 2880)),
                          ((10.1, 20.7, 998, 1498), (3000, 3000))]:
            crop = crop_spec(box, page)
            self.assertLessEqual(crop[2] * crop[3], 1_500_000)
            # A dense lower bound must not find more padding than binary search.
            for step in range(1501):
                f = step / 10000
                x, y, w, h = box
                left, top = max(0, math.floor(x - w*f)), max(0, math.floor(y - h*f))
                right, bottom = min(page[0], math.ceil(x+w+w*f)), min(page[1], math.ceil(y+h+h*f))
                if (right-left)*(bottom-top) <= 1_500_000:
                    self.assertLessEqual(crop[0], left)
                    self.assertLessEqual(crop[1], top)
                    self.assertGreaterEqual(crop[0]+crop[2], right)
                    self.assertGreaterEqual(crop[1]+crop[3], bottom)


if __name__ == "__main__":
    unittest.main()
