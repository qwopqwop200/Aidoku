# Native runtime map

The reader's translation display, final image export and dictionary popup use
native code. Installed source packages run their WASM as upstream Aidoku does.
Browser-dependent login and interactive challenges
still use WebKit. The app as a whole therefore still has a browser component.

| Area | Current execution | Main entry points |
| --- | --- | --- |
| Page translation (V2) | Core ML layout/OCR/inpainting plus Swift grouping, removal mask, style and Core Text paint | `ReaderTranslationV2Service`, `V2Pipeline` (`Docs/translation-v2.md`) |
| OCR models | Core ML PP-OCRv6 manga detector and recognizer, run by V2 | `NativeCoreMLDetector`, `V2Recognition` |
| Translation requests | Swift URLSession transport, parsing and bounded batching | `RemoteTranslationClient`, `ReaderTranslationService` |
| Reader display and export | The finished V2 page bitmap is attached above the source image and saved as is | `ReaderTranslationPage`, `ReaderTranslationImageExporter` |
| Dictionary popup | UIKit text, links and view layout | `NativeDictionaryPopupView` |
| Installed sources | `main.wasm` on the AidokuRunner interpreter, or the legacy runtime for 0.6-API packages | `SourceManager`, `Core/Sources/Legacy`, AidokuRunner package (fork) |
| Web login, challenge solving and user agent | WebKit for browser-dependent flows | `WebView`, `CloudflareHandler`, `UserAgentProvider` |
| Image translation CLI | Native production algorithms with an AppKit/Core Graphics host adapter | `Scripts/image-translation.swift` |

Historical `Browser…` names can remain on pure Swift OCR data types. A type
name alone does not imply browser execution.

## Host image translation

```sh
swift Scripts/image-translation.swift /path/to/page.png
swift Scripts/image-translation.swift --ocr-only /path/to/page.png
```

The launcher builds the V2 pipeline (`Docs/translation-v2.md`) from current
source with incremental object/model caches on Apple Silicon macOS 15+ with the
Xcode command-line tools. See [CLI configuration and outputs](../Scripts/image-translation/README.md).
Host font and raster behavior is not proof of exact iPhone output.

## Native allocation policy

Translation-cache SQLite compressed reads borrow the BLOB only within the
synchronous statement and return owned decoded bytes. Writes retain their source
buffer until SQLite finalizes the statement. Dictionary raster attachments decode
at their display size and retain one size/trait-specific rendered bitmap;
explicit pixelated images preserve their original pixels.

## Verification

See [test commands](../Scripts/TESTING.md).
