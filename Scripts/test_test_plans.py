"""Guard default scope and retain an unfiltered exhaustive test entry point."""
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class TestPlanScopeTests(unittest.TestCase):
    def test_fast_is_scheme_default_and_full_remains_available(self):
        scheme = ET.parse(ROOT / 'Aidoku.xcodeproj/xcshareddata/xcschemes/Aidoku.xcscheme')
        self.assertEqual(scheme.find('./TestAction').get('buildConfiguration'), 'Release')
        refs = scheme.findall('./TestAction/TestPlans/TestPlanReference')
        defaults = [r.get('reference') for r in refs if r.get('default') == 'YES']
        self.assertEqual(defaults, ['container:AidokuFast.xctestplan'])
        self.assertIn('container:AidokuFull.xctestplan', [r.get('reference') for r in refs])
        full = json.loads((ROOT / 'AidokuFull.xctestplan').read_text())
        for target in full['testTargets']:
            self.assertNotIn('selectedTests', target)
            self.assertFalse(target.get('skippedTests'))
            self.assertFalse(target.get('enabled') is False)

    def test_fast_suite_identifiers_exist_and_exclude_live_benchmarks(self):
        fast = json.loads((ROOT / 'AidokuFast.xctestplan').read_text())
        self.assertIs(fast['defaultOptions']['codeCoverage'], False)
        selection = fast['testTargets'][0]['selectedTests']
        self.assertIsInstance(selection, dict)  # Legacy arrays select XCTest only.
        selected = [suite['name'] for suite in selection['suites']]
        self.assertFalse(selection.get('xctestClasses'))
        self.assertGreater(len(selected), 100)
        self.assertEqual(len(selected), len(set(selected)))
        declarations = set()
        for path in (ROOT / 'AidokuTests').rglob('*.swift'):
            declarations.update(re.findall(r'(?:struct|class)\s+(\w+Tests)\b', path.read_text()))
        self.assertFalse(set(selected) - declarations)
        self.assertNotIn('ReaderMixedNetworkABTests', selected)
        self.assertNotIn('NativeOCRRecognitionPerformanceTests', selected)
        self.assertNotIn('ReaderTranslationRenderSpeedTests', selected)
        self.assertIn('ReaderMemoryRecoveryTests', selected)
        self.assertIn('TranslationHTTPCodecTests', selected)
        self.assertIn('SourcePaginationTests', selected)
