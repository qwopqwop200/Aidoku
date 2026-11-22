# App localization

`Aidoku/App/Resources/Localization/en.lproj` defines the UI keys; `ko.lproj` must provide
the same keys in `Localizable.strings` and `InfoPlist.strings`. Other locales stay as
upstream ships them and fall back to English. `AidokuShare` has its own English and
Korean `Localizable.strings`. Permission descriptions must match `Aidoku/Info.plist`.

```sh
python3 -m unittest discover -s Scripts -v
python3 Scripts/validate_localizations.py
```

The validator (also the Localization workflow) checks missing tables/locales/keys,
extra or duplicate keys, blank or malformed entries, unresolved literal Swift references,
built-in source setting keys, English copied into Korean (four or more English words;
a heuristic) and format argument compatibility. Positional arguments such as `%2$@` are
allowed when a translation reorders words. It checks structure, not translation quality.
