"""Regression checks for the localization gate (python3 -m unittest discover -s Scripts)."""
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import validate_localizations as validator


class LocalizationValidationTests(unittest.TestCase):
    def parse(self, source):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'Localizable.strings'
            path.write_text(source)
            with patch.object(validator, 'ROOT', root):
                return validator.parse(path)

    def test_urls_and_escaped_quotes_are_not_comments(self):
        values, errors = self.parse(r'/* comment */ "URL" = "https://host/path"; // comment' '\n'
                                    r'"TEXT" = "Tap \"Go\" /* literal */";')
        self.assertFalse(errors)
        self.assertEqual(values['URL'], 'https://host/path')
        self.assertIn('/* literal */', values['TEXT'])

    def test_duplicate_and_empty_values_fail(self):
        _, errors = self.parse('"SAVE" = "Save";\n"SAVE" = "";')
        self.assertTrue(any('duplicate' in issue for issue in errors))
        self.assertTrue(any('empty' in issue for issue in errors))

    def test_truncated_entry_fails(self):
        _, errors = self.parse('"SAVE" = "Save"')
        self.assertTrue(any('malformed' in issue for issue in errors))

    def test_positional_translation_can_reorder_arguments(self):
        self.assertEqual(validator.signature('Remove %i from %@'),
                         validator.signature('%2$@에서 %1$i개 제거'))

    def test_unindexed_reordering_fails(self):
        self.assertNotEqual(validator.signature('Remove %i from %@'),
                            validator.signature('%@에서 %i개 제거'))

    def test_integer_width_and_repeated_arguments_are_checked(self):
        self.assertNotEqual(validator.signature('%lld'), validator.signature('%d'))
        self.assertNotEqual(validator.signature('%@'), validator.signature('%@ %@'))
        self.assertNotEqual(validator.signature('%.2f%%'), validator.signature('%.2f'))

    def test_copied_english_prose_fails_but_names_are_allowed(self):
        self.assertTrue(validator.copied_english(
            'Keep Shared Images in Local Files', 'Keep Shared Images in Local Files', 'de'))
        self.assertFalse(validator.copied_english('OpenAI', 'OpenAI', 'de'))
        self.assertFalse(validator.copied_english('Keep shared images', '共有画像を保持', 'ja'))
        self.assertFalse(validator.copied_english('Keep shared images in files', 'Keep shared images in files', 'en'))

    def test_extension_table_uses_its_own_keys_and_checks_translations(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            extension = root / 'AidokuShare'
            for locale, value in [('en', 'Images saved. Open the app.'), ('ko', 'Images saved. Open the app.')]:
                folder = extension / (locale + '.lproj')
                folder.mkdir(parents=True)
                (folder / 'Localizable.strings').write_text(f'"SHARED_IMAGES_SAVED" = "{value}";')
            with patch.object(validator, 'ROOT', root):
                source, count, errors = validator.validate_table(extension, 'Localizable.strings', ['en', 'ko', 'ja'])
            self.assertEqual(set(source), {'SHARED_IMAGES_SAVED'})
            self.assertEqual(count, 2)
            self.assertTrue(any('untranslated English' in issue for issue in errors))
            self.assertTrue(any('missing table' in issue for issue in errors))

    def test_missing_table_fails(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(validator, 'ROOT', root):
                _, errors = validator.parse(root / 'missing.strings')
            self.assertTrue(any('missing table' in issue for issue in errors))


if __name__ == '__main__':
    unittest.main()
