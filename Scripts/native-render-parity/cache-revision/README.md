# Final native render namespace

Published revision: `reader-render-v155-native-final-paint`. Revision155 did not appear in the current app/tests/scripts or repository history before this change. Only the render revision changes; OCR, translation and metadata identity algorithms remain unchanged. Asset schema stays3 and native layout schema stays1 because their encoded representations remain compatible.

A compatible asset schema does not authorize replay across a renderer revision. The revision participates in the complete render key; snapshot, native-plan, loaded-composite and render-asset storage keys all include that key. Old completed PNGs and old settled assets therefore cannot satisfy a new request. The persisted layout policy also includes the revision, so a saved v154 policy is transactionally replaced and its layout/render-asset records are removed while OCR/translation/metadata bytes are retained. The page generation changes and rejects late old-generation layout writes. A database with no prior layout policy may retain unreferenced old rows, but the new namespaces cannot replay them.

New suite `ReaderNativeRenderRevisionTests` has two declarations/cases. It stores genuine completed snapshots, loaded PNGs, valid schema3 assets and a valid native plan under historical v154 keys, then checks every actual current lookup misses. Its second test seeds the historical SQLite policy, reopens, verifies old rendered bytes are removed, durable work survives and old-generation writes fail while current writes succeed. It has passed a real iOS SDK semantic check against the existing compiled Aidoku module using the Testing macro plugin; actual runtime execution belongs to the next root checkpoint.

Focused selection:

- `ReaderNativeRenderRevisionTests`
- `ReaderRenderCacheIdentityAuditTests`
- `NativeSettledBitmapReplayTests`
- `ReaderTranslationDiskCacheTests/rendererRevisionRetiresOnlyRecomputableLayouts()` as the narrow existing persistent-policy control

No renderer/asset format rewrite or unrelated cache clearing accompanies this bump. `staged/render-revision.patch` preserves the prepared one-line change.
