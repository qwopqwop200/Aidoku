// Exercise the production dispatcher with controlled recovery outcomes. Pixel
// ownership belongs to the individual restorers; this tests retry arbitration.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,
  '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourcePanelRestoration.swift'), 'utf8');
const start = source.indexOf('function aidokuRestoreSourcePanel(rgba');
const end = source.indexOf('function aidokuRestoreSourcePanelAttempts(', start);
assert.ok(start >= 0 && end > start);
const dispatcher = source.slice(start, end);
function run(branch, {verified = false, outline = true, slanted = false, throws = false} = {}) {
  const partial = {sourceErasureVerified: verified, method: 'candidate'};
  const complete = {sourceErasureVerified: true, method: 'outline'};
  let outlineCalls = 0;
  const identity = x => x;
  const make = new Function('attempt', 'recover', 'discover', 'refine', dispatcher + `
    function aidokuRestoreSourcePanelAttempts(...args) {
      aidokuRestoreSourcePanel.classificationCache.shortGlyphCandidate = true;
      aidokuRestoreSourcePanel.classificationCache.denseDonorCandidate = true;
      return attempt(...args);
    }
    const aidokuRestoreChromaticBalloonGlyphs = recover;
    const aidokuDiscoverOutlinedSource = discover;
    const aidokuNarrowPaperGlyphs = () => null;
    const aidokuFinishClearPaperCaption = refine;
    const aidokuRefineChromaticFringe = refine;
    const aidokuRefineWhiteGlyphFringe = refine;
    return aidokuRestoreSourcePanel;
  `);
  const restore = make((rgba, w, h, b, palette, options) => {
    const match = branch === 'base' || branch === 'short' && options.shortGlyphRecovery ||
      branch === 'dense' && options.denseDonorSampling || branch === 'enclosed' && options.enclosedWordRecovery;
    if (match && throws) throw new Error('probe');
    return match ? partial : null;
  }, () => { outlineCalls++; return outline ? complete : null; }, () => null, identity);
  if (throws) assert.throws(() => restore([], 1, 1, [], {}, {}), /probe/);
  else {
    const result = restore([], 1, 1, [], {}, {slantedOwnership: slanted});
    assert.equal(result, verified || !outline || slanted && branch === 'short' ? partial : complete);
    if (verified || slanted && branch === 'short') assert.equal(outlineCalls, 0);
  }
  assert.equal(restore.classificationCache, null, 'release page scratch state even after failure');
}
for (const branch of ['base', 'short', 'dense', 'enclosed']) {
  run(branch);
  run(branch, {verified: true});
  run(branch, {outline: false});
  run(branch, {throws: true});
}
run('short', {slanted: true});
console.log('PASS restoration retry priority: 17 cases');
