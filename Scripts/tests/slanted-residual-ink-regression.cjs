// Reviewed failures must erase every annotated source stroke and expose the
// restored interior to translation fitting, while preserving nearby artwork.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const source = name => fs.readFileSync(path.resolve(__dirname,
  '../../Aidoku/Core/Translation/NativeEngine/Overlay/' + name + '.swift'), 'utf8')
  .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const {restore, fits, geometry} = new Function(source('BrowserSourceTextColor') + source('BrowserSourcePanelRestoration') +
  source('BrowserSlantedSourceRestoration') +
  ';return {restore:aidokuRestoreSlantedSource,fits:aidokuSlantedInkFits,geometry:aidokuSlantedLocalGeometry}')();
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/slanted-ruby-pixels.json'))).cases;
const unpack = value => new Uint8ClampedArray(zlib.inflateSync(Buffer.from(value, 'base64')));
const palettes = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/slanted-renderer-palettes.json'))).cases;
const ids = ['ruby-05--25', 'ruby-05-+25', 'ruby-05-+78'];
for (const id of ids) for (const paletteKind of ['fixture', 'renderer']) {
  const fixture = fixtures.find(f => f.id === id);
  assert(fixture, 'missing reviewed residual-ink fixture: ' + id);
  const input = unpack(fixture.rgba), ink = unpack(fixture.ink), protectedPixels = unpack(fixture.protected);
  const original = input.slice();
  const palette = paletteKind === 'fixture' ? fixture.palette : palettes.find(p => p.id === id).palette;
  const result = restore(input, fixture.w, fixture.h, fixture.box, fixture.angle, palette,
    fixture.vertical, {auxiliary: fixture.auxiliary, auxiliaryPolygons: fixture.auxiliaryPolygons, inferRuby: fixture.infer});
  const options = {auxiliary: fixture.auxiliary, auxiliaryPolygons: fixture.auxiliaryPolygons, inferRuby: fixture.infer};
  const roundedTrip = fixture.box.map((v, i) => v + (i % 2 ? 1 : -1) * 1e-11);
  assert.deepEqual(geometry(roundedTrip, fixture.angle, fixture.vertical, options),
    geometry(fixture.box, fixture.angle, fixture.vertical, options), id + ': normalized-coordinate round trip');
  assert(result, id + ': keeping the source instead of translating is not a fix');
  assert.deepEqual(input, original, id + ': immutable original');
  let visibleInk = 0, residual = 0, changedArt = 0;
  for (let i = 0; i < ink.length; i++) {
    const delta = Math.max(...[0, 1, 2].map(k => Math.abs(result.rgba[i * 4 + k] - input[i * 4 + k])));
    // The mask is nearest-neighbor rotated; white resampling pixels are not ink.
    const visible = Math.max(...fixture.palette.background.map((v, k) => Math.abs(v - input[i * 4 + k]))) > 24;
    if (ink[i] && visible) {
      visibleInk++;
      if (result.rgba[i * 4 + 3] < 250 || delta <= 10) residual++;
    }
    if (protectedPixels[i] && result.rgba[i * 4 + 3] && delta > 3) changedArt++;
  }
  assert(visibleInk > 5000, id + ': nonempty real-image oracle');
  assert.equal(residual, 0, id + ': visible original strokes remain');
  assert.equal(changedArt, 0, id + ': artwork or balloon outline was changed');
  // This reviewed white interior can accommodate a small translated glyph in
  // source-local coordinates. A stale pre-erasure safety/luminance map rejected
  // it at -25 and +78 degrees even after the native source pixels were cleared.
  assert(fits(result, [[53, 75, 62, 88]], 1, [0, 0, 0]),
    id + ': completed erasure must also be available to translated text fitting');
  if (id === 'ruby-05-+78') assert(fits(result, [[177, 78, 180, 81]], 1, [0, 0, 0]),
    'erased glyph edges mixed with untouched paper must use final composite contrast');
  console.log(`PASS ${id} (${paletteKind}): ${visibleInk} source-ink pixels erased; protected artwork unchanged`);
}
console.log(`${ids.length * 2}/${ids.length * 2} strict slanted residual-ink regressions passed`);
