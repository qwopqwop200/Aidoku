import importlib.util
import unittest
from pathlib import Path


path = Path(__file__).parent / "equivalence" / "compare.py"
spec = importlib.util.spec_from_file_location("compare_structure", path)
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class LayoutStructureTests(unittest.TestCase):
    def assertDifferent(self, a, b):
        for left, right in [(a, b), (b, a)]:
            with self.subTest(left=left, right=right):
                self.assertFalse(compare.compare_layout(left, right, 0)["ok"])

    def test_literal_missing_string_is_not_absent_key(self):
        self.assertDifferent({"text": "<missing>"}, {})

    def test_empty_object_is_not_absent_key(self):
        self.assertDifferent({"metadata": {}}, {})

    def test_nested_empty_object_is_not_absent(self):
        self.assertDifferent({"items": [{"metadata": {}}]}, {"items": [{}]})

    def test_container_types_cannot_collide_with_flattened_keys(self):
        self.assertDifferent({"items": []}, {"items": {"#len": 0}})

    def test_literal_path_keys_are_not_nested_paths(self):
        self.assertDifferent({"a.b": 1}, {"a": {"b": 1}})
        self.assertDifferent({"items[0]": "x", "items.#len": 1}, {"items": ["x"]})

    def test_container_and_scalar_types_differ(self):
        self.assertDifferent({"items": {}}, {"items": None})
        self.assertDifferent({"items": []}, {"items": {}})

    def test_equal_structures_and_numeric_semantics(self):
        value = {"empty": {}, "items": [[], {}, {"text": "<missing>"}]}
        self.assertTrue(compare.compare_layout(value, value, 0)["ok"])
        self.assertTrue(compare.compare_layout({"x": [1, -0.0]}, {"x": [1.0, 0]}, 0)["ok"])
        self.assertFalse(compare.compare_layout({"x": True}, {"x": 1}, 0)["ok"])
        self.assertTrue(compare.compare_layout({"x": 1}, {"x": 1.125}, .125)["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
