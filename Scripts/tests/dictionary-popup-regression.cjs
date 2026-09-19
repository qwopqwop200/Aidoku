// Runs the production popup scripts with a deterministic DOM/animation harness.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '../../Aidoku/Features/Dictionary/Popup');
function element() {
    return { children: [], classList: { toggle() {}, contains() { return false; } },
        appendChild(child) { this.children.push(child); return child; },
        replaceChildren(...children) { this.children = children; },
        get childNodes() { return this.children; },
        set innerHTML(_) { this.children = []; }, querySelectorAll() { return []; },
        addEventListener() {}, setAttribute() {}, style: {} };
}
const container = element();
const frames = [];
const context = vm.createContext({ console, URLSearchParams, setTimeout,
    window: { addEventListener() {}, cardFormatCount: 0 },
    document: { getElementById: () => container, createElement: element,
        addEventListener() {}, scrollingElement: { scrollTop: 0 },
        querySelectorAll: () => [], body: element() },
    CSS: { supports: () => false }, Node: { TEXT_NODE: 3 },
    requestAnimationFrame: callback => frames.push(callback),
    webkit: { messageHandlers: { duplicateCheck: { postMessage: async () => [false] } } }
});
vm.runInContext(fs.readFileSync(path.join(root, 'popup.js'), 'utf8'), context);
vm.runInContext(`
    el = () => document.createElement('div');
    createEntryHeader = entry => ({ label: entry.expression });
    createTags = () => null;
    createGlossarySection = name => ({ label: name });
    reportButtonRects = () => {};
`, context);
function entry(expression) { return { expression, glossaries: [{ dictionary: expression + '-1' }, { dictionary: expression + '-2' }] }; }
async function flush() {
    for (let i = 0; i < 30; i++) {
        frames.splice(0).forEach(callback => callback());
        await Promise.resolve();
    }
}
(async () => {
    context.window.lookupEntries = [entry('old'), entry('old-next')];
    context.window.entryCount = 2;
    context.window.renderPopup(); // Pause mid-entry while its first glossary is displayed.
    context.redirect([entry('new')]);
    await flush();
    assert.equal(container.children.length, 1, 'stale render must not append old entries to a redirected page');
    assert.equal(container.children[0].children[0].label, 'new');
    context.window.navigateBack();
    await flush();
    assert.equal(container.children.length, 3, 'back must restore all entries even when original rendering was interrupted');
    assert.equal(container.children[2].children[0].label, 'old-next');
    // A duplicate check for the previous page must not mutate the new page buttons.
    let resolveDuplicate, updated = false;
    context.webkit.messageHandlers.duplicateCheck.postMessage = () => new Promise(resolve => { resolveDuplicate = resolve; });
    vm.runInContext('getButtonSlots = () => [{ dataset: { slotIndex: 0 } }];', context);
    context.updateButtonSlot = () => { updated = true; };
    const pending = context.checkDuplicates(0);
    context.redirect([entry('other')]);
    resolveDuplicate([false]);
    await pending;
    assert.equal(updated, false);

    vm.runInContext(fs.readFileSync(path.join(root, 'selection.js'), 'utf8'), context);
    const selection = context.window.hoshiSelection;
    const node = { nodeType: 3, textContent: '𠮷野家' };
    context.window.scanNonJapaneseText = false;
    selection.getCaretRange = () => ({ startContainer: node, startOffset: 1 });
    selection.isFurigana = () => false;
    selection.inCharRange = () => true;
    let end;
    context.document.createRange = () => ({ setStart() {}, setEnd(_, value) { end = value; } });
    assert.equal(selection.getCharacterAtPoint(0, 0).offset, 0);
    assert.equal(end, 2, 'a supplementary kanji must be tested as a complete UTF-16 pair');
    console.log('PASS: redirected render cancellation, complete back history, stale duplicate isolation, supplementary kanji selection');
})().catch(error => { console.error(error); process.exitCode = 1; });
