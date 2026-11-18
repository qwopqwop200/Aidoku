"""Focused fresh-source and prototype-exclusion regression checks."""

import hashlib
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import optimized_measurements as measurements
from font_metric_features import default_font_paths
from optimized_features.templates import rotate


class FreshMeasurementsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        paths = default_font_paths()
        cls.paths = (paths, paths + paths, paths)
        rng = np.random.default_rng(65)
        descriptors = rng.normal(size=(12, 198)).astype(np.float32)
        descriptors /= np.linalg.norm(descriptors, axis=1)[:, None]
        cls.bank = {
            "features": descriptors,
            "emPerComponentScale": np.arange(12, dtype=np.float32) + 1,
            "support": np.ones(12, np.float32),
            "excludedBySourceGroup": {"g:known": np.array([0, 1, 2])},
        }

    def packet(self):
        image = Image.new("RGB", (64, 88), "white")
        ImageDraw.Draw(image).text(
            (7, 4),
            "あ\nい",
            font=ImageFont.truetype(self.paths[0][0], 30),
            fill="black",
        )
        rgb = np.asarray(image).copy()
        return {
            "rgb": rgb,
            "bbox": [4, 4, 56, 80],
            "prior": 30.0,
            "text": "あい",
            "ownership": rgb.min(axis=2) < 220,
            "pageSize": [500, 800],
            "confidence": 0.98,
            "role": "dialogue",
            "cropOrigin": [50, 70],
            "sourceHash": "fresh-source",
            "sourceGroup": "fresh-source",
            "style": {
                "sourceOnly": True,
                "inferenceUsesGT": False,
                "fill": {"rgb": [0, 0, 0]},
                "background": {"rgb": [255, 255, 255]},
                "outline": {"present": False},
                "shadow": {"present": False},
            },
        }

    def test_fresh_source_extracts_supported_features_and_preserves_inputs(self):
        packet = self.packet()
        rgb, owned = packet["rgb"].copy(), packet["ownership"].copy()
        result = measurements.extract_source_measurements(
            packet, {}, font_paths=self.paths
        )
        for key, width in measurements.SIGNAL_WIDTHS.items():
            self.assertEqual(result[key].shape, (width,), key)
            self.assertTrue(np.isfinite(result[key]).all(), key)
        self.assertGreater(result["masked65"].sum(), 0)
        self.assertGreater(result["templates167"][-2], 0)
        self.assertGreater(result["style187"][255], 0)
        np.testing.assert_array_equal(packet["rgb"], rgb)
        np.testing.assert_array_equal(packet["ownership"], owned)

    def test_numeric_or_semantic_labels_are_not_inputs(self):
        identity = {"sourceImageSHA256": "a" * 64, "cropSHA256": "b" * 64}
        annotated = dict(identity, fontSizePx=-999999, split="test", sourceGroup=1)
        self.assertEqual(
            measurements._source_identity_rows({"items": [annotated]}), [identity]
        )
        annotated.update(fontSizePx=999999, split="train", sourceGroup="query")
        self.assertEqual(
            measurements._source_identity_rows({"items": [annotated]}), [identity]
        )
        for invalid in (None, 123, "not-a-source-hash", "z" * 64):
            with self.assertRaisesRegex(ValueError, "source provenance"):
                measurements._source_identity_rows(
                    {"items": [dict(identity, sourceImageSHA256=invalid)]}
                )
        packet = self.packet()
        packet["fontSizePx"] = -999999
        packet["itemID"] = "arbitrary-old-item"
        first = measurements.extract_source_measurements(
            packet, {}, font_paths=self.paths
        )
        packet["fontSizePx"] = 999999
        packet["itemID"] = "another-item"
        second = measurements.extract_source_measurements(
            packet, {}, font_paths=self.paths
        )
        for key in measurements.SIGNAL_WIDTHS:
            np.testing.assert_array_equal(first[key], second[key], err_msg=key)

    def test_source_member_polygon_drives_fresh_pose_measurements(self):
        packet = self.packet()
        packet["memberPolygons"] = [[[22, 6], [38, 12], [18, 78], [4, 72]]]
        result = measurements.extract_source_measurements(
            packet, {}, font_paths=self.paths
        )
        self.assertGreater(abs(result["angles131"]), 1)
        self.assertLess(result["priorRatio131"], 1 / 1.1)
        for key, width in measurements.SIGNAL_WIDTHS.items():
            self.assertEqual(result[key].shape, (width,), key)
            self.assertTrue(np.isfinite(result[key]).all(), key)

    def test_missing_style_fails_instead_of_fabricating_late_features(self):
        packet = self.packet()
        del packet["style"]
        with self.assertRaisesRegex(ValueError, "source-predicted style"):
            measurements.extract_source_measurements(packet, {}, font_paths=self.paths)

    def test_context_and_prediction_mask_admission(self):
        packet = self.packet()
        packet["bbox"] = [20, 20, 20, 20]
        with self.assertRaisesRegex(ValueError, "15%"):
            measurements._validate_packet(packet)
        packet = self.packet()
        packet["GTMaskUsed"] = True
        with self.assertRaisesRegex(ValueError, "source-predicted"):
            measurements._validate_packet(packet)

    def test_prototypes_exclude_stable_same_source_groups(self):
        query = self.bank["features"][0:1]
        result = measurements._neighbors(
            query, [20], [0], self.bank, source_groups=["g:known"]
        )
        self.assertFalse(np.isin(result["ratios"], [1, 2, 3]).any())
        independent = measurements._neighbors(
            query, [20], [0], self.bank, source_groups=["new-hash"]
        )
        self.assertEqual(independent["ratios"][0, 0], 1)
        with self.assertRaisesRegex(ValueError, "stable string"):
            measurements._neighbors(query, [20], [0], self.bank, source_groups=[0])

    def test_asset_hash_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "font.ttf"
            path.write_bytes(b"font")
            record = {"path": str(path), "SHA256": hashlib.sha256(b"other").hexdigest()}
            with self.assertRaisesRegex(ValueError, "hash differs"):
                measurements._font_paths({"fonts": [record]}, "fonts", 1)

    def test_pose_rotation_preserves_observation_and_does_not_rescale(self):
        observation = np.ones((20, 30), np.uint8)
        rotated, bbox = rotate(observation, [0, 0, 30, 20], 20, nearest=True)
        self.assertGreater(rotated.shape[0], 20)
        self.assertGreater(rotated.shape[1], 30)
        self.assertLessEqual(abs(int(rotated.sum()) - 600), 4)
        self.assertGreater(bbox[2], 30)


if __name__ == "__main__":
    unittest.main()
