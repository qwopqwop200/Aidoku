#!/usr/bin/env python3
"""No-build raw-audit wiring/contract and stored remaining27 smoke checks."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR"
HELPER = (OCR / "NativeCausalRawDecodeDiagnostics.swift").read_text()
RECOGNIZER = (OCR / "NativeCoreMLRecognizer.swift").read_text()


class RawDecodeSmoke(unittest.TestCase):
    def test_default_off_and_page_scoped_dispatch(self):
        self.assertIn('@TaskLocal static var current:', HELPER)
        self.assertIn('environment["AIDOKU_OCR_RAW_DECODE_AUDIT"] == "1"', HELPER)
        self.assertIn('enabled: Bool = NativeCausalRawDecodeDiagnostics.runtimeEnabled', HELPER)
        self.assertIn('current?.record(event)', HELPER)
        dispatch = RECOGNIZER.split('private func emitAudit(', 1)[1].split(
            'var lastDiagnostics:', 1)[0]
        self.assertIn('@autoclosure', dispatch)
        self.assertIn('guard auditObserver != nil || NativeCausalRawDecodeDiagnostics.current != nil', dispatch)
        self.assertIn('auditObserver?(value)', dispatch)
        self.assertIn('NativeCausalRawDecodeDiagnostics.observe(value)', dispatch)
        self.assertNotIn('NativeCausalRawDecodeDiagnostics.current =', RECOGNIZER)

    def test_all_existing_observation_sites_use_dispatch(self):
        self.assertEqual(RECOGNIZER.count('emitAudit(.requested('), 3)
        self.assertEqual(RECOGNIZER.count('emitAudit(.decoded('), 2)
        self.assertNotRegex(RECOGNIZER, r'auditObserver[?(]*\.(?:requested|decoded)')
        for value in ('cached', 'decoded'):
            pattern = (
                r'emitAudit\(\.decoded\(\s*'
                r'requestID: requestID, region: preparedWork.work.region,\s*'
                rf'text: {value}.text, confidence: {value}.confidence,\s*'
                r'threshold: threshold, cacheHit: (?:true|false)\s*\)\)\s*'
                rf'if !{value}.text.isEmpty,\s*{value}.confidence >= threshold'
            )
            self.assertRegex(RECOGNIZER, pattern)

    def test_bounded_whitelist_and_exact_binding(self):
        for field in (
            'version', 'ordinal', 'requestID', 'sourceIndex', 'polygon', 'samplingPolygon',
            'minimumSequenceWidth', 'text', 'textTruncated', 'empty', 'confidence', 'threshold',
            'belowRecognizerFloor', 'cacheHit', 'detectorBinding', 'detectorIndex', 'detectorOwnerID',
            'requestedRows', 'decodedRows', 'dataBytes', 'droppedRows', 'invalidRows',
            'rejectedBindings', 'truncated', 'maximumDataAndSummaryBytes'
        ):
            self.assertIn('"' + field + '"', HELPER)
        for contract in (
            'requestedRows: min(256', 'decodedRows: min(512', 'min(1_048_576',
            'min(1024', 'limits.bytes - 1024 - emittedBytes',
            'detectors[requestID]?[region.sourceIndex]', 'detector.polygon == region.polygon',
            '"unbound-or-recovery-geometry"', 'confidence.isFinite', 'threshold.isFinite',
            'guard !finished else', 'guard enabled else', 'sink(data)'
        ):
            self.assertIn(contract, HELPER)
        for forbidden in ('base64EncodedString', 'HostDump.capture', 'sourceProbabilityROI',
                          'recognizer.recognize(', 'CGImage', 'FileHandle', 'print('):
            self.assertNotIn(forbidden, HELPER)



if __name__ == "__main__":
    unittest.main(verbosity=2)
