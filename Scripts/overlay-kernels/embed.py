# Embeds a wasm file as base64 JavaScript string lines between the aidokuPixelKernelBytes markers.
import base64, re, sys
wasm, swift = sys.argv[1], sys.argv[2]
b64 = base64.b64encode(open(wasm, 'rb').read()).decode()
src = open(swift).read()
m = re.search(r"(\n(\s*)// BEGIN aidokuPixelKernelBytes\n)(.*?)(\n\s*// END aidokuPixelKernelBytes)", src, re.S)
assert m, 'markers missing'
indent = m.group(2)
lines = [b64[i:i + 112] for i in range(0, len(b64), 112)]
body = '\n'.join(indent + "'" + l + "'+" for l in lines) + '\n' + indent + "'';"
src = src[:m.start(3)] + body + src[m.end(3):]
open(swift, 'w').write(src)
print('embedded', len(b64), 'base64 chars in', len(lines), 'lines')
