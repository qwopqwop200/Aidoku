#!/usr/bin/env python3
import json,struct,zlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];o=ROOT/'build/native-render-parity/glyph-cover';inputs=json.loads((o/'fixtures.json').read_text());expected=json.loads((o/'expected.json').read_text());raw=json.dumps(dict(version=1,cases=[dict(input=i,expected=e) for i,e in zip(inputs,expected)]),separators=(',',':')).encode();c=zlib.compressobj(9,wbits=-15);compressed=c.compress(raw)+c.flush();p=ROOT/'AidokuTests/Translation/NativeEngine/Fixtures/native-glyph-cover-fixtures.json.deflate';p.write_bytes(struct.pack('<Q',len(raw))+compressed);print(p,len(raw),len(compressed))
