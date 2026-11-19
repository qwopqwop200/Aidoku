#!/usr/bin/env python3
"""Copy the installed app's provider/language settings from iPhone into the local ignored .env.
The existing API key stays in .env; Keychain is never read or modified. The V2 host
(swift Scripts/image-translation.swift) reads these values; V2 has no OCR or overlay settings.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PREFIX = 'Reader.translation.'
MAXIMUM_PROVIDER_CONCURRENCY = 3  # The app caps image-attached page calls at three.
# Keys written by earlier versions for the removed legacy host; dropped on sync.
RETIRED = ('AIDOKU_OCR_', 'AIDOKU_IPHONE_OVERLAY_JSON', 'AIDOKU_IPHONE_SCHEDULING_JSON', 'AIDOKU_TRANSLATION_RTL',
           'AIDOKU_TRANSLATION_INCLUDE_IMAGE', 'AIDOKU_TRANSLATION_FILTER_', 'AIDOKU_RENDER_VIEWPORT')


def profile(prefs):
    """Provider and language settings the V2 host reads (Scripts/image-translation-v2/V2HostSettings.swift)."""
    def get(name, default=None):
        value = prefs.get(PREFIX + name, default)
        return json.loads(value) if isinstance(value, bytes) else value
    if get('provider') != 'custom':
        raise ValueError('Expected the installed custom-server profile; refusing to guess credentials/provider.')
    custom = get('custom')
    if not isinstance(custom, dict):
        raise ValueError('Installed app preferences are missing the custom provider settings.')
    reasoning = custom.get('reasoningEffort', 'modelDefault')
    return {
        'AIDOKU_TRANSLATION_BASE_URL': custom['baseURL'],
        'AIDOKU_TRANSLATION_MODEL': custom['model'],
        'AIDOKU_TRANSLATION_PROTOCOL': custom['apiProtocol'],
        'AIDOKU_TRANSLATION_REASONING': reasoning,
        'AIDOKU_TRANSLATION_TIMEOUT': 120 if reasoning == 'none' else 300,
        'AIDOKU_TRANSLATION_SOURCE': get('sourceLanguage', 'auto'),
        'AIDOKU_TRANSLATION_TARGET': get('targetLanguage', 'ko'),
        'AIDOKU_TRANSLATION_CONCURRENCY': min(MAXIMUM_PROVIDER_CONCURRENCY, max(1, int(get('concurrency', 3)))),
        'AIDOKU_IPHONE_CAPTURED_AT': datetime.now(timezone.utc).isoformat(),
    }


def literal(value):
    if isinstance(value, (dict, list)):
        return "'" + json.dumps(value, ensure_ascii=False, separators=(',', ':')) + "'"
    if isinstance(value, bool): return str(value).lower()
    if isinstance(value, float): return format(value, '.12g')
    text = str(value)
    if any(character in text for character in "\r\n'\""):
        raise ValueError('Unsupported dotenv literal in installed preferences; no values were written.')
    return text


def write_env(path, values):
    lines = path.read_text().splitlines() if path.exists() else []
    pending = dict(values)
    output = []
    for line in lines:
        key = line.split('=', 1)[0].strip()
        if key.startswith(RETIRED):
            continue
        if key in values:
            if key in pending: output.append(key + '=' + literal(pending.pop(key)))
        else: output.append(line)
    output += [key + '=' + literal(value) for key, value in pending.items()]
    temporary = path.with_name('.env.sync-tmp')
    temporary.touch(mode=0o600, exist_ok=False)
    try:
        temporary.write_text('\n'.join(output) + '\n')
        temporary.replace(path)
        path.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--bundle-id', default='dev.junjae.Aidoku')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='aidoku-phone-settings-') as temporary:
        source = Path(temporary) / 'preferences.plist'
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
            '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle_id,
            '--source', f'Library/Preferences/{args.bundle_id}.plist', '--destination', str(source), '--quiet'], check=True)
        values = profile(plistlib.loads(source.read_bytes()))
    values['AIDOKU_IPHONE_DEVICE'] = args.device
    values['AIDOKU_IPHONE_BUNDLE_ID'] = args.bundle_id
    write_env(ROOT / '.env', values)
    print('Imported installed iPhone provider settings into .env; existing API key preserved.')


if __name__ == '__main__':
    main()
