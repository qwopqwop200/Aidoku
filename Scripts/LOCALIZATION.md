# App localization

`Aidoku/App/Resources/Localization/en.lproj` defines the UI keys. Every language
listed in the Xcode project's `knownRegions` must provide the same keys in
`Localizable.strings` and `InfoPlist.strings`. The separate `AidokuShare` target
must provide its own `Localizable.strings` for the same locales.

When adding UI text, use `NSLocalizedString`, add the English entry, and translate
it in every locale. Keep stored setting values, provider names, API protocol
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

The validator checks structure, not translation quality or layout. Initial coverage
included machine translation; the entry-by-entry wording review and its evidence
are recorded in `Documentation/LocalizationReview-2026-09-17.md` and the linked
language-group reports. Agent review is not native-speaker certification or a
device layout check. Dynamic source content and third-party source translations
are outside these app resource tables.

The subsequent full-table recheck is recorded in `Documentation/LocalizationRecheck-2026-09-17.md`, with a separate before/after ledger and final table hashes.

The third independent reassigned-agent audit is in `Documentation/LocalizationRound3-2026-09-17.md`; it records additional implementation-backed wording corrections and the Suwayomi runtime mismatch corrected in the implementation follow-up.
