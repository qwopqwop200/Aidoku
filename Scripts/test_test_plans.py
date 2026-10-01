"""Guard default scope and retain an unfiltered exhaustive test entry point."""
import ast
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


# Tokenize declarations without matching trait-looking strings, comments, or a
# SwiftUI .disabled() call later in the test body. Attributes may span lines.
_SWIFT_TOKENS = re.compile(
    r'//[^\n]*|/\*[\s\S]*?\*/|\#*"""[\s\S]*?"""\#*|'
    r'\#*"(?:\\.|[^"\\])*"\#*|[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def swift_test_skip_tokens(source):
    tokens = [token for token in _SWIFT_TOKENS.findall(source)
              if not token.startswith(('//', '/*')) and not token.lstrip('#').startswith('"')]
    findings = []
    for index, token in enumerate(tokens):
        if token in {'XCTSkip', 'XCTSkipIf', 'XCTSkipUnless'} and tokens[index + 1:index + 2] == ['(']:
            findings.append(token)
        if token != '@' or tokens[index + 1:index + 3] not in (['Test', '('], ['Suite', '(']):
            continue
        depth = 1
        cursor = index + 3
        while cursor < len(tokens) and depth:
            current = tokens[cursor]
            if current == '(':
                depth += 1
            elif current == ')':
                depth -= 1
            elif current == '.' and tokens[cursor + 1:cursor + 3] in (['disabled', '('], ['enabled', '(']):
                findings.append('.' + tokens[cursor + 1])
            cursor += 1
    return findings


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

    def test_tests_do_not_silently_skip_for_local_prerequisites(self):
        for path in (ROOT / 'AidokuTests').rglob('*.swift'):
            source = path.read_text()
            self.assertEqual(swift_test_skip_tokens(source), [], str(path))
            self.assertNotRegex(source, r'guard\s+#available\([^)]*\)\s+else\s*\{\s*return\s*\}', str(path))
        for path in ROOT.glob('*.xctestplan'):
            for target in json.loads(path.read_text())['testTargets']:
                self.assertFalse(target.get('skippedTests'), str(path))
                self.assertIsNot(target.get('enabled'), False, str(path))

    def test_multiline_skip_guard_distinguishes_attributes_from_ui_and_literals(self):
        self.assertEqual(swift_test_skip_tokens(
            '@Test(\n "reason",\n .enabled(if: available())\n) func example() {}'), ['.enabled'])
        self.assertEqual(swift_test_skip_tokens(
            '@Suite(\n .serialized, .disabled("reason")\n) struct Example {}'), ['.disabled'])
        self.assertEqual(swift_test_skip_tokens('func example() { throw XCTSkip("reason") }'), ['XCTSkip'])
        self.assertEqual(swift_test_skip_tokens(
            '@Test func example() { view.disabled(true); let text = "XCTSkip(" } // @Test(.disabled())'), [])

    def test_host_tests_do_not_use_framework_skips(self):
        skip_names = {'skip', 'skipIf', 'skipUnless', 'skipTest', 'SkipTest', 'skipif'}
        paths = set((ROOT / 'Scripts').glob('test*.py')) | set((ROOT / 'Scripts/tests').glob('*.py'))
        for path in sorted(paths):
            for node in ast.walk(ast.parse(path.read_text(), filename=str(path))):
                if not isinstance(node, ast.Call):
                    continue
                name = node.func.attr if isinstance(node.func, ast.Attribute) else (
                    node.func.id if isinstance(node.func, ast.Name) else None)
                self.assertNotIn(name, skip_names, f'{path}:{node.lineno}')

    def test_suite_files_have_executable_tests(self):
        for path in (ROOT / 'AidokuTests').rglob('*.swift'):
            source = path.read_text()
            if re.search(r'@Suite\b', source):
                self.assertRegex(source, r'@Test\b', str(path))

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
