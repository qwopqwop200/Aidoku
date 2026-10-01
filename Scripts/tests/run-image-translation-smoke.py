#!/usr/bin/env python3
"""Focused opt-in native host smoke: real OCR, HTTP codec, render, lists and failures.

Run: python3 Scripts/tests/run-image-translation-smoke.py
No external provider or API key is used; the mock server binds only to loopback.
"""
import base64
import http.server
import json
import os
import re
from pathlib import Path
import shutil
import sys
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'Scripts/image-translation.swift'
FIXTURE = ROOT / 'AidokuTests/Translation/Fixtures/VerticalSingleGlyphBalloon.png'
SECRET = 'image-translation-smoke-secret'
requests = []
parallel_probe = False
active_requests = 0
peak_requests = 0
request_lock = threading.Lock()
overlap = threading.Event()
# Run all cases against one compiled snapshot while other chats may edit app sources.
use_binary = '--reuse-built' in sys.argv
BINARY = ROOT / 'build/image-translation-host/image-translation'


class Provider(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-vLLM-Version', '0.11.0')
        response = b'{"data": [{"id": "smoke-fixture"}]}'
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def do_POST(self):
        global active_requests, peak_requests
        if parallel_probe:
            with request_lock:
                active_requests += 1
                peak_requests = max(peak_requests, active_requests)
                if active_requests >= 2: overlap.set()
            overlap.wait(4)
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.headers['Authorization'] == f'Bearer {SECRET}'
        if 'structured_outputs' in body:
            ids = [key.replace(r'\.', '.') for key in re.findall(r'"id":"([^"]+)"', body['structured_outputs']['regex'])]
        else:
            schema = body['response_format']['json_schema']['schema']
            ids = schema['properties']['translations']['items']['properties']['id']['enum']
        assert ids, body
        requests.append(body)
        content = json.dumps({'translations': [{'id': key, 'text': '어서! 빨리 움직여!'} for key in ids]}, ensure_ascii=False)
        if body.get('stream'):
            chunk = {'choices': [{'index': 0, 'delta': {'content': content}, 'finish_reason': None}]}
            terminal = {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}
            response = (f'data: {json.dumps(chunk, ensure_ascii=False)}\n\n'
                        f'data: {json.dumps(terminal)}\n\ndata: [DONE]\n\n').encode()
        else:
            response = json.dumps({'choices': [{'index': 0, 'finish_reason': 'stop', 'message': {'content': content}}]}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream' if body.get('stream') else 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)
        if parallel_probe:
            with request_lock: active_requests -= 1

    def log_message(self, *args):
        pass


def run(arguments, expected=0):
    global use_binary
    command = [str(BINARY)] if use_binary else ['swift', str(ENTRY)]
    environment = {key: value for key, value in os.environ.items() if not key.startswith('AIDOKU_')}
    # Override every persisted option so a developer's ignored phone profile
    # cannot change this test's model, endpoint, geometry, filters or credentials.
    environment.update({
        'AIDOKU_PIPELINE_ROOT': str(ROOT), 'AIDOKU_TRANSLATION_API_KEY': SECRET,
        'AIDOKU_TRANSLATION_KEY_ENV': 'AIDOKU_TRANSLATION_API_KEY',
        'AIDOKU_TRANSLATION_BASE_URL': '', 'AIDOKU_TRANSLATION_MODEL': '',
        'AIDOKU_TRANSLATION_PROTOCOL': 'chatCompletions',
        'AIDOKU_TRANSLATION_SOURCE': 'ja', 'AIDOKU_TRANSLATION_TARGET': 'ko',
        'AIDOKU_TRANSLATION_REASONING': 'modelDefault', 'AIDOKU_TRANSLATION_TIMEOUT': '60',
        'AIDOKU_TRANSLATION_SOURCE_LANGUAGES': '[]', 'AIDOKU_TRANSLATION_ALLOW_LOCAL_HTTP': 'false',
        'AIDOKU_TRANSLATION_INCLUDE_IMAGE': 'false', 'AIDOKU_TRANSLATION_FILTER_SFX': 'false',
        'AIDOKU_TRANSLATION_FILTER_BACKGROUND': 'false', 'AIDOKU_TRANSLATION_RTL': 'false',
        'AIDOKU_OCR_TIER': 'medium', 'AIDOKU_OCR_CONFIDENCE': '0.75',
        'AIDOKU_OCR_DETECTOR_SIDE': '1184', 'AIDOKU_OCR_RECOGNIZER_WIDTH': '1184',
        'AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD': '0.3', 'AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD': '0.3',
        'AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE': '3', 'AIDOKU_RENDER_VIEWPORT': '430x932', 'AIDOKU_IMAGE_JOBS': '2',
        'AIDOKU_IPHONE_OVERLAY_JSON': json.dumps({'visible': True, 'opacity': 1,
            'preserveSourceTextColor': True, 'preserveSourceBackgroundColor': True, 'inpaintingEnabled': True}),
    })
    fingerprint = ROOT / 'build/image-translation-host/fingerprint'
    if fingerprint.exists():
        environment['AIDOKU_PIPELINE_FINGERPRINT'] = fingerprint.read_text()
    result = subprocess.run([*command, *map(str, arguments)], cwd=ROOT,
                            env=environment, capture_output=True, text=True)
    assert result.returncode == expected, result.stdout + result.stderr
    assert SECRET not in result.stdout + result.stderr
    use_binary = True
    return result


def latest_summary(output):
    runs = list(output.glob('run-*'))
    assert len(runs) == 1, runs
    return runs[0], json.loads((runs[0] / 'summary.json').read_text())


with tempfile.TemporaryDirectory(prefix='aidoku image pipeline ') as temporary:
    directory = Path(temporary)
    first = directory / 'first/page.png'
    second = directory / 'second/page.png'
    first.parent.mkdir()
    second.parent.mkdir()
    shutil.copyfile(FIXTURE, first)
    shutil.copyfile(FIXTURE, second)
    (directory / 'broken.png').write_bytes(b'invalid image data')
    # Same basename, spaces in parent path, relative list paths and canonical deduplication.
    (directory / 'images.json').write_text(json.dumps(['first/page.png', 'second/page.png', 'first/page.png']))
    output = directory / 'ocr output'
    run(['--list', directory / 'images.json', '--ocr-only', '--quiet', '--output', output])
    run_dir, summary = latest_summary(output)
    assert len(summary) == 2 and all(row['status'] == 'success' for row in summary), summary
    run(['--resume-run', run_dir, '--list', directory / 'images.json', '--ocr-only', '--quiet'])
    resumed = json.loads((run_dir / 'summary.json').read_text())
    assert len(resumed) == 2 and all(row.get('resumed') for row in resumed), resumed
    final = json.loads((run_dir / '0001/final.json').read_text())
    assert any('早く' in region['source'] for region in final['regions']), final
    runtime = json.loads(next((run_dir / '0001').glob('*runtime-settings.json')).read_text())['value']
    assert runtime['ocr']['detectorMaximumSide'] == 1184 and runtime['ocr']['recognizerMaximumWidth'] == 1184
    assert list((run_dir / '0001').glob('*detector-output.json'))
    assert list((run_dir / '0001').glob('*native-ocr.json'))
    assert (run_dir / 'analysis-index.html').exists()
    assert (run_dir / '0001/analysis.html').exists()
    analysis = json.loads((run_dir / '0001/analysis.json').read_text())
    assert analysis['stages'] and analysis['maps']
    assert all((run_dir / '0001' / item['raw']).stat().st_size == item['width'] * item['height'] * 4 for item in analysis['maps'])
    replay = directory / 'replay.json'
    replay.write_text(json.dumps({region['source']: '어서! 빨리 움직여!' for region in final['regions']}, ensure_ascii=False))
    replay_output = directory / 'replay output'
    run(['--translations', replay, '--quiet', '--output', replay_output, first])
    replay_dir, summary = latest_summary(replay_output)
    assert (replay_dir / '0001/final.png').stat().st_size > 100
    assert (replay_dir / '0001/final.html').exists()
    analysis = json.loads((replay_dir / '0001/analysis.json').read_text())
    assert analysis['finalImage'] == 'final.png' and analysis['segmentation']
    assert any(trace['captures'] for trace in analysis['segmentation']), 'Actual renderer segmentation paths must be exercised'
    diagnostics = json.loads(next((replay_dir / '0001').glob('*native-render-diagnostics.json')).read_text())['value']
    assert 'cards' in diagnostics and not diagnostics['initialPatchCaptureFailures'], diagnostics
    render_result = json.loads(next((replay_dir / '0001').glob('*render-result.json')).read_text())['value']
    assert render_result['engine'] == 'native-coretext-coregraphics'
    assert render_result['renderedItemCount'] > 0 and render_result['layoutVersion'] > 0
    assert not list((replay_dir / '0001').glob('*render-dom.json'))
    assert (replay_dir / '0001/final-typography.pdf').read_bytes().startswith(b'%PDF-')
    assert (replay_dir / '0001/final-layers.json').exists()
    assert (replay_dir / '0001/native-layout.json').exists()
    final_html = (replay_dir / '0001/final.html').read_text()
    assert 'data:image/png;base64,' in final_html and '<script' not in final_html.lower()
    embedded_png = re.search(r'src="data:image/png;base64,([A-Za-z0-9+/=]+)"', final_html).group(1)
    assert base64.b64decode(embedded_png, validate=True) == (replay_dir / '0001/final.png').read_bytes()
    for trace in analysis['segmentation']:
        assert trace['engine'] == 'native-coretext-coregraphics' and not trace['captureFailures']
        assert len(trace['captures']) <= 64
        for capture in trace['captures']:
            assert capture['function'] == 'NativeTranslationRestoration'
            assert capture['kind'] == 'native-repair-alpha' and capture['status'] == 'captured'
            assert 0 <= capture['selectedPixels'] <= capture['width'] * capture['height']
            for field in ['source', 'mask', 'overlay']:
                if field in capture: assert (replay_dir / '0001' / capture[field]).stat().st_size > 50
    translated = json.loads((replay_dir / '0001/final.json').read_text())
    assert all(region['translation'] == '어서! 빨리 움직여!' for region in translated['regions'])
    assert translated['renderEngine'] == 'native-coretext-coregraphics'
    # Native payload replay uses the direct patch path and retains saved OCR/translations.
    native_ocr_before = {file.name: file.read_bytes() for file in (replay_dir / '0001').glob('*native-ocr.json')}
    saved_payload = next((replay_dir / '0001').glob('*render-payload.json'))
    latest_payload = replay_dir / '0001/1000-render-payload.json'
    latest_payload.write_bytes(saved_payload.read_bytes())
    stale_payload = replay_dir / '0001/999-render-payload.json'
    stale_payload.write_text(json.dumps({'stage': 'render-payload', 'value': {'hostViewport': []}}))
    run(['--render-run', replay_dir])
    assert json.loads((replay_dir / '0001/final.json').read_text())['regions'] == translated['regions']
    assert {file.name: file.read_bytes() for file in (replay_dir / '0001').glob('*native-ocr.json')} == native_ocr_before
    replay_html = (replay_dir / '0001/final.html').read_text()
    replay_png = re.search(r'src="data:image/png;base64,([A-Za-z0-9+/=]+)"', replay_html).group(1)
    assert base64.b64decode(replay_png, validate=True) == (replay_dir / '0001/final.png').read_bytes()
    # Completed browser-era runs must recompose through native code when resumed,
    # while retaining OCR and user translations without any provider request.
    saved_payload = latest_payload
    legacy_payload = json.loads(saved_payload.read_text())
    for key in ['nativeLayout', 'nativeSettings', 'hostRenderer']:
        legacy_payload['value'].pop(key, None)
    saved_payload.write_text(json.dumps(legacy_payload, ensure_ascii=False))
    translated.pop('renderEngine')
    (replay_dir / '0001/final.json').write_text(json.dumps(translated, ensure_ascii=False))
    ocr_before = {file.name: file.read_bytes() for file in (replay_dir / '0001').glob('*native-ocr.json')}
    (replay_dir / '0001/final.png').unlink()
    run(['--resume-run', replay_dir, '--translations', replay, '--quiet', first])
    migrated = json.loads((replay_dir / '0001/final.json').read_text())
    assert migrated['renderEngine'] == 'native-coretext-coregraphics'
    assert migrated['regions'] == translated['regions']
    assert (replay_dir / '0001/final.png').stat().st_size > 100
    assert {file.name: file.read_bytes() for file in (replay_dir / '0001').glob('*native-ocr.json')} == ocr_before
    assert all(row.get('resumed') for row in json.loads((replay_dir / 'summary.json').read_text()))
    # Real production client + codec/transport against a loopback mock.
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        remote_output = directory / 'remote output'
        run(['--quiet', '--output', remote_output, '--base-url', f'http://127.0.0.1:{server.server_port}/v1',
             '--model', 'smoke-fixture', '--protocol', 'chatCompletions', '--no-filter-sfx', '--no-filter-background', '--allow-local-http', '--source', 'ja', '--include-image', first])
        remote_dir, summary = latest_summary(remote_output)
        assert requests and requests[0].get('stream'), 'No streaming provider request executed'
        assert list((remote_dir / '0001').glob('*translation-partial.json')), 'Streaming publications were not captured'
        assert (remote_dir / '0001/final.png').exists()
        assert list((remote_dir / '0001').glob('*http-request.json'))
        assert list((remote_dir / '0001').glob('*http-response.json'))
        for file in remote_dir.rglob('*.json'):
            assert SECRET not in file.read_text(), file
        parallel_probe = True
        parallel_output = directory / 'parallel output'
        run(['--jobs', '2', '--quiet', '--output', parallel_output, '--base-url', f'http://127.0.0.1:{server.server_port}/v1',
             '--model', 'smoke-fixture', '--protocol', 'chatCompletions', '--no-filter-sfx', '--no-filter-background',
             '--allow-local-http', first, second])
        parallel_dir, summary = latest_summary(parallel_output)
        assert peak_requests == 2, f'Translation did not overlap: peak={peak_requests}'
        assert len(summary) == 2 and all(row['status'] == 'success' for row in summary), summary
        assert [Path(row['input']).parent.name for row in summary] == ['first', 'second']
        assert all((parallel_dir / f'{index:04d}/final.png').exists() for index in [1, 2])
        assert len(list((parallel_dir / 'final').glob('*.png'))) == 2
        parallel_probe = False

    finally:
        server.shutdown()
        server.server_close()
    # A decode failure does not prevent the next valid image from completing.
    mixed_output = directory / 'mixed output'
    run(['--ocr-only', '--quiet', '--output', mixed_output, directory / 'broken.png', first], expected=1)
    _, summary = latest_summary(mixed_output)
    assert [row['status'] for row in summary] == ['failed', 'success'], summary
    nested_output = directory / 'nested output'
    run(['--ocr-only', '--quiet', '--recursive', '--limit', '1', '--output', nested_output, directory / 'first'])
    _, summary = latest_summary(nested_output)
    assert len(summary) == 1
    run(['--ocr-only', '--confidence', 'nan', first], expected=2)
    run(['--ocr-only', directory / 'missing.png'], expected=2)
    run(['--base-url', 'http://example.org/v1', '--model', 'fixture', first], expected=2)
print('PASS: native OCR, offline render, concurrent provider requests, stable ordering, inputs/resume/failures and credential exclusion')
