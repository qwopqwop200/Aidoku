import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';

const [manifestPath, wasmPath, outputDirectory] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const module = new WebAssembly.Module(fs.readFileSync(wasmPath));
const { exports } = new WebAssembly.Instance(module, { env: { sqrt: Math.sqrt } });
const functions = Object.keys(exports).filter(name => typeof exports[name] === 'function').sort();
const expected = Object.keys(manifest.abi).sort();
if (JSON.stringify(functions) !== JSON.stringify(expected)) {
    throw new Error(`Export ABI mismatch: ${JSON.stringify(functions)} versus ${JSON.stringify(expected)}`);
}
fs.mkdirSync(outputDirectory, { recursive: true });
const heap = (Number(exports.__heap_base.value) + 15) & ~15;
const reports = [];
for (const fixture of manifest.cases) {
    const data = Buffer.from(fixture.data, 'base64');
    const required = heap + data.length;
    if (required > exports.memory.buffer.byteLength) {
        exports.memory.grow(Math.ceil((required - exports.memory.buffer.byteLength) / 65536));
    }
    new Uint8Array(exports.memory.buffer, heap, data.length).set(data);
    const returns = fixture.calls.map(call => exports[call.name](...call.args.map(value =>
        typeof value === 'object' ? heap + value.pointer : value)));
    const result = Buffer.from(new Uint8Array(exports.memory.buffer, heap, data.length));
    fs.writeFileSync(path.join(outputDirectory, `${fixture.id}.bin`), result);
    reports.push({ id: fixture.id, returns: returns.map(value => value === undefined ? null : value),
        sha256: crypto.createHash('sha256').update(result).digest('hex') });
}
fs.writeFileSync(path.join(outputDirectory, 'results.json'), JSON.stringify(reports, null, 2));
