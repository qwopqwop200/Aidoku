const fs = require('fs'), vm = require('vm');
const source = fs.readFileSync(process.argv[3] + '/BrowserSourcePanelRestoration.swift', 'utf8')
    .split('static let script = """')[1].split('"""')[0];
const context = {}; vm.createContext(context); vm.runInContext(source, context);
const outputs = JSON.parse(fs.readFileSync(process.argv[2])).map(f => {
    const restored = {rgba: new Uint8ClampedArray(f.restored), layoutSafe: new Uint8Array(f.safe)};
    const painted = context.aidokuCompleteConnectedLettering(new Uint8ClampedArray(f.rgba), f.width, f.height,
        f.box, restored, f.excluded, f.vertical ?? null);
    return {name: f.name, painted, rgba: Array.from(restored.rgba), safe: Array.from(restored.layoutSafe)};
});
fs.writeFileSync(process.argv[4], JSON.stringify(outputs));
