import json,zipfile,pathlib,subprocess,tempfile,sys
root=pathlib.Path(tempfile.mkdtemp(prefix='hoshi-import-check-'))
base=['猫','ねこ','','',1,['cat'],1,'']
def run(name,bank=None,title=None,extra=None,expect=False):
 archive=root/(name+'.zip');output=root/'output';title=title or name
 with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED) as z:
  z.writestr('index.json',json.dumps({'title':title,'revision':'1','format':3}))
  z.writestr('term_bank_1.json',bank if isinstance(bank,str) else json.dumps(bank or [base],ensure_ascii=True))
  for k,v in (extra or {}).items():z.writestr(k,v)
 p=subprocess.run([sys.argv[1],str(archive),str(output)],capture_output=True,text=True)
 assert (p.returncode==0)==expect,(name,p.stdout,p.stderr)
 assert not p.stderr,(name,p.stderr)
 print(name,p.stdout.strip())
 if not expect and title !='valid':assert not (output/title).exists(),name
 return output/title
valid=run('valid',extra={'styles.css':'/*\x01*/'},expect=True)
assert json.loads((valid/'index.json').read_text())['styles']=='/*\x01*/'
assert '猫'.encode() in (valid/'blobs.bin').read_bytes()
before={p.name:p.read_bytes() for p in valid.iterdir()}
run('existing',title='valid',expect=False)
assert before=={p.name:p.read_bytes() for p in valid.iterdir()}
run('truncated',json.dumps([base])[:-1]);run('tuple','[[]]');run('trailing',json.dumps([base])+'x')
a=base.copy();a[0]='x'*65536;run('longexpr',[a])
a=base.copy();a[7]='x'*256;run('longtag',[a])
a=base.copy();a[4]=1e100;run('score',[a])
run('badtag',extra={'tag_bank_1.json':'[[]]'});run('badmeta',extra={'kanji_meta_bank_1.json':'[[]]'})
run('badtoplevel',title='../escape');run('nul',title='nul\x00suffix')
print('PASS root='+str(root))
