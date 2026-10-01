import json,zlib,struct
from pathlib import Path
R=Path(__file__).resolve().parents[3];b=R/'build/native-render-parity/late-plate-trim'
f=json.loads((b/'fixtures.json').read_text());e=json.loads((b/'expected.json').read_text());payload=json.dumps({'version':1,'cases':[{'input':a,'expected':c} for a,c in zip(f,e)]},separators=(',',':')).encode();out=R/'AidokuTests/Translation/NativeEngine/Fixtures/native-late-plate-trim-fixtures.json.deflate';out.write_bytes(struct.pack('<Q',len(payload))+zlib.compress(payload,9)[2:-4]);print(len(payload),out.stat().st_size)
