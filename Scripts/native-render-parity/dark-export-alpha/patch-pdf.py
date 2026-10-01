import re,zlib,sys,pathlib
folder=pathlib.Path(sys.argv[1]); dst=pathlib.Path(sys.argv[2]);dst.mkdir(parents=True,exist_ok=True)
def objects(path):
 data=path.read_bytes();objs={int(m[1]):m[2].strip() for m in re.finditer(rb'(\d+) 0 obj([\s\S]*?)endobj',data)}
 for i,obj in objs.items():
  s=re.search(rb'stream\r?\n([\s\S]*?)\r?\nendstream',obj)
  if s:
   try:decoded=zlib.decompress(s[1])
   except:decoded=s[1]
   if (b'BT ' in decoded and b'Tm ' in decoded) or b'W* n' in decoded:return data,objs,i,decoded
 raise Exception('no page')
web,wo,wi,ws=objects(folder/'web-typography.pdf');native,no,ni,ns=objects(folder/'native-typography.pdf')
(dst/'web-page.txt').write_bytes(ws);(dst/'native-page.txt').write_bytes(ns)
# Keep paint/colors/fonts/gradients identical; replace only rounded clipping paths.
pattern=rb'q [\d.]+\s+[\d.]+\s+m[\s\S]*?h W\*? n'
wpaths=re.findall(pattern,ws);npaths=re.findall(pattern,ns)
assert len(wpaths)==len(npaths)==4,(len(wpaths),len(npaths))
def write_pdf(name,page):
 objects=dict(no);encoded=zlib.compress(page)
 objects[ni]=b'<< /Length '+str(len(encoded)).encode()+b' /Filter /FlateDecode >>\nstream\n'+encoded+b'\nendstream'
 out=b'%PDF-1.3\n';offsets={}
 for i,obj in sorted(objects.items()):offsets[i]=len(out);out+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
 xref=len(out);count=max(objects)+1;out+=f'xref\n0 {count}\n'.encode()+b'0000000000 65535 f \n'
 for i in range(1,count):out+=(f'{offsets[i]:010} 00000 n \n'.encode() if i in offsets else b'0000000000 00000 f \n')
 root=re.search(rb'/Root (\d+) 0 R',native)[1]
 out+=b'trailer\n<< /Size '+str(count).encode()+b' /Root '+root+b' 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n'
 (dst/name).write_bytes(out)
for idx in range(4):
 page=ns.replace(npaths[idx],wpaths[idx]);write_pdf(f'path{idx}.pdf',page)
page=ns
for a,b in zip(npaths,wpaths):page=page.replace(a,b)
write_pdf('both.pdf',page)
print('saved 5 patched PDF probes')

write_pdf("gradient.pdf",ns.replace(b"253.6562",b"253.6563").replace(b"181.3438",b"181.3437").replace(b"51.32812",b"51.32813"))
write_pdf("geometry.pdf",page.replace(b"253.6562",b"253.6563").replace(b"181.3438",b"181.3437").replace(b"51.32812",b"51.32813"))
# Proof uses only geometry serialized by the actual native Capture helper after
# its general device-scale transform. It does not copy frozen path constants.
_,_,_,generated=objects(dst/'float-device-scale.pdf')
gpaths=re.findall(pattern,generated);assert len(gpaths)==len(npaths)
replayed=ns
for a,b in zip(npaths,gpaths):replayed=replayed.replace(a,b)
rectpat=rb'[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+re'
grects=re.findall(rectpat,generated);nrects=re.findall(rectpat,ns);assert len(grects)==len(nrects)
for a,b in zip(nrects,grects):replayed=replayed.replace(a,b)
write_pdf('native-derived-transform.pdf',replayed)
