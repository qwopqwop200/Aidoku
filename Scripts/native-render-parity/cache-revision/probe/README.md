# JSON serialization ordering counterexample

`NativePlan.swift` extracts the actual `NativeTranslationLayout` declaration from production. Only the element and planner types are minimal placeholders; the element list is empty and geometry validation is never used during encoding. The probe invokes the genuine synthesized layout encoder32 times, then decodes all outputs and compares their values. On this host it produced9 distinct byte serializations of the same value. The default JSON encoder does not promise canonical object-key order.

This identifies the test mistake in the final BUILD55 assertion: it compared bytes stored from one `plan()` call to a second independently encoded `plan()` call. The correction captures `currentPlan` once and requires the cache to return those exact bytes. No storage behavior or comparison tolerance changes.

```sh
xcrun swiftc -O Scripts/native-render-parity/cache-revision/probe/NativePlan.swift \
  Scripts/native-render-parity/cache-revision/probe/main.swift -o /tmp/aidoku-cache-plan-json-probe
/tmp/aidoku-cache-plan-json-probe
```
