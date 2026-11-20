# App localization

`Aidoku/App/Resources/Localization/en.lproj` defines the UI keys. This fork
maintains English and Korean only: `ko.lproj` must provide the same keys in
`Localizable.strings` and `InfoPlist.strings`. The other locales stay as upstream
ships them; keys they lack fall back to English. The separate `AidokuShare` target
ships its own `Localizable.strings` in English and Korean.

When adding UI text, use `NSLocalizedString`, add the English entry, and translate
it in Korean. Keep stored setting values, provider names, API protocol
names, and font family identifiers unchanged; localize their display labels.
Permission descriptions must also match the English text in `Aidoku/Info.plist`.

Run from the repository root:

```sh
python3 -m unittest discover -s Scripts -v
python3 Scripts/validate_localizations.py
```

The Localization workflow checks missing tables/locales/keys, extra or duplicate
keys, blank values, malformed entries, unresolved literal Swift references,
built-in source setting keys, unchanged English text containing four or more
English words, and format argument compatibility. Short shared names and technical
terms are allowed; the English-copy check is a heuristic, not a language detector. It permits
positional arguments such as `%2$@` and `%1$i` when a translation changes word
order. Never swap unnumbered placeholders of different types.

The validator checks structure, not translation quality or layout. Dynamic source
content and third-party source translations are outside these app resource tables.
