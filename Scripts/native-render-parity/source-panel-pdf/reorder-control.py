"""Diagnostic only: reorder native standalone RGB background blocks by WK order.

Never edits capture inputs, colors, geometry, font resources or image oracle.
Refuses ambiguous repeated colors rather than assigning an arbitrary block.
Run with bundled Python containing pypdf; arguments: capture-directory output-dir.
"""
from pathlib import Path
import collections
import hashlib
import json
import shutil
import sys
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ContentStream

capture, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
readers = {side: PdfReader(capture / (side + '-typography.pdf')) for side in ('native', 'web')}
streams = {side: ContentStream(reader.pages[0]['/Contents'], reader) for side, reader in readers.items()}

def blocks(operations):
    depth, start = 0, None
    for index, (_, operator) in enumerate(operations):
        if operator == b'q':
            if depth == 0:
                start = index
            depth += 1
        elif operator == b'Q':
            depth -= 1
            assert depth >= 0
            if depth == 0:
                yield start, index + 1, operations[start:index + 1]
    assert depth == 0

def signature(operations):
    if any(operator == b'BT' for _, operator in operations):
        return None
    if not any(operator == b'f' for _, operator in operations):
        return None
    colors = [tuple(map(float, values)) for values, operator in operations
              if operator in (b'sc', b'rg') and len(values) == 3]
    return colors[0] if len(colors) == 1 else None

native = [(start, end, ops, signature(ops)) for start, end, ops in blocks(streams['native'].operations)]
selected = [block for block in native if block[3] is not None]
counts = collections.Counter(block[3] for block in selected)
assert selected and all(count == 1 for count in counts.values()), 'Ambiguous native color identity'
web_order = [color for _, _, ops in blocks(streams['web'].operations)
             if (color := signature(ops)) in counts]
assert collections.Counter(web_order) == counts, 'Missing or repeated reference color identity'
by_color = {block[3]: block[2] for block in selected}
replacement = iter(web_order)
operations = streams['native'].operations.copy()
# Replace variable-length blocks sequentially; all unrelated commands keep order.
result, cursor = [], 0
for start, end, _, color in selected:
    result += operations[cursor:start] + by_color[next(replacement)]
    cursor = end
result += operations[cursor:]
writer = PdfWriter(clone_from=readers['native'])
stream = ContentStream(writer.pages[0]['/Contents'], writer)
stream.operations = result
writer.pages[0].replace_contents(stream)
writer.write(output / 'native-typography.pdf')
shutil.copyfile(capture / 'web-typography.pdf', output / 'web-typography.pdf')
(output / 'input-order.json').write_text(json.dumps({
    'scope': 'Background order counterexample only; immutable actual iOS capture remains the oracle',
    'nativeOrder': [block[3] for block in selected], 'referenceOrder': web_order,
    'sourceSHA256': {side: hashlib.sha256((capture / (side + '-typography.pdf')).read_bytes()).hexdigest()
                     for side in readers}}, indent=2))
print('Background blocks reordered:', len(selected))
