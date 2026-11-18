"""Keep field calibration independent: choose a fresh or retained source encoder on DEV."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
from optimize_appearance import read,save,assign_splits,split,digest
from paint_palette_metrics import measure

FILES=['pixel-role-model.pkl','PIXEL-ROLE-RESULTS.json','predictions-with-width.json']


def quality(folder,rows):
    predictions=read(folder/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in predictions]:raise ValueError('Pixel context/item correspondence changed')
    indices=[i for i,r in enumerate(rows) if split(r)=='dev'];pp=[predictions[i] for i in indices]
    return dict(points=read(folder/'PIXEL-ROLE-RESULTS.json')['selected']['dev'],
        palette=measure([rows[i] for i in indices],pp,[p['pixelRoleEvidence']['roles']['fill']['observedColours'] for p in pp]))


def acceptable(candidate,reference):
    a,b=candidate['points'],reference['points'];x,y=candidate['palette'],reference['palette']
    return (a['accuracy']>=b['accuracy'] and a['macroF1']>=b['macroF1'] and
        all(a['confusion'][i][i]>=b['confusion'][i][i] for i in range(4)) and
        x['colourRecall']>=y['colourRecall'] and x['annotatedColourPrecision']>=y['annotatedColourPrecision'])


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','reference-estimator','source-root','masks','ocr-evidence']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args();root=args.estimator;scripts=Path(__file__).resolve().parent
    if root.resolve()==args.reference_estimator.resolve():raise ValueError('Pixel selection requires a separate candidate checkpoint')
    rows=read(args.gt)['items'];assign_splits(rows);reference=quality(args.reference_estimator,rows);fresh=quality(root,rows);report=dict(referenceDEV=reference,freshDEV=fresh,selected='fresh',GTAtInference=False,GTChanged=False,TESTUsedForSelection=False)
    path=root/'PIXEL-CONTEXT-SELECTION.json'
    if acceptable(fresh,reference):save(path,report);print('Fresh pixel calibration preserves DEV point and paint evidence',flush=True);return
    if read(args.reference_estimator/'SOURCE-POLICY.json')['inputGTSHA256']!=digest(args.gt):
        report.update(referenceUnavailable='GT supervision changed');save(path,report);return
    backup=root/'.pixel-context-backup';backup.mkdir(exist_ok=True)
    for name in FILES:shutil.copyfile(root/name,backup/name)
    def restore():
        for name in FILES:shutil.copyfile(backup/name,root/name)
    try:
        candidate=root/'pixel-context-reference'
        subprocess.run([sys.executable,str(scripts/'retain_pixel_feature_context.py'),'--gt',str(args.gt),'--estimator',str(root),
            '--reference-estimator',str(args.reference_estimator),'--out',str(candidate)],check=True)
        command=[sys.executable,str(scripts/'apply_pixel_roles.py')]
        for key,value in dict(gt=args.gt,estimator=root,source_root=args.source_root,masks=args.masks,ocr_evidence=args.ocr_evidence,
            model=candidate/'pixel-role-model.pkl',validation=candidate/'VALIDATION.json',jobs=args.jobs).items():command.extend(['--'+key.replace('_','-'),str(value)])
        subprocess.run([*command,'--validate-points'],check=True)
        retained=quality(root,rows);report['retainedDEV']=retained
        if acceptable(retained,reference):report['selected']='independent-source-context'
        else:restore();report['retainedRejected']=True
        save(path,report);print('Pixel calibration selected',report['selected'],flush=True)
    except Exception:
        restore();raise
    finally:shutil.rmtree(backup)


if __name__=='__main__':main()
