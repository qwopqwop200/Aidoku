const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'),'utf8');
const script=source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const plane=new Function(script+';return aidokuSurfacePlaneRGB;')();
const channels=a=>[a,a,a];
const distance=(a,b)=>Math.max(...a.map((v,i)=>Math.abs(v-b[i])));
// Actual 60-page capture: round3-diverse-4430 region3, extrapolated white.
const clipped=plane(channels([278.84400019354126,0,0]),0,0);
assert.deepEqual(clipped,[255,255,255]);
assert.ok(distance([254,254,254],clipped)<=18);
// The next real rejected pixel remains a drawing boundary; no threshold lift.
assert.ok(distance([18,18,18],clipped)>18);
assert.ok(distance([206,206,206],clipped)>18,'gray balloon contour must stay protected');
assert.ok(distance([236,239,246],clipped)>18,'near-white colored art must still pass the original RGB gate');
assert.deepEqual(plane(channels([-19,0,0]),0,0),[0,0,0]);
assert.ok(distance([6,4,42],plane(channels([-19,0,0]),0,0))>18,'dark blue image edge must not become black paper');
assert.deepEqual(plane([[100,20,10],[200,-30,4],[250,5,-2]],.25,.5),[110,194.5,250.25]);
assert.ok(plane([[Infinity,0,0],[NaN,0,0],[0,0,0]],0,0).some(v=>!Number.isFinite(v)),'invalid coefficients cannot yield a fully finite valid color');
console.log('PASS finite surface-plane gamut and real captured contour/color rejection controls');
