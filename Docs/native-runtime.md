# Native runtime map

Reader translation display and image export are native. As upstream, installed sources run WASM and the dictionary
popup is a web view; browser-dependent login and interactive challenges still use WebKit.

| Area | Current execution | Main entry points |
| --- | --- | --- |
| Page translation (V2) | Core ML layout/OCR/inpainting, Swift grouping, mask, style and Core Text paint | `ReaderTranslationV2Service`, `V2Pipeline` ([V2](translation-v2.md)) |
| OCR models | Core ML PP-OCRv6 manga detector and recognizer | `NativeCoreMLDetector`, `V2Recognition` |
| Translation requests | URLSession transport, parsing and bounded batching | `RemoteTranslationClient`, `ReaderTranslationService` |
| Reader display and export | Finished V2 bitmap above the source image, saved as is | `ReaderTranslationPage`, `ReaderTranslationImageExporter` |
| Dictionary popup | Upstream `popup.js` in a WKWebView | `PopupView`, `PopupWebView` |
| Installed sources | `main.wasm` on AidokuRunner, or the legacy runtime for 0.6-API packages | `SourceManager`, `Core/Sources/Legacy` |
| Web login, challenges, user agent | WebKit | `WebView`, `CloudflareHandler`, `UserAgentProvider` |
| Image translation CLI | Production algorithms with an AppKit/Core Graphics host adapter | `Scripts/image-translation.swift` |

`Browser…` names on pure Swift OCR data types are historical. Host font and raster output of the CLI
([README](../Scripts/image-translation/README.md)) is not proof of exact iPhone output.

Translation-cache SQLite reads borrow the compressed BLOB only within the statement and return owned bytes; writes
keep their buffer until the statement finalizes. Dictionary raster attachments decode at display size and keep one
rendered bitmap per size/trait; explicitly pixelated images keep their original pixels.
