#!/usr/bin/env python3
"""Check every bundled UI locale. Run from any directory; no dependencies required."""
from collections import Counter
from pathlib import Path
import re
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]
LOCALIZATION = ROOT / 'Aidoku/App/Resources/Localization'
# Tokenize comments separately so URLs and comment-like text inside values survive.
TOKEN = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hljztL])?([@diuoxXfFeEgGaAcCsSp%])')
SETTING_REFERENCE = re.compile(r'(?:title|footer|subtitle|placeholder):\s*"([A-Z][A-Z_0-9]+)"|SourceError\.message\("([A-Z][A-Z_0-9]+)"')
REFERENCE = re.compile(r'(?:NSLocalizedString\s*\(\s*|String\s*\(\s*localized:\s*)"([^"\\]+)"')


def parse(path):
    errors = []
    values = {}
    if not path.exists():
        return values, [f'{path.relative_to(ROOT)}: missing table']
    text = path.read_text(encoding='utf-8-sig')
    cursor = 0
    while cursor < len(text):
        match = TOKEN.match(text, cursor)
        if not match:
            line = text.count('\n', 0, cursor) + 1
            errors.append(f'{path.relative_to(ROOT)}:{line}: malformed .strings entry')
            break
        key, value = match.groups()
        if key is not None:
            if key in values:
                errors.append(f'{path.relative_to(ROOT)}: duplicate key {key}')
            if not value.strip():
                errors.append(f'{path.relative_to(ROOT)}: empty value {key}')
            values[key] = value
        cursor = match.end()
    return values, errors


def signature(value):
    """Allow positional argument reordering, but retain argument index and type."""
    result = Counter()
    index = 1
    for match in FORMAT.finditer(value):
        position, length, kind = match.groups()
        if kind == '%':
            result['literal percent'] += 1
            continue
        argument = int(position) if position else index
        if not position:
            index += 1
        result[(argument, length or '', kind)] += 1
    return result


def copied_english(source, value, locale):
    """Flag unchanged English prose; short shared names/technical terms are allowed."""
    return locale != 'en' and source == value and len(re.findall(r"[A-Za-z]+", source)) >= 4


def validate_table(directory, table, locales):
    source, errors = parse(directory / 'en.lproj' / table)
    entries = 0
    for locale in locales:
        path = directory / (locale + '.lproj') / table
        values, issues = parse(path)
        errors.extend(issues)
        label = str(path.relative_to(ROOT))
        for key in sorted(source.keys() - values.keys()):
            errors.append(f'{label}: missing {key}')
        for key in sorted(values.keys() - source.keys()):
            errors.append(f'{label}: unknown key {key}')
        for key in source.keys() & values.keys():
            if signature(source[key]) != signature(values[key]):
                errors.append(f'{label}: format arguments differ for {key}')
            if re.search(r'ZXQ\s*\d+\s*QXZ', values[key], re.I):
                errors.append(f'{label}: translation marker in {key}')
            if copied_english(source[key], values[key], locale):
                errors.append(f'{label}: untranslated English text for {key}')
        entries += len(values)
    return source, entries, errors


def main():
    errors = []
    project = (ROOT / 'Aidoku.xcodeproj/project.pbxproj').read_text()
    regions = re.search(r'knownRegions = \((.*?)\);', project, re.S)
    if not regions:
        print('Cannot read Xcode knownRegions', file=sys.stderr)
        return 1
    expected = {item.strip().strip(chr(34)) for item in regions[1].split(',') if item.strip()} - {'Base'}
    entries = 0
    references = set()
    targets = [
        (LOCALIZATION, ROOT / 'Aidoku', ['Localizable.strings', 'InfoPlist.strings']),
        (ROOT / 'AidokuShare', ROOT / 'AidokuShare', ['Localizable.strings']),
    ]
    for directory, source_directory, tables in targets:
        actual = {locale.stem for locale in directory.glob('*.lproj')}
        if expected != actual:
            errors.append(f'{directory.relative_to(ROOT)}: locale mismatch: '
                          f'missing {sorted(expected - actual)}, extra {sorted(actual - expected)}')
        english = {}
        for table in tables:
            source, count, issues = validate_table(directory, table, sorted(expected))
            english[table] = source
            entries += count
            errors.extend(issues)
        if directory == LOCALIZATION:
            with (ROOT / 'Aidoku/Info.plist').open('rb') as info_file:
                info = plistlib.load(info_file)
            for key, value in info.items():
                if key.endswith('UsageDescription') and english['InfoPlist.strings'].get(key) != value:
                    errors.append(f'InfoPlist.strings: missing or outdated English permission text for {key}')
        for path in sorted(source_directory.rglob('*.swift')):
            text = path.read_text()
            keys = REFERENCE.findall(text) + [a or b for a, b in SETTING_REFERENCE.findall(text)]
            for key in keys:
                references.add(key)
                if key not in english['Localizable.strings']:
                    errors.append(f'{path.relative_to(ROOT)}: undefined localization key {key}')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        print(f'FAIL: {len(errors)} localization errors', file=sys.stderr)
        return 1
    print(f'PASS: {len(expected)} locales, app + share extension, {entries} entries; '
          f'{len(references)} literal Swift localization keys resolved. '
          'No missing, extra, duplicate, blank, malformed, copied English prose or incompatible format entries.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
