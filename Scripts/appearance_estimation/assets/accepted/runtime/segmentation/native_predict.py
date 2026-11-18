#!/usr/bin/env python3
"""Run the actual Swift segmentation implementation, not Python surrogate masks."""
import argparse
import fcntl
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
import os
import shutil
from functools import lru_cache
from pathlib import Path
import subprocess
import tempfile
import time

import numpy as np

from evaluate_gt import DEFAULT_OUT, ROOT, read, save, sha


def build(out):
    cache=ROOT/'Aidoku/build/segmentation-gt-replay-module-cache'
    cache.mkdir(parents=True,exist_ok=True)
    with (cache/'.compile.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        return build_locked(out)


def build_locked(out):
    native = ROOT / 'Aidoku/Aidoku/Core/Translation/NativeEngine'
    sources = [native / 'Layout/NativeRFDETRSemanticGrid.swift', native / 'Layout/NativeRFDETRLayoutModels.swift']
    sources.extend(native / 'Ensemble' / name for name in [
        'NativeEnsembleRemovalSourceFactory.swift', 'NativePixelRFFeatures.swift',
        'NativePixelRFForest.swift', 'NativePixelRFEvidence.swift', 'NativePixelRFSegmentation.swift'])
    sources.append(Path(__file__).with_name('NativePixelRFSegmentationReplay.swift'))
    compiler = subprocess.check_output(['xcrun', 'swiftc', '--version'])
    fingerprint = hashlib.sha256(compiler + b''.join(p.read_bytes() for p in sources)).hexdigest()
    receipt = out / 'NATIVE-SEGMENTATION-BUILD.json'; binary = out / 'native-pixel-rf-segmentation'
    shared=ROOT/'Aidoku/build/segmentation-gt-replay-module-cache/shared-native-pixel-rf-segmentation'
    shared_receipt=shared.with_suffix('.json')
    if not binary.exists() or not receipt.exists() or read(receipt)['fingerprint'] != fingerprint:
        start = time.monotonic()
        if shared.exists() and shared_receipt.exists():
            previous=read(shared_receipt)
            if previous['fingerprint']==fingerprint and previous['binarySHA256']==sha(shared):
                shutil.copy2(shared,binary)
                save(receipt,dict(previous,reusedSharedBinary=True,seconds=time.monotonic()-start))
                return binary
        command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-module-cache-path',
                   str(ROOT / 'Aidoku/build/segmentation-gt-replay-module-cache'), *map(str, sources), '-o', str(binary)]
        subprocess.run(command, check=True)
        save(receipt, dict(fingerprint=fingerprint, sources={str(p):sha(p) for p in sources},
                          seconds=time.monotonic() - start, command=command))
    current=read(receipt)
    current['binarySHA256']=sha(binary)
    if (not shared.exists() or not shared_receipt.exists() or
            read(shared_receipt).get('fingerprint')!=fingerprint or sha(shared)!=current['binarySHA256']):
        shutil.copy2(binary,shared);save(shared_receipt,current)
    save(receipt,current)
    return binary


def input_contract(message, model_hash, binary_hash):
    """Bind every actual numeric/source input; never read evaluation targets."""
    return dict(schema='native-segmentation-crop-checkpoint-v1',
        modelSHA256=model_hash, executableSHA256=binary_hash,
        width=message['width'], height=message['height'],
        polygons=message['polygons'], fontPixels=message['fontPixels'],
        rgbSHA256=sha(Path(message['rgb'])), coarseRFSHA256=sha(Path(message['coarseRF'])),
        fullRFSHA256=sha(Path(message['fullRF'])) if message.get('fullRF') else None)


def cached_result(receipt, output, contract):
    try:
        saved=read(receipt)
        if (saved['contract']!=contract or
                output.stat().st_size!=contract['width']*contract['height'] or
                sha(output)!=saved['outputSHA256']):
            return None
        return saved['nativeRecord']
    except (OSError,ValueError,KeyError,TypeError):
        return None


@lru_cache(maxsize=256)
def observation_sha(path, size, modified_ns):
    return sha(Path(path))


def observed_file(path):
    path=Path(path).resolve();stat=path.stat()
    return observation_sha(str(path),stat.st_size,stat.st_mtime_ns)


