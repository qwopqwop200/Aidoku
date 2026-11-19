#!/usr/bin/env python3
"""V2 host smoke: real Core ML OCR, live provider request shape through the production
RemoteTranslationClient against a loopback mock, ordering, replay, OCR-only, failures,
output files and credential exclusion.

Run: python3 Scripts/tests/run-image-translation-smoke.py
No external provider or real API key is used; the mock server binds only to loopback.
The developer's .env is never read (AIDOKU_ENV_FILE is set empty).
"""
import base64
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'Scripts/image-translation.swift'
FIXTURE = ROOT / 'Scripts/tests/fixtures/v2-host/VerticalSingleGlyphBalloon.png'
SECRET = 'image-translation-smoke-secret'
TRANSLATION = '어서! 빨리 움직여!'
requests = []
request_lock = threading.Lock()
parallel_probe = False
active_requests = 0
peak_requests = 0
overlap = threading.Event()


def requested_ids(body):
    """Segment ids from the structured-output schema the production codec sent."""
    if 'structured_outputs' in body:
        pattern = body['structured_outputs']['regex']
        return [key.replace(r'\.', '.') for key in re.findall(r'"id":"([^"]+)"', pattern)], set()
    schema = body['response_format']['json_schema']['schema']
    item = schema['properties']['translations']['items']
    branch = item.get('anyOf', [item])[0]
    definition = branch['properties']['id']
    if '$ref' in definition:
        definition = schema
        for component in branch['properties']['id']['$ref'][2:].split('/'):
            definition = definition[component]
    return definition['enum'], set(branch['required'])


def user_content(body):
    for message in body['messages']:
        if message['role'] == 'user':
            return message['content']
    raise AssertionError('no user message')


