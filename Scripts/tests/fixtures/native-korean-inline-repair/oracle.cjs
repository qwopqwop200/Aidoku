const fs=require('fs'),vm=require('vm'),view=fs.readFileSync(process.argv[3]+'/BrowserOverlayView.swift','utf8');
let source=view.slice(view.indexOf('        const koreanWrapStarted ='),view.indexOf('        // Preserve word and punctuation repairs')).replaceAll('\\\\','\\');
const output=JSON.parse(fs.readFileSync(process.argv[2])).map(f=>{
 const p=f.padding||[2,2,2,2],style={fontWeight:700,fontFamily:'sans-serif',fontSize:f.font+'px',paddingLeft:p[3]+'px',paddingRight:p[1]+'px',paddingTop:p[0]+'px',paddingBottom:p[2]+'px',wordBreak:'keep-all',lineBreak:'auto',overflowWrap:'anywhere'};
 Object.defineProperty(style,'padding',{get(){return [this.paddingTop,this.paddingRight,this.paddingBottom,this.paddingLeft].join(' ');},set(s){const p=s.split(' ');[this.paddingTop,this.paddingRight,this.paddingBottom,this.paddingLeft]=p;}});
 const measurementNode={style:{...style}},node={style,dataset:{}},card=f.card||[0,0,50,50],root={dataset:{}};
 function data(){return f.profiles[style.lineBreak==='strict'?'strict':parseFloat(style.fontSize).toFixed(2)];}
 const c={node,measurementNode,root,displayedText:f.text,vertical:f.vertical||false,wrappingScript:f.script||'korean',koreanWrapMeasure:true,width:card[2],height:card[3],x:card[0],y:card[1],reference:{exclusionRects:f.exclusions||[]},minimumFontSize:f.minimum||5,koreanWrapCharacterBudget:f.budget??2048,performance:{now:()=>0},setKoreanFont(){},koreanTextWidth(){return f.widest??100;},applyMeasuredFontSize(v){style.fontSize=v+'px';},lineProfile(){const d=data();return !d||d.null?null:{lines:d.lines,breaks:d.breaks||[],badStarts:d.starts||[],badEnds:d.ends||[],ink:d.ink||[[2,2,10,10]]};},contentFits(){return data()?.fits!==false;}};
 vm.createContext(c);vm.runInContext(source,c);
 return {name:f.name,font:parseFloat(style.fontSize),padding:[style.paddingTop,style.paddingRight,style.paddingBottom,style.paddingLeft].map(parseFloat),strict:style.lineBreak==='strict',wrap:node.dataset.koreanWrapRepair==='accepted',punctuation:node.dataset.koreanPunctuationRepair==='accepted',budget:c.koreanWrapCharacterBudget};
});fs.writeFileSync(process.argv[4],JSON.stringify(output));
