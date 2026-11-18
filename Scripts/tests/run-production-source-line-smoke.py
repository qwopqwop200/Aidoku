"""Execute the real production painter on neutral source-line fixtures.
No OCR, network provider, source RGB, evaluation GT or inference model calls.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import hashlib
import math
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]


def item(ident,text,frame,font):
    return dict(id=ident,text=text,frame=frame,fontReference=font,fill=[220,60,140],outline=[255,255,255],
                outlineWidth=font*.06,sourceFontWeight='regular',renderBold=False,textAlignment='left',
                textPlacementGuide=dict(rectNormalized=[frame[0]/700,frame[1]/500,frame[2]/700,frame[3]/500],horizontal='left',vertical='top'),
                textExpansionPolicy=dict(allowedRectNormalized=[0,0,1,1],candidates=[[0,0,1,1]],
                                         maskCoverage=[1],backgroundRisk=[0],sourceFontPixels=font,kind='source-near-limited-expansion'))


with tempfile.TemporaryDirectory(prefix='aidoku-production-source-line-')as tmp:
    out=Path(tmp);cases=[item('title','원래 가로 제목',[40,180,400,70],70),item('small','소지품 검사',[40,80,200,40],40)]
    balloon=item('own-lobe','짧은 글',[80,90,40,80],24);balloon.pop('textExpansionPolicy')
    balloon['balloonInterior']=dict(rect=[.08,.1,.25,.5],spans=[.08,.33]*16,center=[.205,.35],contourVerified=True)
    stale=item('stale-contour','범위',[80,90,40,80],24);stale.pop('textExpansionPolicy')
    stale['balloonInterior']=dict(rect=[.6,.6,.2,.2],spans=[.6,.8]*16,center=[.7,.7],contourVerified=True)
    cases.extend([balloon,stale])
    request=dict(pages=[dict(page='fixture-'+str(i),width=700,height=500,items=[r])for i,r in enumerate(cases)])
    for page in request['pages'][2:]:
        page['inferExpansionFromRF']=True
        page['rfRegions']=[dict(classID=2,confidence=.95,bounds=[.01,.01,.9,.9],exterior=[[.01,.01],[.91,.01],[.91,.91],[.01,.91]])]
    family=[item('family-a','같은 크기',[40,70,280,50],40),item('family-b','글자 크기를 똑같이 유지',[40,210,280,50],40)]
    for r in family:r.pop('textExpansionPolicy');r['typographyGroupID']='shared-source-family'
    request['pages'].append(dict(page='shared-family',width=700,height=500,items=family,inferExpansionFromRF=True,rfRegions=[]))
    stacked=[item('start-a','원래 시작 위치와 같은 크기를 유지하며 긴 문장을 표시',[31,486,812,44],44),
             item('start-b','두 번째 안내 문장',[37,555,613,44],44)]
    for r in stacked:
        x,y,w,h=r['frame'];r['typographyGroupID']='stacked-family'
        r['textPlacementGuide']['rectNormalized']=[x/1200,y/630,w/1200,h/630]
        r['textExpansionPolicy']=dict(allowedRectNormalized=[0,470/630,1001/1200,148/630],
            candidates=[[0,470/630,1001/1200,148/630]],maskCoverage=[1],backgroundRisk=[0],
            sourceFontPixels=44,kind='inside-balloon-mask',sourceAnchorLimitEm=3,
            maskRectNormalized=[0,470/630,1001/1200,148/630],maskSpansNormalized=[0,1001/1200]*4)
    request['pages'].append(dict(page='stacked-start-anchors',width=1200,height=630,items=stacked))
    cohort=[item('cohort-a','정신을 차렸을 때',[50,80,95,180],24),
            item('cohort-b','한 글자 꼬리줄 없이 같은 크기로 표시',[190,80,95,180],24)]
    for r in cohort:
        r['typographyGroupID']='cohort-family'
        r['sourceClusterAlignment']=dict(groupID='cohort',axis='top',anchorNormalized=.16,anchorPolicy='source-near-final-alpha')
    request['pages'].append(dict(page='cohort-counterfactual',width=700,height=500,items=cohort))
    lexical=item('lexical-exterior','도서관에서 책을 읽었습니다',[280,100,65,230],24)
    lexical['textPlacementGuide'].update(horizontal='center',vertical='center')
    lexical['textExpansionPolicy']['allowedRectNormalized']=[.3,.1,.3,.8]
    lexical['textExpansionPolicy']['candidates']=[[.3,.1,.3,.8]]
    request['pages'].append(dict(page='lexical-exterior',width=700,height=500,items=[lexical]))
    independent=item('independent-caption','같은 글자 크기로 긴 문장 표시',[200,180,160,50],40)
    independent.pop('textExpansionPolicy')
    request['pages'].append(dict(page='independent-exterior',width=700,height=500,items=[independent],
                                 inferExpansionFromRF=True,rfRegions=[]))
    for index,angle in enumerate([-.24,.24]):
        tilted=item('tilted-'+str(index),'기울어진 원문 글줄',[200,180,280,90],32)
        tilted['textPlacementGuide'].update(horizontal='center',vertical='center',sourceRotationRadians=angle)
        request['pages'].append(dict(page='observed-tilt-'+str(index),width=700,height=500,items=[tilted]))
    lobe=item('right-lobe','같은 글자',[470,110,140,100],32);lobe.pop('textExpansionPolicy')
    lobe['textPlacementGuide'].update(horizontal='center',vertical='center')
    polygon=[[.1,.1],[.4,.1],[.4,.3],[.65,.3],[.65,.1],[.9,.1],
             [.9,.85],[.65,.85],[.65,.5],[.4,.5],[.4,.9],[.1,.9]]
    request['pages'].append(dict(page='connected-lobes',width=700,height=500,items=[lobe],inferExpansionFromRF=True,
        rfRegions=[dict(classID=2,confidence=.95,bounds=[.1,.1,.8,.8],exterior=polygon)]))
    paragraph=item('clean-paragraph','좋은 글은 읽기 편한 문장으로 함께 자연스럽게 배치한다',[280,80,130,320],24)
    paragraph['textPlacementGuide'].update(horizontal='center',vertical='center')
    previous=json.loads(json.dumps(paragraph));previous['id']='clean-paragraph-prior';previous['renderLegacyWordRefinement']=True
    request['pages'].append(dict(page='clean-paragraph-compaction',width=700,height=500,items=[paragraph]))
    request['pages'].append(dict(page='clean-paragraph-prior',width=700,height=500,items=[previous]))
    source_start_cohort=json.loads(json.dumps(cohort))
    for r in source_start_cohort:r['sourceClusterAlignment']['anchorsToSourceStart']=True
    request['pages'].append(dict(page='source-start-cohort-verification',width=700,height=500,items=source_start_cohort))
    for supplied in (False,True):
        caption=item('exterior-caption','말풍선 밖에서 읽는 글',[70,120,120,160],24)
        if not supplied:caption.pop('textExpansionPolicy')
        request['pages'].append(dict(page='exterior-balloon-'+str(supplied),width=700,height=500,
            items=[caption],inferExpansionFromRF=True,rfRegions=[dict(classID=2,confidence=.95,
            bounds=[.3,.15,.25,.6],exterior=[[.3,.15],[.55,.15],[.55,.75],[.3,.75]])]))
    # A stale body target outside its assigned mask must not drop a separate
    # healthy body's coupled paragraph fit during local placement recovery.
    local=[]
    for ident,text,frame,order in [('healthy-a','첫 안내',[60,100,50,100],0),('healthy-b','다음 안내',[150,100,50,100],1)]:
        r=item(ident,text,frame,20)
        r['textPlacementGuide'].update(horizontal='center',vertical='top')
        r['balloonPlacement']=dict(bodyID='healthy',rectNormalized=[.03,.1,.36,.5],preserveSourceOffsets=True,
            biasNormalized=[0,0],flow='row',paddingEm=.25,gapEm=1.2,maskSHA256='a'*64,order=order,crossAlignment='start')
        r['textExpansionPolicy'].update(allowedRectNormalized=[.03,.1,.36,.5],candidates=[[.03,.1,.36,.5]],kind='inside-balloon-mask',
            maskRectNormalized=[.03,.1,.36,.5],maskSpansNormalized=[.03,.39]*16)
        local.append(r)
    bad=item('stale-body-target','별도 문단',[460,100,140,150],24)
    bad['balloonPlacement']=dict(bodyID='stale',rectNormalized=[.03,.65,.3,.3],biasNormalized=[0,0],flow='column',
        paddingEm=.25,gapEm=.35,maskSHA256='b'*64,order=0)
    bad['textExpansionPolicy'].update(allowedRectNormalized=[.6,.1,.3,.6],candidates=[[.6,.1,.3,.6]],kind='inside-balloon-mask',
        maskRectNormalized=[.6,.1,.3,.6],maskSpansNormalized=[.6,.9]*16)
    local.append(bad)
    request['pages'].append(dict(page='local-body-target-recovery',width=700,height=500,items=local))
    edge=item('page-edge','가장자리 글자',[0,80,120,160],24)
    request['pages'].append(dict(page='readable-page-edge',width=700,height=500,items=[edge]))
    for supplied,confidence in [(False,.95),(True,.95),(True,.89)]:
        boxed=item('boxed','짧은 글',[100,100,100,200],24)
        if not supplied:boxed.pop('textExpansionPolicy')
        request['pages'].append(dict(page='box-bound-'+str(supplied)+'-'+str(confidence).replace('.',''),width=700,height=500,
            items=[boxed],inferExpansionFromRF=True,rfRegions=[dict(classID=2,confidence=confidence,
            bounds=[80/700,80/500,200/700,300/500],exterior=[])]))
    # Keep indices 0..21 as production regression controls. These terminal
    # reflow probes use only HostRawTextRender's neutral 700x500 background.
    assert len(request['pages'])==22
    readability_pages=[]
    # The original six remain no-op controls. The last rectangular 260px
    # mask is a positive: 24px font, 4->9px margin, 5->6 retained rows.
    for index,width in enumerate((240,268,296,324,352,380,260)):
        left=340-width/2;top=65;height=340
        rect=[left/700,top/500,width/700,height/500]
        text='오늘 우리는 조용한 도서관에서 새로운 이야기를 읽으며 서로의 생각을 천천히 나누고 다음 여행을 함께 준비한다'
        owner=item('readability-owner',text,[310,135,60,220],24)
        owner['textAlignment']='center'
        owner['textPlacementGuide'].update(horizontal='center',vertical='center')
        owner['balloonLayoutRectNormalized']=rect
        # Alternate rectangular and gently curved masks. The supplied layout
        # starts wide; extra rows have ample vertical room but must earn actual
        # retained-alpha boundary clearance at the SAME native font and pitch.
        spans=[]
        for row in range(64):
            inset=12*(2*abs((row+.5)/64-.5))**4 if index%2 else 0
            spans.extend([(left+inset)/700,(left+width-inset)/700])
        owner['textExpansionPolicy']=dict(allowedRectNormalized=rect,candidates=[rect],
            maskCoverage=[1],backgroundRisk=[0],sourceFontPixels=24,kind='inside-balloon-mask',
            maskRectNormalized=rect,maskSpansNormalized=spans)
        peer=item('readability-peer','별도 안내',[570,425,110,40],18)
        page=dict(page='balloon-readability-'+str(index),width=700,height=500,items=[owner,peer])
        readability_pages.append(page)
    request['pages'].extend(readability_pages)
    path=out/'request.json';path.write_text(json.dumps(request,ensure_ascii=False))
    env=dict(os.environ,AIDOKU_PIPELINE_ROOT=str(ROOT),AIDOKU_BALLOON_READABILITY_REFLOW='1')
    command=['swift',str(ROOT/'Scripts/image-translation.swift'),'--native-raw-text-render',str(path),str(out/'result')]
    subprocess.run(command,env=env,cwd=ROOT,check=True)
    report=json.loads((out/'result/REPORT.json').read_text())
    assert report['sourceRGBRead']is False and report['OCRCalls']==report['providerCalls']==report['modelCalls']==0
    for page,source in zip(report['pages'],cases):
        audit=page['audit'];row=audit['rawNativeItems'][0];paint=audit['finalPaintAdmission'][0]
        x,y,w,h=paint['finalFootprintOutputPixels'];sx,sy,sw,sh=source['frame']
        assert page['complete']and page['expectedItems']==page['paintedItems']==1
        assert row['sourceUTF16']==row['visibleUTF16']
        assert row['requestedDisplayFontSize']==source['fontReference']
        assert row['fontShrunkForCapacity']==(row['fontSize']<source['fontReference']-.01)
        if source['id']in ('title','small'):
            assert w<=sw*1.35 and h<=sh*1.2+source['fontReference']*.1
            assert (x,y)==(sx,sy)and len(row['actualCoreTextLineStrings'])==1
        assert paint['peerAlphaCollisions']==0
        policy=page['expansionPolicies'][0]['policy']
        if policy['kind']=='inside-balloon-mask':
            X,Y,W,H=policy['allowedRectNormalized'];X*=700;W*=700;Y*=500;H*=500
            assert x>=X-1e-9 and y>=Y-1e-9 and x+w<=X+W+1e-9 and y+h<=Y+H+1e-9
    own,stale=[p['expansionPolicies'][0]for p in report['pages'][2:4]]
    assert own['authority']=='connected-source-contour'and own['policy']['allowedRectNormalized']==[.08,.1,.25,.5]
    assert stale['authority']=='source-associated-rf-contour'
    assert all(abs(a-b)<1e-9 for a,b in zip(stale['policy']['allowedRectNormalized'],[.01,.01,.9,.9]))
    shared=report['pages'][4]
    assert shared['expectedItems']==shared['paintedItems']==2
    assert all(r['fontSize']==40 for r in shared['audit']['rawNativeItems'])
    assert any(r['capacityExpanded']for r in shared['audit']['rawNativeItems'])
    for p in shared['expansionPolicies']:
        assert p['policy']['sourceLineWidthScale']>=2 and p['policy']['allowedRectNormalized'][2]*700>520
    tight=report['pages'][5];placed=tight['audit']['finalPaintAdmission'];raw=tight['audit']['rawNativeItems']
    assert tight['paintedItems']==2 and raw[0]['fontSize']==raw[1]['fontSize']
    for r,source in zip(placed,stacked):
        x,y,w,h=r['finalFootprintOutputPixels'];X,Y,_,_=source['frame']
        assert ((x-X)**2+(y-Y)**2)**.5<=44*3+1
        assert x>=0 and y>=470 and x+w<=1001 and y+h<=618
    compared=report['pages'][6]
    assert compared['paintedItems']==2 and compared['audit']['sourceCohortComparisonRuns']>0
    assert all(r['fontSize']==24 for r in compared['audit']['rawNativeItems'])
    assert all(r['sourceUTF16']==r['visibleUTF16']for r in compared['audit']['rawNativeItems'])
    lexical_page=report['pages'][7];lexical_row=lexical_page['audit']['rawNativeItems'][0]
    assert lexical_page['paintedItems']==1 and lexical_row['fontSize']==24
    assert lexical_row['sourceUTF16']==lexical_row['visibleUTF16']==len(lexical['text'])
    assert lexical_row['softWordCuts']==0 and lexical_row['tailRefinementOriginWidthPixels']is not None
    lx,ly,lw,lh=lexical_page['audit']['finalPaintAdmission'][0]['finalFootprintOutputPixels']
    assert lx>=210 and ly>=50 and lx+lw<=420 and ly+lh<=450 and lw>80
    expanded=report['pages'][8];erow=expanded['audit']['rawNativeItems'][0]
    epolicy=expanded['expansionPolicies'][0]['policy']
    ex,ey,ew,eh=expanded['audit']['finalPaintAdmission'][0]['finalFootprintOutputPixels']
    assert expanded['paintedItems']==1 and erow['fontSize']==40, (erow,epolicy)
    assert erow['sourceUTF16']==erow['visibleUTF16']
    assert epolicy['kind']=='source-near-limited-expansion' and epolicy['sourceLineWidthScale']>1.35
    assert ew>160*1.35 and eh<=50*1.2+40*.1
    ax,ay,aw,ah=epolicy['allowedRectNormalized']
    assert ex>=ax*700 and ey>=ay*500 and ex+ew<=(ax+aw)*700 and ey+eh<=(ay+ah)*500
    for page,angle in zip(report['pages'][9:11],[-.24,.24]):
        raw=page['audit']['rawNativeItems'][0];paint=page['audit']['finalPaintAdmission'][0]
        assert raw['sourceObservedRotationRadians']==angle and raw['rotationBeforeFinalAlphaAdmission']
        assert raw['fontSize']==32 and raw['sourceUTF16']==raw['visibleUTF16']
        assert paint['peerAlphaCollisions']==0 and paint['pageContained']
        pixels=np.asarray(Image.open(page['output']).convert('RGB')).astype(float)
        yy,xx=np.nonzero(np.max(np.abs(pixels-pixels[0,0]),axis=2)>10)
        observed=np.cov(xx,yy)[0,1]/np.var(xx,ddof=1)
        assert abs(observed-math.tan(angle))<.04,(angle,observed)
    connected=report['pages'][11];domain=connected['expansionPolicies'][0]['policy']
    assert domain['maskIntervalRowsNormalized']and any(len(row)==4 for row in domain['maskIntervalRowsNormalized'])
    assert connected['paintedItems']==1 and connected['audit']['rawNativeItems'][0]['fontSize']==32
    paint=connected['audit']['finalPaintAdmission'][0]
    assert paint['peerAlphaCollisions']==0 and paint['pageContained']
    x,y,w,h=paint['finalFootprintOutputPixels'];assert x>=455 and x+w<=630,(x,y,w,h)
    compact,prior=report['pages'][12:14]
    compactRow=compact['audit']['rawNativeItems'][0];priorRow=prior['audit']['rawNativeItems'][0]
    assert compactRow['fontSize']==priorRow['fontSize']==24
    assert compactRow['softWordCuts']==priorRow['softWordCuts']==0
    assert len(compactRow['actualCoreTextLineStrings'])<len(priorRow['actualCoreTextLineStrings'])
    for page in (compact,prior):
        raw=page['audit']['rawNativeItems'][0];paint=page['audit']['finalPaintAdmission'][0]
        assert raw['sourceUTF16']==raw['visibleUTF16']and paint['peerAlphaCollisions']==0 and paint['pageContained']
        x,y,w,h=paint['finalFootprintOutputPixels']
        assert math.hypot(x+w/2-345,y+h/2-240)<=24*.75
    anchored=report['pages'][14]
    assert anchored['complete']and anchored['paintedItems']==2
    for raw,paint in zip(anchored['audit']['rawNativeItems'],anchored['audit']['finalPaintAdmission']):
        assert raw['fontSize']==24 and raw['sourceUTF16']==raw['visibleUTF16']
        assert paint['finalFootprintOutputPixels'][1]==80 and paint['sourceClusterAnchorOutputPixels']==80
        assert paint['peerAlphaCollisions']==0 and paint['pageContained']
    for page in report['pages'][15:17]:
        assert page['complete'] and page['paintedItems']==1
        policy=page['expansionPolicies'][0]['policy']
        assert policy['kind']=='source-near-limited-expansion'
        assert np.allclose(policy['forbiddenBalloonRectNormalized'],[.3,.15,.25,.6],rtol=0,atol=1e-12)
        assert len(policy['forbiddenBalloonRowsNormalized'])==512
        raw=page['audit']['rawNativeItems'][0];paint=page['audit']['finalPaintAdmission'][0]
        assert raw['sourceUTF16']==raw['visibleUTF16']
        x,y,w,h=paint['finalFootprintOutputPixels']
        assert x+w<=210 or x>=385 or y+h<=75 or y>=375,(x,y,w,h)
    recovery=report['pages'][17]
    assert recovery['complete']and recovery['paintedItems']==3
    placements={r['owner']:r for r in recovery['audit']['finalPaintAdmission']}
    assert placements['healthy-a']['balloonBodyPlaced']and placements['healthy-b']['balloonBodyPlaced']
    assert not placements['healthy-a']['balloonCapacityFallback']and not placements['healthy-b']['balloonCapacityFallback']
    assert placements['stale-body-target']['balloonCapacityFallback']and not placements['stale-body-target']['balloonBodyPlaced']
    assert all(r['peerAlphaCollisions']==0 and r['pageContained']and r['domainContained']for r in placements.values())
    edge_page=report['pages'][18];edge_raw=edge_page['audit']['rawNativeItems'][0]
    edge_paint=edge_page['audit']['finalPaintAdmission'][0]
    assert edge_page['complete']and edge_page['paintedItems']==1
    assert edge_raw['fontSize']==24 and edge_raw['sourceUTF16']==edge_raw['visibleUTF16']
    assert edge_paint['pageEdgeMarginRefined'] and edge_paint['finalFootprintOutputPixels'][0]>=3
    assert edge_paint['pageContained']and edge_paint['domainContained']and edge_paint['peerAlphaCollisions']==0
    for bounded in report['pages'][19:21]:
        policy=bounded['expansionPolicies'][0]
        assert policy['authority']=='source-associated-rf-box-expansion-bound'
        assert policy['policy']['kind']=='source-near-limited-expansion'
        assert policy['policy'].get('maskRectNormalized')is None
        assert np.allclose(policy['policy']['allowedRectNormalized'],[82.88/700,82.88/500,194.24/700,294.24/500],atol=1e-10)
        assert bounded['complete']and bounded['paintedItems']==1
        x,y,w,h=bounded['audit']['finalPaintAdmission'][0]['finalFootprintOutputPixels']
        assert x>=82.88 and y>=82.88 and x+w<=277.12 and y+h<=377.12
        raw=bounded['audit']['rawNativeItems'][0]
        assert raw['fontSize']==24 and raw['sourceUTF16']==raw['visibleUTF16']
    untrusted=report['pages'][21]['expansionPolicies'][0]
    assert untrusted['authority']!='source-associated-rf-box-expansion-bound'
    assert untrusted['policy']['allowedRectNormalized']==[0,0,1,1]
    # Env-off comparison is intentionally restricted to the six appended pages.
    old_path=out/'readability-old.json'
    old_path.write_text(json.dumps(dict(pages=readability_pages),ensure_ascii=False))
    old_command=command[:-2]+[str(old_path),str(out/'readability-old')]
    subprocess.run(old_command,env=dict(env,AIDOKU_BALLOON_READABILITY_REFLOW='0'),cwd=ROOT,check=True)
    old_report=json.loads((out/'readability-old/REPORT.json').read_text())
    for result in (report,old_report):
        assert result['productionPainter']=='NativeAOTRawTextPainter.renderCentered'
        assert result['sourceRGBRead']is False and result['GTAtInference']is False
        assert result['OCRCalls']==result['providerCalls']==result['modelCalls']==0
    assert len(report['pages'])==29 and len(old_report['pages'])==7

    def assert_full_ownership(raw,text):
        encoded=text.encode('utf-16-le');length=len(encoded)//2;cursor=0
        assert raw['sourceUTF16']==raw['visibleUTF16']==length
        ranges=raw['lineRangesUTF16']
        assert len(ranges)==len(raw['actualCoreTextLineStrings'])
        for start,count in ranges:
            assert start==cursor and count>0 and start+count<=length,(raw['id'],ranges)
            # Strict decoding also rejects a range splitting a surrogate pair.
            encoded[2*start:2*(start+count)].decode('utf-16-le')
            cursor+=count
        assert cursor==length

    reflowed=[]
    for fixture,new,old in zip(readability_pages,report['pages'][22:],old_report['pages']):
        assert new['page']==old['page']==fixture['page']
        assert not old['audit'].get('balloonReadabilityReflowOwners',[])
        new_rows={r['id']:r for r in new['audit']['rawNativeItems']}
        old_rows={r['id']:r for r in old['audit']['rawNativeItems']}
        new_paint={r['owner']:r for r in new['audit']['finalPaintAdmission']}
        old_paint={r['owner']:r for r in old['audit']['finalPaintAdmission']}
        for page in (new,old):
            audit=page['audit']
            assert page['complete']and page['expectedItems']==page['paintedItems']==2
            assert audit['policy']=='mandatory-pureBW-outward-max2px-runtime-em'
            assert audit['paintOrder']=='all-strokes-then-all-fills'
            assert audit['finalPaintBoundsChecked']and audit['finalCompositeAlphaVerified']
            assert len(audit['endpointDecisions'])==2
            assert all(r>=2 for r in audit['outwardRadiiOutputPixels'])
            for raw,decision in zip(audit['rawNativeItems'],audit['endpointDecisions']):
                assert decision['finalEndpoint']in (0,255)
                assert raw['finalStrokeDecision']==decision
                assert raw['finalDisplayStroke']==[decision['finalEndpoint']]*3
            for paint in audit['finalPaintAdmission']:
                assert paint['pageContained']and paint['domainContained']and paint['peerAlphaCollisions']==0
        for source in fixture['items']:
            ident=source['id'];before=old_rows[ident];after=new_rows[ident]
            for raw in (before,after):
                assert_full_ownership(raw,source['text'])
                assert raw['fontSize']==raw['requestedDisplayFontSize']==source['fontReference']
                assert not raw['fontShrunkForCapacity']
            assert after['softWordCuts']<=before['softWordCuts']
            assert after['retainedLinePitchOutputPixels']==before['retainedLinePitchOutputPixels']
        peer='readability-peer'
        assert new_paint[peer]['finalFootprintOutputPixels']==old_paint[peer]['finalFootprintOutputPixels']
        assert new_rows[peer]['lineRangesUTF16']==old_rows[peer]['lineRangesUTF16']
        selected=new['audit'].get('balloonReadabilityReflowOwners',[])
        assert set(selected)<= {'readability-owner'}
        if selected:
            ident=selected[0];before=old_rows[ident];after=new_rows[ident];paint=new_paint[ident]
            row_gain=len(after['lineRangesUTF16'])-len(before['lineRangesUTF16'])
            assert row_gain in (1,2),(fixture['page'],before,after)
            assert after['balloonReadabilityReflow']and paint['balloonReadabilityReflow']
            assert paint['balloonReadabilityRowsBefore']==len(before['lineRangesUTF16'])
            assert paint['balloonReadabilityRowsAfter']==len(after['lineRangesUTF16'])
            assert new_paint[ident]['finalFootprintOutputPixels'][2]<old_paint[ident]['finalFootprintOutputPixels'][2]
            # Compare actual shared-helper alpha-margin audit, not bbox proxies.
            if 'balloonReadabilityMarginBeforePixels'in paint:
                gain=paint['balloonReadabilityMarginAfterPixels']-paint['balloonReadabilityMarginBeforePixels']
                assert gain>=max(2,math.ceil(after['fontSize']*.1))
            reflowed.append(fixture['page'])
    assert reflowed,'No real production balloon reflow among seven width/mask probes'
    assert reflowed==['balloon-readability-6'],'Positive probe must reflow; original six remain controls'
    for new,old in zip(report['pages'][22:28],old_report['pages'][:6]):
        assert not new['audit'].get('balloonReadabilityReflowOwners',[])
        assert np.array_equal(np.asarray(Image.open(new['output']).convert('RGBA')),
                              np.asarray(Image.open(old['output']).convert('RGBA')))
    positive=report['pages'][28]['audit']['finalPaintAdmission'][0]
    assert positive['balloonReadabilityMarginBeforePixels']<=6
    assert positive['balloonReadabilityMarginAfterPixels']-positive['balloonReadabilityMarginBeforePixels']>=3
    # Individual recovery has only a fragment of the page. Without complete
    # peer context it must retain the pre-reflow geometry instead of growing
    # text into unknown neighbours before the final page-wide union gate.
    partial_path=out/'readability-partial.json'
    partial_path.write_text(json.dumps(dict(pages=[dict(p,completePeerContext=False)for p in readability_pages]),ensure_ascii=False))
    partial_command=command[:-2]+[str(partial_path),str(out/'readability-partial')]
    subprocess.run(partial_command,env=env,cwd=ROOT,check=True)
    partial_report=json.loads((out/'readability-partial/REPORT.json').read_text())
    assert len(partial_report['pages'])==7
    for previous,partial in zip(old_report['pages'],partial_report['pages']):
        assert not partial['audit'].get('balloonReadabilityReflowOwners')
        assert np.array_equal(np.asarray(Image.open(previous['output']).convert('RGBA')),
                              np.asarray(Image.open(partial['output']).convert('RGBA')))
    # Duplicate owners must fail cleanly before the actual painter's dictionary boundary.
    request['pages'][0]['items']*=2;path.write_text(json.dumps(request,ensure_ascii=False))
    invalid=subprocess.run(command,env=env,cwd=ROOT,capture_output=True)
    assert invalid.returncode!=0 and b'invalidGeometry'in invalid.stderr
    proof=ROOT/'build/production-source-line-smoke';proof.mkdir(exist_ok=True)
    sources=[ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'/name for name in ('NativeAOTRawTextPainter.swift','NativeFixedFontRecovery.swift','NativeOperationalRenderExpansion.swift','NativeTextExpansionPolicy.swift','NativeFinalTextPaintAdmission.swift','NativeBalloonReadabilityReflow.swift','NativeFinalTextFlow.swift','NativeMandatoryDisplayStroke+Composer.swift','NativeMainEnsemblePipeline.swift')]
    sources.extend([ROOT/'Scripts/image-translation/HostRawTextRender.swift',Path(__file__).resolve()])
    (proof/'VERIFICATION.json').write_text(json.dumps(dict(passed=True,scenarios=len(request['pages']),duplicateOwnerRejected=True,
        sourceRGBRead=False,modelCalls=0,productionPainterExecuted=True,report=report,
        balloonReadabilityReflowPages=reflowed,balloonReadabilityEnvOffReport=old_report,incompletePeerContextCases=7,
        sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources},
        hostBinarySHA256=hashlib.sha256((ROOT/'build/image-translation-host/image-translation').read_bytes()).hexdigest()),ensure_ascii=False,indent=2))
    print('PASS production source-line fit, original font audit, UTF16 ownership, source-contour priority, stale-contour rejection, duplicate rejection')
