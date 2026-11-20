#!/usr/bin/env python3
"""V2 host .env and settings resolution: the real V2HostSettings.swift and production
translation model types, compiled standalone. No model, image decode or network call."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TRANSLATION = ROOT / 'Aidoku/Core/Translation/NativeEngine/Translation'
SOURCES = [ROOT / 'Scripts/image-translation-v2/V2HostSettings.swift',
           ROOT / 'Aidoku/Extensions/Foundation/NSLocalizedString.swift'] + [
    TRANSLATION / f'{name}.swift' for name in (
        'TranslationModels', 'TranslationEndpointPolicy', 'TranslationHTTPCodec', 'TranslationImageSupport',
        'TranslationStreamDecoder', 'KeychainTranslationCredentialStore')]
CHECK = r'''
import Foundation
@main struct Check {
    static func main() {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let environment = try V2DotEnv.merged(root: root, environment: ProcessInfo.processInfo.environment)
            let settings = try V2HostSettings.parse(Array(CommandLine.arguments.dropFirst(2)),
                                                    environment: environment, root: root)
            var value = settings.describe()
            // Exposes only whether the resolved key equals the fixture, never the key itself.
            value["credentialMatchesFixture"] = (try? settings.credentialStore.secret(for: settings.keyEnv))
                == ProcessInfo.processInfo.environment["FIXTURE_EXPECTED_KEY"]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("\(error)\n", stderr); exit(2) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='aidoku-env-') as temporary:
    directory = Path(temporary)
    main = directory / 'Check.swift'
    main.write_text(CHECK)
    binary = directory / 'check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                    '-module-cache-path', str(directory / 'module-cache'),
                    *map(str, SOURCES), str(main), '-o', str(binary)], check=True)
    profile = directory / 'profile'
    profile.mkdir()
    image = profile / 'page.png'
    image.write_bytes(b'not decoded here')
    secret = 'env-fixture-secret-$(touch should-not-exist)'
    (profile / '.env').write_text(
        '# defaults\n'
        'export AIDOKU_TRANSLATION_BASE_URL="https://example.test/v1" # url\n'
        "AIDOKU_TRANSLATION_MODEL='fixture model'\n"
        f"AIDOKU_TRANSLATION_API_KEY='{secret}'\n"
        'AIDOKU_TRANSLATION_PROTOCOL=responses\n'
        'AIDOKU_TRANSLATION_SOURCE=ja\nAIDOKU_TRANSLATION_TARGET=en\n'
        'AIDOKU_TRANSLATION_REASONING=none\nAIDOKU_TRANSLATION_TIMEOUT=120\n'
        'AIDOKU_TRANSLATION_CREDENTIAL_GENERATION=4\nAIDOKU_TRANSLATION_CONCURRENCY=8\n'
        'AIDOKU_IMAGE_JOBS=4\nAIDOKU_READING_DIRECTION=leftToRight\n'
        # Retired legacy keys stay harmless.
        'AIDOKU_OCR_TIER=tiny\nAIDOKU_RENDER_VIEWPORT=390x844\n')
    base = {key: value for key, value in os.environ.items() if not key.startswith('AIDOKU_')}
    base['FIXTURE_EXPECTED_KEY'] = secret

    def run(args=(), extra=None, expected=0, cwd=directory):
        result = subprocess.run([str(binary), str(profile), *map(str, args)], env={**base, **(extra or {})},
                                cwd=cwd, capture_output=True, text=True)
        assert result.returncode == expected, result.stdout + result.stderr
        assert secret not in result.stdout + result.stderr
        return json.loads(result.stdout) if expected == 0 else result.stderr

    defaults = run([image])
    provider = defaults['provider']
    assert defaults['mode'] == 'live' and defaults['jobs'] == 4 and defaults['readingDirection'] == 'leftToRight'
    assert defaults['sourceLanguage'] == 'ja' and defaults['targetLanguage'] == 'en'
    assert provider['endpoint'] == 'https://example.test' and provider['model'] == 'fixture model', provider
    assert provider['protocol'] == 'responses' and provider['reasoning'] == 'none' and provider['timeout'] == 120
    assert provider['keyPresent'] and defaults['credentialMatchesFixture'] and provider['credentialGeneration'] == 4
    assert provider['concurrency'] == 3, 'provider calls are capped at three like the app'
    assert provider['includePageImage'] and provider['filterSFX'] and provider['filterBackground']
    assert 'fixture-secret' not in json.dumps(defaults)
    # The working directory does not matter: .env is read from the root.
    assert run([image], cwd=profile)['provider']['model'] == 'fixture model'
    # Shell > .env (including an explicitly empty shell value); CLI > shell.
    shell = run([image], {'AIDOKU_TRANSLATION_MODEL': 'shell', 'AIDOKU_TRANSLATION_TARGET': 'ko', 'AIDOKU_IMAGE_JOBS': '2'})
    assert shell['provider']['model'] == 'shell' and shell['targetLanguage'] == 'ko' and shell['jobs'] == 2
    cli = run(['--model', 'cli', '--protocol', 'chatCompletions', '--target', 'ja', '--jobs', '6',
               '--reading-direction', 'topToBottom', '--source', 'auto', image], {'AIDOKU_TRANSLATION_MODEL': 'shell'})
    assert cli['provider']['model'] == 'cli' and cli['provider']['protocol'] == 'chatCompletions'
    assert cli['targetLanguage'] == 'ja' and cli['jobs'] == 6 and cli['readingDirection'] == 'topToBottom'
    assert 'Missing API key' in run([image], {'AIDOKU_TRANSLATION_API_KEY': ''}, expected=2)
    renamed = run(['--key-env', 'OTHER_KEY', image], {'OTHER_KEY': secret})
    assert renamed['provider']['keyEnv'] == 'OTHER_KEY' and renamed['credentialMatchesFixture']
    # Offline modes need no provider settings or key.
    offline = run(['--ocr-only', image], {'AIDOKU_TRANSLATION_BASE_URL': '', 'AIDOKU_TRANSLATION_API_KEY': ''})
    assert offline['mode'] == 'ocr-only' and 'provider' not in offline
    replay = run(['--replay-translations', profile, image], {'AIDOKU_TRANSLATION_MODEL': ''})
    assert replay['mode'] == 'replay' and 'provider' not in replay
    # Validation before any work; messages never carry the value.
    assert 'base-url' in run([image], {'AIDOKU_TRANSLATION_BASE_URL': ''}, expected=2)
    assert 'Unknown option' in run(['--no-include-image', image], expected=2)
    assert 'Unknown option' in run(['--viewport', '430x932', image], expected=2)
    assert 'AIDOKU_TRANSLATION_PROTOCOL' in run([image], {'AIDOKU_TRANSLATION_PROTOCOL': 'smtp'}, expected=2)
    assert 'AIDOKU_IMAGE_JOBS' in run([image], {'AIDOKU_IMAGE_JOBS': '0'}, expected=2)
    assert 'AIDOKU_TRANSLATION_ALLOW_LOCAL_HTTP' in run([image], {'AIDOKU_TRANSLATION_ALLOW_LOCAL_HTTP': 'maybe'}, expected=2)
    assert 'manga recognizer' in run(['--source', 'en', image], expected=2)
    assert 'either --ocr-only or --replay-translations' in run(['--ocr-only', '--replay-translations', profile, image], expected=2)
    run(['--base-url', 'http://example.test/v1', image], expected=2)  # insecure remote endpoint
    run(['--timeout', 'nan', image], expected=2)
    assert not (directory / 'should-not-exist').exists() and not (profile / 'should-not-exist').exists()
    # AIDOKU_ENV_FILE selects another file; empty disables .env entirely.
    other = directory / 'other.env'
    other.write_text("AIDOKU_TRANSLATION_MODEL=other\nAIDOKU_TRANSLATION_BASE_URL=https://other.test/v1\n"
                     f"AIDOKU_TRANSLATION_API_KEY='{secret}'\n")
    assert run([image], {'AIDOKU_ENV_FILE': str(other)})['provider']['model'] == 'other'
    disabled = run(['--ocr-only', image], {'AIDOKU_ENV_FILE': ''})
    assert disabled['sourceLanguage'] == 'auto' and disabled['jobs'] == 3 and disabled['readingDirection'] == 'rightToLeft'
    # Malformed .env: the line number is reported, the value is not.
    (profile / '.env').write_text("AIDOKU_TRANSLATION_API_KEY='unclosed-secret-value\n")
    error = run(['--ocr-only', image], expected=2)
    assert 'line 1' in error and 'unclosed-secret-value' not in error
    (profile / '.env').unlink()
    assert run(['--ocr-only', image])['sourceLanguage'] == 'auto'
    # Inputs: folders, lists, repeated files and page ids.
    folder = profile / 'folder'
    folder.mkdir()
    for name in ['b.png', 'a.jpg', 'notes.txt', '.hidden.png']:
        (folder / name).write_bytes(b'x')
    (profile / 'pages.json').write_text(json.dumps(['folder/a.jpg', {'page_id': 'custom', 'image_path': 'folder/b.png'}]))
    (profile / 'pages.txt').write_text('# comment\nfolder/b.png\n\npage.png\n')
    listed = run(['--ocr-only', folder, '--list', profile / 'pages.json', '--list', profile / 'pages.txt', image])
    assert [item['pageID'] for item in listed['images']] == ['a', 'b', 'page'], listed['images']
    duplicates = run(['--ocr-only', image, profile / 'folder/../page.png', folder / 'a.jpg', '--', profile / 'pages.json'])
    assert [item['pageID'] for item in duplicates['images']] == ['page', 'a', 'pages'], duplicates['images']
    assert run(['--ocr-only', '--limit', '1', folder])['images'] == [{'pageID': 'a', 'path': str(folder / 'a.jpg')}]
    assert 'does not exist' in run(['--ocr-only', profile / 'missing.png'], expected=2)

# The phone import keeps only settings the V2 host reads and never touches the key.
profile = runpy.run_path(str(ROOT / 'Scripts/image-translation/sync-iphone-settings.py'))['profile']
imported = profile({
    'Reader.translation.provider': 'custom',
    'Reader.translation.custom': {'baseURL': 'https://example.test/v1', 'model': 'fixture', 'apiProtocol': 'responses',
                                  'reasoningEffort': 'none'},
    'Reader.translation.concurrency': 16, 'Reader.translation.sourceLanguage': 'ja',
    'Reader.translation.ocr': {'detectorMaximumSide': 960}, 'Reader.translation.overlay': {},
})
assert imported['AIDOKU_TRANSLATION_BASE_URL'] == 'https://example.test/v1' and imported['AIDOKU_TRANSLATION_MODEL'] == 'fixture'
assert imported['AIDOKU_TRANSLATION_PROTOCOL'] == 'responses' and imported['AIDOKU_TRANSLATION_REASONING'] == 'none'
assert imported['AIDOKU_TRANSLATION_CONCURRENCY'] == 3 and imported['AIDOKU_TRANSLATION_SOURCE'] == 'ja'
assert not any(key.startswith(('AIDOKU_OCR_', 'AIDOKU_IPHONE_OVERLAY')) or 'API_KEY' in key for key in imported), imported

# .env stays out of Git; .env.example carries no credential.
ignore = (ROOT / '.gitignore').read_text().splitlines()
assert '.env' in ignore or '/.env' in ignore, 'the repository .gitignore must exclude .env'
example = (ROOT / '.env.example').read_text()
assert all(line.split('=', 1)[1].strip() in ('', "''", '""') for line in example.splitlines()
           if line.startswith('AIDOKU_TRANSLATION_API_KEY='))
print('PASS: dotenv parsing, AIDOKU_ENV_FILE, cwd independence, .env < shell < CLI precedence, provider cap, '
      'offline modes, validation without secret output, input lists/dedup, phone import, .env exclusion')