class Provider(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        response = b'{"data": [{"id": "smoke-fixture"}]}'
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def do_POST(self):
        global active_requests, peak_requests
        if parallel_probe:
            with request_lock:
                active_requests += 1
                peak_requests = max(peak_requests, active_requests)
                if active_requests >= 2:
                    overlap.set()
            overlap.wait(4)
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.headers['Authorization'] == f'Bearer {SECRET}'
        with request_lock:
            requests.append(body)
        ids, required = requested_ids(body)
        assert ids, body
        translations = [{'id': key, **({'text_role': 'dialogue'} if 'text_role' in required else {}),
                         'text': TRANSLATION} for key in ids]
        content = json.dumps({'translations': translations}, ensure_ascii=False, separators=(',', ':'))
        response = json.dumps({'choices': [{'index': 0, 'finish_reason': 'stop',
                                            'message': {'content': content}}]}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)
        if parallel_probe:
            with request_lock:
                active_requests -= 1

    def log_message(self, *args):
        pass


def run(arguments, expected=0, extra=None):
    environment = {key: value for key, value in os.environ.items() if not key.startswith('AIDOKU_')}
    environment.update({'AIDOKU_ENV_FILE': '', 'AIDOKU_TRANSLATION_API_KEY': SECRET, **(extra or {})})
    result = subprocess.run(['swift', str(ENTRY), *map(str, arguments)], cwd=ROOT, env=environment,
                            capture_output=True, text=True)
    assert result.returncode == expected, f'exit {result.returncode}\n{result.stdout}{result.stderr}'
    assert SECRET not in result.stdout + result.stderr
    return result


def summary(output):
    value = json.loads((output / 'summary.json').read_text())
    assert value['schema'] == 'aidoku-v2-run-summary-v2', value
    assert value['pages'] == len(value['pageResults'])
    for row in value['pageResults']:
        assert (output / row['json']).exists(), row
    return value


def page(output, page_id):
    return json.loads((output / 'pages' / f'{page_id}.json').read_text())


def assert_no_secret(directory):
    for file in directory.rglob('*'):
        if file.is_file():
            assert SECRET.encode() not in file.read_bytes(), file


with tempfile.TemporaryDirectory(prefix='aidoku image pipeline ') as temporary:
    directory = Path(temporary)
    first = directory / 'first/page.png'
    second = directory / 'second/page.png'
    for path in (first, second):
        path.parent.mkdir()
        shutil.copyfile(FIXTURE, path)
    (directory / 'broken.png').write_bytes(b'invalid image data')
    # Same basename, spaces in the parent path, relative list paths and canonical deduplication.
    (directory / 'images.json').write_text(json.dumps(['first/page.png', 'second/page.png', 'first/page.png']))

    # OCR-only: S1-S4, recognized blocks, no PNG, no provider settings needed.
    ocr_output = directory / 'ocr output'
    run(['--ocr-only', '--list', directory / 'images.json', '--output', ocr_output],
        extra={'AIDOKU_TRANSLATION_API_KEY': ''})
    ocr = summary(ocr_output)
    assert ocr['mode'] == 'ocr-only' and [row['pageID'] for row in ocr['pageResults']] == ['page', 'page-2'], ocr
    assert all(row['status'] == 'success' and 'png' not in row for row in ocr['pageResults']), ocr
    assert not list((ocr_output / 'pages').glob('*.png'))
    recognized = page(ocr_output, 'page')
    assert recognized['mode'] == 'ocr-only' and recognized['placed'] == []
    assert any('早く' in block['sourceText'] for block in recognized['blocks']), recognized['blocks']
    assert all(block.get('translation') is None for block in recognized['blocks'])
    assert all(line['text'] for block in recognized['blocks'] for line in block['lines'])
    assert not any(stage in recognized['timings'] for stage in ('s6_mask', 's7_inpaint', 's10_paint')), recognized['timings']
    assert 'provider' not in ocr

    # Live: the real client/codec against the loopback mock, mandatory page settings.
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f'http://127.0.0.1:{server.server_port}/v1'
    provider = ['--base-url', base_url, '--model', 'smoke-fixture', '--protocol', 'chatCompletions',
                '--allow-local-http', '--source', 'ja', '--target', 'ko']
    try:
        live_output = directory / 'live output'
        run([*provider, '--output', live_output, first])
        live = summary(live_output)
        assert live['mode'] == 'live' and live['failedPages'] == [], live
        assert live['provider']['keyPresent'] is True and live['provider']['model'] == 'smoke-fixture'
        assert live['provider']['includePageImage'] and live['provider']['filterSFX'] and live['provider']['filterBackground']
        assert len(requests) == 1, len(requests)
        body = requests[0]
        assert body['model'] == 'smoke-fixture' and not body.get('stream'), body.keys()
        content = user_content(body)
        images = [part for part in content if isinstance(part, dict) and part.get('type') == 'image_url']
        assert len(images) == 1, 'the page image is mandatory'
        jpeg = base64.b64decode(images[0]['image_url']['url'].split(',', 1)[1])
        assert jpeg.startswith(b'\xff\xd8'), 'page image must be a JPEG'
        ids, required = requested_ids(body)
        assert ids == ['v2-block-0'] or all(key.startswith('v2-block-') for key in ids), ids
        assert 'text_role' in required, 'SFX/background filtering must request text roles'
        text = json.dumps(body, ensure_ascii=False)
        assert '早く' in text, 'recognized source text is sent'
        translated = page(live_output, 'page')
        painted = [block for block in translated['blocks'] if block.get('translation')]
        assert painted and all(block['translation'] == TRANSLATION for block in painted), translated['blocks']
        assert translated['placed'], 'translated blocks are placed and painted'
        png = live_output / 'pages/page.png'
        assert png.read_bytes().startswith(b'\x89PNG') and png.stat().st_size > 100
        assert live['pageResults'][0]['png'] == 'pages/page.png'
        assert_no_secret(live_output)

        # Pages overlap their provider calls and results stay in input order.
        parallel_probe = True
        parallel_output = directory / 'parallel output'
        run([*provider, '--jobs', '2', '--output', parallel_output, '--list', directory / 'images.json'])
        parallel_probe = False
        assert peak_requests == 2, f'Translation did not overlap: peak={peak_requests}'
        parallel = summary(parallel_output)
        assert [row['image'] for row in parallel['pageResults']] == [str(first), str(second)], parallel['pageResults']
        assert all(row['status'] == 'success' and row['png'] for row in parallel['pageResults'])
        assert_no_secret(parallel_output)

        # Replay from the live V2 run: no provider call, same translations.
        before = len(requests)
        replay_output = directory / 'replay output'
        run(['--replay-translations', live_output, '--output', replay_output, first],
            extra={'AIDOKU_TRANSLATION_API_KEY': ''})
        assert len(requests) == before, 'replay must not call the provider'
        replay = summary(replay_output)
        assert replay['mode'] == 'replay' and 'provider' not in replay
        replayed = page(replay_output, 'page')
        assert replayed['replayAvailable'] is True and replayed['replayMatched'] >= 1, replayed
        assert [block.get('translation') for block in replayed['blocks']] == \
            [block.get('translation') for block in translated['blocks']]
        assert (replay_output / 'pages/page.png').exists()

        # `--pipeline v2` is a no-op alias; settings precedence is CLI > shell.
        settings = json.loads(run(['--pipeline', 'v2', *provider, '--model', 'cli-model', '--print-settings', first],
                                  extra={'AIDOKU_TRANSLATION_MODEL': 'shell-model'}).stdout)
        assert settings['provider']['model'] == 'cli-model' and settings['mode'] == 'live', settings
    finally:
        server.shutdown()
        server.server_close()

    # A decode failure does not stop the next page; the run exits 1 and records it.
    mixed_output = directory / 'mixed output'
    run(['--ocr-only', '--output', mixed_output, directory / 'broken.png', first], expected=1)
    mixed = summary(mixed_output)
    assert [row['status'] for row in mixed['pageResults']] == ['failed', 'success'], mixed
    assert mixed['pageResults'][0]['failure'].startswith('load:') and mixed['failedPages'] == ['broken']

    # Invalid settings fail before model loading (exit 2) and never echo the key.
    run([first], expected=2)  # live without --base-url/--model
    run(['--base-url', 'http://example.org/v1', '--model', 'fixture', first], expected=2)  # insecure remote HTTP
    run(['--base-url', base_url, '--model', 'fixture', '--allow-local-http', first], expected=2,
        extra={'AIDOKU_TRANSLATION_API_KEY': ''})  # missing key
    run(['--ocr-only', '--source', 'en', first], expected=2)
    run(['--ocr-only', '--replay-translations', live_output, first], expected=2)
    run(['--ocr-only', directory / 'missing.png'], expected=2)
    run(['--pipeline', 'legacy', first], expected=2)
print('PASS: V2 OCR-only blocks, live provider request shape (image, roles, ids), overlap and input ordering, '
      'V2-run replay without provider calls, output files, failures and credential exclusion')
