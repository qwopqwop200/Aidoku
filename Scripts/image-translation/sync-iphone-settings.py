#!/usr/bin/env python3
"""Copy installed Aidoku preferences from iPhone into the local ignored .env.
The existing API key stays in .env; Keychain is never read or modified.
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


def profile(prefs):
    def get(name, default=None):
        value = prefs.get(PREFIX + name, default)
        return json.loads(value) if isinstance(value, bytes) else value
    if get('provider') != 'custom':
        raise ValueError('Expected the installed custom-server profile; refusing to guess credentials/provider.')
    custom = get('custom'); ocr = get('ocr'); overlay = get('overlay')
    if not all(isinstance(value, dict) for value in [custom, ocr, overlay]):
        raise ValueError('Installed app preferences are missing custom/OCR/overlay settings.')
    values = {
        'AIDOKU_IMAGE_JOBS': get('concurrency', 16),
        'AIDOKU_TRANSLATION_BASE_URL': custom['baseURL'],
        'AIDOKU_TRANSLATION_MODEL': custom['model'],
        'AIDOKU_TRANSLATION_PROTOCOL': custom['apiProtocol'],
        'AIDOKU_TRANSLATION_REASONING': custom.get('reasoningEffort', 'modelDefault'),
        'AIDOKU_TRANSLATION_TIMEOUT': 120 if custom.get('reasoningEffort') == 'none' else 300,
        'AIDOKU_TRANSLATION_SOURCE': get('sourceLanguage', 'auto'),
        'AIDOKU_TRANSLATION_TARGET': get('targetLanguage', 'ko'),
        'AIDOKU_TRANSLATION_SOURCE_LANGUAGES': get('translationSourceLanguages', []),
        'AIDOKU_TRANSLATION_INCLUDE_IMAGE': get('includePageImage', False),
        'AIDOKU_TRANSLATION_FILTER_SFX': get('filterSFXWithLLM', False),
        'AIDOKU_TRANSLATION_FILTER_BACKGROUND': get('filterBackgroundWithLLM', False),
        # The app does not currently persist/load a panel-order preference.
        'AIDOKU_TRANSLATION_RTL': False,
        'AIDOKU_OCR_TIER': ocr.get('modelTier', get('modelTier', 'medium')),
        'AIDOKU_OCR_CONFIDENCE': ocr['confidenceThreshold'],
        'AIDOKU_OCR_DETECTOR_SIDE': ocr['detectorMaximumSide'],
        'AIDOKU_OCR_RECOGNIZER_WIDTH': ocr['recognizerMaximumWidth'],
        'AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD': ocr.get('detectorPixelThreshold', .3),
        'AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD': ocr.get('detectorConfidenceThreshold', .6),
        'AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE': ocr.get('detectorMinimumBoxSide', 3),
        'AIDOKU_IPHONE_OVERLAY_JSON': overlay,
        # Retain app scheduling/cache preferences as provenance. CLI uses concurrency above; chapter/cache scheduling stays app-only.
        'AIDOKU_IPHONE_SCHEDULING_JSON': {
            'concurrency': get('concurrency', 16), 'automatic': get('automatic', True),
            'background': get('background', False), 'pretranslationLimit': get('pretranslationLimit'),
            'cacheLimitBytes': get('cacheLimitBytes')},
        'AIDOKU_IPHONE_CAPTURED_AT': datetime.now(timezone.utc).isoformat(),
    }
    return values


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
    print('Imported installed iPhone preferences into .env; existing API key preserved.')


if __name__ == '__main__':
    main()
