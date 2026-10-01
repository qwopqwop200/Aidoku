    const aidokuRebaseCoverageClip = (plate, coverage, left, top) => {
      if(!plate.style.clipPath||plate.style.clipPath==='none')return;
      const clip=`path('${coverage.map(r=>`M ${r[0]-left} ${r[1]-top} h ${r[2]} v ${r[3]} h ${-r[2]} Z`).join(' ')}')`;
      plate.style.clipPath=CSS.supports('clip-path',clip)?clip:'';
    };
const CSS={supports:()=>true};
const coverage=[[101.125,202.25,11.5,13.75]];
const cases=[['empty',''],['none','none'],['percent','inset(10% 20% 30% 40%)'],['path',"path('M 0 0 H 1 V 1 H 0 Z')"]];
const result=cases.map(([name,clip])=>{const plate={style:{clipPath:clip}};aidokuRebaseCoverageClip(plate,coverage,100,200);return {name,before:clip,after:plate.style.clipPath};});
console.log(JSON.stringify(result));
