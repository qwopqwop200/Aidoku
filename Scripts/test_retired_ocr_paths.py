"""Retired experiments must not remain build/cache dependencies."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
RETIRED = (
    'NativeOCRFinePrintContextRecovery', 'NativeOCRQuotedContextRecovery',
    'NativeOCRShortReactionRecovery', 'NativeOCRShortFragmentRecovery',
    'NativeOCRShortContextRecovery', 'NativeOCRLowConfidenceContextRecovery',
    'NativeOCRFragmentedGridRecovery',
)


class RetiredOCRPathsTests(unittest.TestCase):
    def test_no_production_reference_or_definition(self):
        for file in (ROOT/'Aidoku').rglob('*.swift'):
            source = file.read_text()
            for name in RETIRED:
                self.assertNotIn(name, source, str(file))

    def test_actual_rf_paths_are_retained(self):
        source = (ROOT/'Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLOCRPipeline.swift').read_text()
        for call in ('recognitionCrop(', 'completeSupportSampling('):
            self.assertIn('NativeOCRRFPrimaryEnsemble.'+call, source)
        kernel = (ROOT/'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRRFGapRecovery.swift').read_text()
        ingress = kernel.split('static func recognitionCrop(', 1)[1].split('static func completingClippedEndpointInk(', 1)[0]
        for call in ('pixelEndpointCompletion(index:', 'supportedEndpointCompletion(index:'):
            self.assertIn(call, ingress)
        self.assertIn('expandedFirstCrops.append(', source)

if __name__ == '__main__':
    unittest.main()
