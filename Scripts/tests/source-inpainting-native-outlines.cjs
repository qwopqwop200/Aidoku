// Real UIKit-prepared source crops: successful core-only masks used to leave readable white ghosts.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), zlib = require('node:zlib'), crypto = require('node:crypto');
const source = fs.readFileSync(path.join(__dirname,
  '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourcePanelRestoration.swift'), 'utf8');
const script = source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore = new Function(script + ';return aidokuRestoreSourcePanel;')();
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-native-outlines.json'))).fixtures;
for (const f of fixtures) {
  const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
  assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'), f.sha256);
  const result = restore(rgba, f.w, f.h, f.b, f.palette, f.options);
  assert.ok(result, `${f.name}: retain inpainting`);
  assert.equal(result.sourceErasureVerified, true);
  assert.equal(result.preservedCore, 0);
  assert.ok(result.erased >= f.minimumErased, `${f.name}: erase complete outlines, not only glyph cores`);
  for (let y = 0; y < f.h; y++) for (let x = 0; x < f.w; x++) {
    if (x < 2 || y < 2 || x >= f.w - 2 || y >= f.h - 2)
      assert.equal(result.rgba[(y * f.w + x) * 4 + 3], 0, `${f.name}: preserve crop boundary`);
  }
  console.log(`PASS ${f.name}: ${result.erased} pixels, complete erasure and untouched boundary`);
}