def classifier_identity(model):
    document=read(model)
    fields={k:document[k] for k in ['trees','featureCount','sourceFeatureVariant','sourceModelSHA256']}
    identity=hashlib.sha256(json.dumps(fields,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return identity,len(document['trees'])


def observation_contract(row,out,classifier_hash,binary_hash,full_rf):
    evidence={}
    if full_rf:
        folder=out/'rf-full/crops';case=folder/f'{row["id"]}.json'
        if case.exists():
            record=read(case)
            evidence=dict(cropMetadata=observed_file(case),nativeGrids=observed_file(folder/record['nativeGrids']))
        else:evidence=dict(legacyPlanes=observed_file(folder/f'{row["id"]}.npz'))
    return dict(schema='source-only-classifier-observation-v1',classifierSHA256=classifier_hash,
        executableSHA256=binary_hash,evidenceAdapterSHA256=observed_file(Path(__file__).with_name('prepare_full_rf.py')),
        producerAdapterSHA256=observed_file(__file__),
        width=row['width'],height=row['height'],polygons=row['polygons'],fontPixels=row['fontPixels'],
        rgbSHA256=observed_file(row['rgb']),coarseEvidenceSHA256=observed_file(row['rf']),fullRF=evidence)


def load_classifier_observation(path,contract,trees):
    try:
        receipt=read(path.with_suffix('.json'))
        if receipt['contract']!=contract or receipt['archiveSHA256']!=sha(path):return None
        with np.load(path) as data:
            votes=data['votes'];base=data['nativeBase']
        shape=(contract['height'],contract['width'])
        if votes.shape!=shape or base.shape!=shape or votes.dtype!=np.uint8 or base.dtype!=np.uint8 or votes.max()>trees:
            return None
        return votes.astype(np.float32)/np.float32(trees),base
    except (OSError,ValueError,KeyError,TypeError):return None


def predict_partition(payload):
    rows, output, prefix, full_rf, ordinal, split, classifier_cache = payload
    out = Path(output); destination = out / f'{prefix}native-{split}'
    records = []; reused=0
    receipts=destination/'receipts'; receipts.mkdir(exist_ok=True)
    model_hash=sha(out/f'{prefix}native-pixel-forest.json')
    binary_hash=sha(out/'native-pixel-rf-segmentation')
    classifier_hash,trees=classifier_identity(out/f'{prefix}native-pixel-forest.json') if classifier_cache else (None,None)
    if classifier_cache:
        if trees>255:raise ValueError('Classifier observation byte cache requires <=255 trees')
        classifier_cache=Path(classifier_cache);classifier_cache.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f'native-{ordinal}-', dir=out) as work:
        work = Path(work)
        with (destination / f'stderr-{ordinal}.log').open('a') as err:
            proc = subprocess.Popen([str(out / 'native-pixel-rf-segmentation'),
                                     str(out / f'{prefix}native-pixel-forest.json')],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True)
            try:
                for row in rows:
                    message = {k:row[k] for k in ['rgb', 'width', 'height', 'polygons', 'fontPixels']}
                    message.update(coarseRF=str(work / 'coarse.f32'),
                        fullRF=str(work / 'full.f32') if full_rf else None,
                        output=str(destination / f'{row["id"]}.u8'))
                    observed=None;cache_file=None
                    if classifier_cache:
                        observed=observation_contract(row,out,classifier_hash,binary_hash,full_rf)
                        key=hashlib.sha256(json.dumps(observed,sort_keys=True,separators=(',',':')).encode()).hexdigest()
                        cache_file=classifier_cache/f'{key}.npz'
                        contract=dict(schema='native-segmentation-source-checkpoint-v2',modelSHA256=model_hash,
                            width=row['width'],height=row['height'],observation=observed)
                    else:
                        with np.load(row['rf']) as data:
                            (data['support'].astype(np.float32)/255).tofile(work/'coarse.f32')
                        if full_rf:
                            from prepare_full_rf import load_case_features
                            load_case_features(row,out).tofile(work/'full.f32')
                        contract=input_contract(message,model_hash,binary_hash)
                    output_path=Path(message['output']); receipt=receipts/f'{row["id"]}.json'
                    record=cached_result(receipt,output_path,contract)
                    was_cached=record is not None
                    if record is None:
                        cached=load_classifier_observation(cache_file,observed,trees) if cache_file else None
                        if cached is not None:
                            probabilities,base=cached
                            probabilities.tofile(work/'probabilities.f32');base.tofile(work/'native-base.u8')
                            message.update(probabilities=str(work/'probabilities.f32'),nativeBase=str(work/'native-base.u8'))
                        elif cache_file:
                            with np.load(row['rf']) as data:
                                (data['support'].astype(np.float32)/255).tofile(work/'coarse.f32')
                            if full_rf:
                                from prepare_full_rf import load_case_features
                                load_case_features(row,out).tofile(work/'full.f32')
                            message.update(captureProbabilities=str(work/'probabilities.f32'),captureNativeBase=str(work/'native-base.u8'))
                        proc.stdin.write(json.dumps(message) + '\n'); proc.stdin.flush()
                        response = proc.stdout.readline()
                        if not response:
                            raise RuntimeError(f'Native segmentation failed for {row["id"]}; see stderr-{ordinal}.log')
                        record = json.loads(response)
                        if output_path.stat().st_size!=row['width']*row['height']:
                            raise RuntimeError(f'Invalid native mask size for {row["id"]}')
                        if cache_file and cached is None:
                            p=np.fromfile(work/'probabilities.f32',np.float32).reshape(row['height'],row['width'])
                            votes=np.rint(p*trees).astype(np.uint8)
                            base=np.fromfile(work/'native-base.u8',np.uint8).reshape(p.shape)
                            with cache_file.with_suffix('.lock').open('a') as lock:
                                fcntl.flock(lock,fcntl.LOCK_EX)
                                if load_classifier_observation(cache_file,observed,trees) is None:
                                    temporary=cache_file.with_suffix(f'.{os.getpid()}.tmp')
                                    with temporary.open('wb') as stream:np.savez_compressed(stream,votes=votes,nativeBase=base)
                                    temporary.replace(cache_file)
                                    save(cache_file.with_suffix('.json'),dict(contract=observed,archiveSHA256=sha(cache_file),GTRead=False))
                        save(receipt,dict(contract=contract,outputSHA256=sha(output_path),nativeRecord=record))
                    else:
                        reused+=1
                    records.append(dict(id=row['id'], checkpointReused=was_cached, **record))
                    if len(records) % 25 == 0:
                        print(f'Native {split} worker{ordinal}: {len(records)}/{len(rows)} (checkpoint reuse{reused})', flush=True)
                proc.stdin.close()
                if proc.wait() != 0:
                    raise RuntimeError(f'Native segmentation worker failed: {proc.returncode}')
            finally:
                if proc.poll() is None:
                    proc.terminate(); proc.wait()
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--full-rf', action='store_true')
    parser.add_argument('--recall-first', action='store_true')
    parser.add_argument('--split', choices=['train', 'dev', 'test'], default='dev')
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--classifier-cache',type=Path)
    args = parser.parse_args(); args.out = args.out.resolve()
    if not 1 <= args.jobs <= 16:
        parser.error('jobs must be between 1 and16')
    build(args.out)
    args.full_rf = args.full_rf or args.recall_first
    prefix = 'recall-full-rf-' if args.recall_first else ('full-rf-' if args.full_rf else '')
    model = args.out / f'{prefix}native-pixel-forest.json'
    if not model.exists():
        raise ValueError('Export the validated candidate before native prediction')
    if args.split == 'test':
        frozen = read(args.out / 'FROZEN-CANDIDATE.json')
        if sha(model) != frozen['modelSHA256'] or sha(args.out / 'evaluation-manifest.json') != frozen['manifestSHA256']:
            raise ValueError('Held-out test requires the frozen model and source split')
    rows = [r for r in read(args.out / 'evaluation-manifest.json')['items'] if r['split'] == args.split]
    # Prediction workers never receive evaluation targets, statuses or splits.
    keys = ['id', 'rgb', 'rf', 'width', 'height', 'polygons', 'fontPixels']
    rows = [{k:r[k] for k in keys} for r in rows]
    (args.out / f'{prefix}native-{args.split}').mkdir(exist_ok=True)
    start = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        partitions = [(rows[i::args.jobs], str(args.out), prefix, args.full_rf, i, args.split,
                       str(args.classifier_cache.resolve()) if args.classifier_cache else None) for i in range(args.jobs)]
        records = [r for partition in pool.map(predict_partition, partitions) for r in partition]
    save(args.out / f'{prefix}NATIVE-{args.split.upper()}-RUN.json', dict(instances=len(records),
        seconds=time.monotonic() - start, records=records, GTMaskRead=False,
        classifierObservationsReused=sum(bool(r.get('classifierObservationReused')) and not r['checkpointReused'] for r in records),
        classifierObservationsCaptured=sum(bool(r.get('classifierObservationCaptured')) and not r['checkpointReused'] for r in records),
        maskCheckpointsReused=sum(r['checkpointReused'] for r in records),
        sourceBoundRawRFExecuted=False, RFCache='verified source-bound27-channel cache' if args.full_rf else 'coarse RF cache',
        scope=('authenticated source-only classifier observations + actual native completion; no final protection/AOT'
               if args.classifier_cache else 'real native source-base/chromatic/features/forest; final protection and AOT not executed')))


if __name__ == '__main__':
    main()
