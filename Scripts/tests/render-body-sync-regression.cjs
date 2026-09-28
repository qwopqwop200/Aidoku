// The overlay render body must stay free of top-level `await`. One await in
// this very long async function makes JavaScriptCore compile the whole body as
// a generator before its first statement runs: about 70 ms per render on the
// host and 75-90 ms in the iOS simulator (every export loads a fresh document).
// Asynchronous steps continue in a synchronous callback instead, as the
// letter-face request does (renderWithLetterFaces).
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const source = fs.readFileSync(path.resolve(__dirname,
  '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'), 'utf8');
const marker = 'BrowserOverlayTypography.script + """\n';
const start = source.indexOf(marker);
assert.ok(start >= 0, 'render body literal found');
const lines = source.slice(start + marker.length).split('\n');
const end = lines.findIndex(line => line.trim().startsWith('"""'));
assert.ok(end > 0, 'render body literal terminated');
const indent = lines[end].length - lines[end].trimStart().length;
const unescape = text => text.replace(/\\(u\{[0-9a-fA-F]+\}|.)/g, (_, c) => {
  if (c[0] === 'u' && c[1] === '{') return String.fromCodePoint(parseInt(c.slice(2, -1), 16));
  return {n: '\n', t: '\t', r: '\r', 0: '\0', '\\': '\\', '"': '"', "'": "'"}[c] ?? c;
});
const body = unescape(lines.slice(0, end).map(line => line.slice(Math.min(indent, line.length - line.trimStart().length))).join('\n'));
assert.ok(body.includes('const revisionNumber = Number(revision);'), 'render body extracted');
// A synchronous function rejects `await` in its own body; nested async
// functions (the letter-face loader) are still allowed.
assert.doesNotThrow(() => new Function('items', 'appearance', 'revision', 'session', body),
  'the render body has no top-level await');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
assert.doesNotThrow(() => new AsyncFunction('items', 'appearance', 'revision', 'session', body), 'the render body parses as async');
console.log('PASS render body has no top-level await');
