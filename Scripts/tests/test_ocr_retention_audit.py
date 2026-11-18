import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def module(name):
    path = Path(__file__).resolve().parents[1] / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


audit = module("audit_ocr_retention")
staging = module("stage_retained_target_corrections")


class OCRRetentionTests(unittest.TestCase):
    def test_missing_stage_is_not_success(self):
        result = audit.audit({"id": "x"})
        self.assertFalse(result["measured"])

    def test_copied_japanese_is_not_reported_as_detector_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ocr.json").write_text(json.dumps({"regions": [
                {"id": "region-3", "source": "あの…", "translation": "あの…", "confidence": .99}]}))
            (root / "payload.json").write_text(json.dumps({"value": {"nativeLayout": {"items": [
                {"id": "kept-3", "keptLettering": True}]}}}))
            result = audit.audit({"id": "x", "source": "original.png", "payload": str(root / "payload.json"),
                                  "runtimeEvidence": {"originalOCR": {"path": str(root / "ocr.json")}}})
            self.assertEqual(result["counts"], {"source-equals-target": 1})
            self.assertTrue(result["regions"][0]["keptLettering"])
            self.assertEqual(result["regions"][0]["directRenderItem"], "kept-3")

    def test_hangul_and_latin_are_not_japanese(self):
        self.assertFalse(audit.japanese("안녕 hello"))
        self.assertTrue(audit.japanese("検査"))

    def test_geometry_tolerance_is_transport_not_pixel_expansion(self):
        self.assertTrue(staging.same_geometry([.1, .2, .3, .4], [.1 + 1e-12, .2, .3, .4]))
        self.assertFalse(staging.same_geometry([.1, .2, .3, .4], [.101, .2, .3, .4]))
        self.assertFalse(staging.same_geometry([.1], [.1, .2]))


if __name__ == "__main__":
    unittest.main()
