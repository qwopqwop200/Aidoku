# Embeds a wasm file as base64 JavaScript string lines between the aidokuPixelKernelBytes markers.
import base64
from pathlib import Path
import re
import sys

wasm, swift = map(Path, sys.argv[1:])
b64 = base64.b64encode(wasm.read_bytes()).decode()
src = swift.read_text()
m = re.search(r"(\n([ \t]*)// BEGIN aidokuPixelKernelBytes\n)(.*?)(\n[ \t]*// END aidokuPixelKernelBytes)", src, re.S)
if m is None:
    raise ValueError('markers missing')
indent = m.group(2)
lines = [b64[i:i + 112] for i in range(0, len(b64), 112)]
body = '\n'.join(indent + "'" + line + "'+" for line in lines) + '\n' + indent + "'';"
updated = src[:m.start(3)] + body + src[m.end(3):]
if updated != src:
    swift.write_text(updated)
    print('embedded', len(b64), 'base64 chars in', len(lines), 'lines')
else:
    print('unchanged:', len(b64), 'base64 chars in', len(lines), 'lines')
