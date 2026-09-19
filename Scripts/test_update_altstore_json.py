"""Offline regression tests for release-source generation."""
import io
import json
import plistlib
import tempfile
import zipfile
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, Mock, patch

# The workflow installs requests; offline unit tests need no third-party package.
spec = importlib.util.spec_from_file_location(
    'altstore_updater', Path(__file__).resolve().parents[1] /
    '.github/workflows/supporting/update_altstore_json.py')
updater = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'requests': SimpleNamespace(get=Mock(), RequestException=Exception)}):
    spec.loader.exec_module(updater)


class AltStoreReleaseTests(unittest.TestCase):
    def test_unpublished_draft_does_not_break_stable_selection(self):
        stable = {'draft': False, 'prerelease': False, 'published_at': '2026-09-01T00:00:00Z'}
        response = Mock()
        response.json.return_value = [
            {'draft': True, 'prerelease': False, 'published_at': None},
            {'draft': False, 'prerelease': True, 'published_at': '2026-09-19T00:00:00Z'},
            stable,
        ]
        with patch.object(updater.requests, 'get', return_value=response) as get:
            self.assertEqual(updater.fetch_latest_release('owner/repo'), stable)
        self.assertEqual(get.call_args.kwargs['timeout'], (10, 60))

    def test_no_stable_release_fails_explicitly(self):
        response = Mock()
        response.json.return_value = [{'draft': True, 'prerelease': False, 'published_at': None}]
        with patch.object(updater.requests, 'get', return_value=response):
            with self.assertRaises(ValueError):
                updater.fetch_latest_release('owner/repo')

    def test_streamed_ipa_update_and_failed_replacement_preserve_json(self):
        ipa = io.BytesIO()
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('Payload/Aidoku.app/Info.plist', plistlib.dumps({
                'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '4'}))
        release = {'tag_name': 'v1.2.3', 'published_at': '2026-09-01T00:00:00Z', 'body': None,
                   'assets': [{'name': 'app.ipa', 'browser_download_url': 'https://example.test/app.ipa', 'size': 123}]}
        response = MagicMock()
        response.__enter__.return_value = response
        response.iter_content.return_value = [ipa.getvalue()]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'apps.json'
            original = '{"apps": [{"versions": []}]}'
            source.write_text(original)
            with patch.object(updater, 'fetch_latest_release', return_value=release), \
                 patch.object(updater.requests, 'get', return_value=response) as get:
                with patch.object(updater.os, 'replace', side_effect=OSError('disk unavailable')):
                    with self.assertRaises(OSError):
                        updater.update_json_file(str(source), 'owner/repo')
                self.assertEqual(source.read_text(), original)
                self.assertEqual(list(Path(directory).iterdir()), [source])
                updater.update_json_file(str(source), 'owner/repo')
                self.assertTrue(get.call_args.kwargs['stream'])
                self.assertEqual(get.call_args.kwargs['timeout'], (10, 60))
            version = json.loads(source.read_text())['apps'][0]['versions'][0]
            self.assertEqual((version['version'], version['buildVersion']), ('1.2.3', '4'))
            self.assertEqual(version['localizedDescription'], '')

    def test_same_version_new_build_is_published_and_duplicate_is_idempotent(self):
        ipa = io.BytesIO()
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('Payload/Aidoku.app/Info.plist', plistlib.dumps({
                'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '5'}))
        release = {'published_at': '2026-09-01T00:00:00Z', 'body': 'Fix',
                   'assets': [{'name': 'app.ipa', 'browser_download_url': 'https://example.test/a.ipa', 'size': 123}]}
        response = MagicMock()
        response.__enter__.return_value = response
        response.iter_content.return_value = [ipa.getvalue()]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'apps.json'
            source.write_text(json.dumps({'apps': [{'versions': [{'version': '1.2.3', 'buildVersion': '4'}]}]}))
            with patch.object(updater, 'fetch_latest_release', return_value=release), \
                 patch.object(updater.requests, 'get', return_value=response):
                updater.update_json_file(str(source), 'owner/repo')
                first = source.read_bytes()
                updater.update_json_file(str(source), 'owner/repo')
                self.assertEqual(source.read_bytes(), first)
            self.assertEqual([x['buildVersion'] for x in json.loads(first)['apps'][0]['versions']], ['5', '4'])

    def test_markdown_preserves_link_destination_and_underscores(self):
        self.assertEqual(updater.markdown_to_plain_text(
            '# Changes\n- [Release](https://example.test/my_file)\n**fixed**'),
            'Changes\n• Release (https://example.test/my_file)\nfixed')
