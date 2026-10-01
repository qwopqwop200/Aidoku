# Native live paint cache revision

Current prepared/published revision is `reader-render-v156-native-live-paint`, replacing `reader-render-v155-native-final-paint`. The production change is one constant; no renderer file changes accompany it. OCR, provider translation and metadata identity algorithms are unchanged. Native asset schema3 and native layout schema1 remain compatible.

The full render key includes the revision. Loaded-composite, settled snapshot, asset-storage and native-plan keys derive from it, so v155 completed live bitmaps/PNG assets/plans cannot satisfy a v156 request. The persisted layout policy also includes the revision and retires layout/asset records on reopening. Durable OCR/translation/metadata bytes survive; old-generation writers cannot repopulate retired layout storage.

`ReaderNativeRenderRevisionTests` retains the original v154 controls and adds the immediate previous v155 revision as parameters: two declarations, four executions. It seeds genuine completed images, valid schema3 assets and valid native plans before requiring all current lookups to miss. The persisted SQLite policy test checks retirement, durable-kind preservation, stale-generation rejection and an exact current-generation byte roundtrip using one captured encoded Data.

The real iOS SDK semantic check passed against the compiled Aidoku module with the Testing macro plugin. Actual runtime remains pending the next root production batch. Root61 hold arrived immediately after app/test publication; root was informed of the exact current state, and owned app/test inputs were then held unchanged. The staged one-line patch and complete test source are retained for review. There was no renderer, source-mask, foreign compositor or kernel mutation by this author.

Focused suite: `ReaderNativeRenderRevisionTests`. Existing controls `ReaderRenderCacheIdentityAuditTests`, `NativeSettledBitmapReplayTests` and `ReaderTranslationDiskCacheTests/rendererRevisionRetiresOnlyRecomputableLayouts()` remain available; no unrelated broad regression run was initiated.
