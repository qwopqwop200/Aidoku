const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'../../..');
const frozen=fs.readFileSync(path.join(root,'AidokuTests/Translation/LegacyReaderTranslationRenderScript.swift'),'utf8');
const match=frozen.match(/static let BrowserOverlayTypography = #?"""\n([\s\S]*?)\n    """/);
const begin=frozen.indexOf('const wordLines=(maxLines'),finish=frozen.indexOf('let growState=',begin);
let word=frozen.slice(begin,finish).replace(/\\\\/g,'\\');
word=word.slice(0,word.indexOf('for(const n of [node,measurementNode])'))+'return lines;};';
const context=vm.createContext({});
vm.runInContext(match[1]+'\n'+word+`\nglobalThis.call=(input,widths)=>{
wrappingScript='korean';displayedText=input.text;koreanWrapMeasure=true;
width=input.width;node={style:{fontSize:String(input.font),paddingLeft:'0',paddingRight:'0'}};
setKoreanFont=()=>{};koreanTextWidth=part=>widths[part];
return wordLines(input.maxLines,input.wide,input.strict,input.any)||null;};`,context);
if(process.argv[2]==='generate'){
const cases=[];
for(const text of ['하는 것은 정말 좋은 것이라고 생각하는 게 당연하죠.','“잘 만든 것 같아!” 라고 말할 수 있을 때','가능한 모든 문장을 자연스럽게 나누어 읽는 거야','과연? 이건 정말 엄청난 것일까요!?','짧은 말 두 줄','가나다라마바사아자차카타파하','아아아아아악!! 지금은 안 되는 건가요?','한글과 é 문자도 그대로 보존한답니다'])
for(const font of [8,12,20])for(const em of [3,6,8,9,12])for(const strict of [false,true])for(const wide of [false,true]){
const input={text,font,width:font*em,maxLines:8,wide,strict,any:false};cases.push({op:'wordLines',args:[input]});
}
process.stdout.write(JSON.stringify(cases));
}else{
const pairs=JSON.parse(fs.readFileSync(0,'utf8'));
process.stdout.write(JSON.stringify(pairs.map(pair=>context.call(pair.input,Object.fromEntries(Object.entries(pair.widths).map(([k,v])=>[Buffer.from(k,"base64").toString("utf8"),v]))))));
}
