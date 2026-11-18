#!/usr/bin/env python3
"""Exercise the exact production raw-byte pool across its former64MB boundary.

No OCR, images, network or app build. Optional --input accepts saved JSON/gzip.
"""
import argparse
import fcntl
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
@main enum LargeRawPoolRegression {
    static func main() {
        do { try run() }
        catch { fputs("raw-pool regression: \(error)\n",stderr);exit(1) }
    }
    static func run() throws {
        let input:Data
        if CommandLine.arguments.count>1 {
            input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        } else {
            let raw:[String:Any]=["text":"</script> 한글 🧪", "large":String(repeating:"owned-evidence-",count:75_000),
                "typed":[true,false,1,0,1.25,NSNull(),["quote":"\\\""],[]] as [Any]]
            let records=(0..<72).map { i in ["id":i,"raw":raw] as [String:Any] }
            input=try JSONSerialization.data(withJSONObject:["stages":[["records":records]],
                "metrics":[["measured":false,"unknown":NSNull()]]],options:[.sortedKeys])
        }
        guard input.count>64_000_000 else{throw CocoaError(.fileReadCorruptFile)}
        let start=ProcessInfo.processInfo.systemUptime
        let (packed,unique,refs)=try HostAnalysisRawPool.pack(input)
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let envelope=try JSONSerialization.jsonObject(with:packed) as! [String:Any]
        var data=envelope["data"] as! [String:Any]
        var stages=data["stages"] as! [[String:Any]]
        let pool=envelope["rawPool"] as! [Any]
        for ref in envelope["rawRefs"] as! [[Int]] {
            var records=stages[ref[0]]["records"] as! [[String:Any]]
            records[ref[1]]["raw"]=pool[ref[2]]
            stages[ref[0]]["records"]=records
        }
        data["stages"]=stages
        let restored=try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys])
        guard input==restored,packed.count<input.count,refs>unique else{throw CocoaError(.fileReadCorruptFile)}
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any]=["passed":true,"sourceBytes":input.count,"packedBytes":packed.count,
            "uniqueRawValues":unique,"rawReferences":refs,"canonicalRoundTripByteExact":true,
            "poolSeconds":elapsed,"peakRSSBytes":usage.ru_maxrss,
            "inputSHA256":SHA256.hash(data:input).map{String(format:"%02x",$0)}.joined()]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    source = ROOT / "Scripts/image-translation/HostAnalysis.swift"
    pin = hashlib.sha256(source.read_bytes()).hexdigest()
    cache = ROOT / "build/host-analysis-large-pool-test"
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aidoku-large-raw-pool-") as temporary:
        folder = Path(temporary)
        entry = cache / "LargeRawPool.swift"
        binary = cache / "raw-pool-test"
        snapshot = source.read_text() + HARNESS
        fingerprint = hashlib.sha256(snapshot.encode()).hexdigest()
        stamp = cache / "fingerprint"
        build_start = time.monotonic()
        with (cache / "build.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            reused = binary.exists() and stamp.exists() and stamp.read_text() == fingerprint
            if not reused:
                if not entry.exists() or entry.read_text() != snapshot:
                    entry.write_text(snapshot)
                mapping = {"": {"swift-dependencies": str(cache / "master.swiftdeps")}, str(entry): {
                    "object": str(cache / "LargeRawPool.o"),
                    "swift-dependencies": str(cache / "LargeRawPool.swiftdeps")}}
                output_map = cache / "output-map.json"
                output_map.write_text(json.dumps(mapping))
                subprocess.run(["xcrun", "swiftc", "-O", "-incremental", "-j1", "-parse-as-library", str(entry),
                                "-output-file-map", str(output_map), "-module-name", "HostAnalysisLargePoolTest",
                                "-module-cache-path", str(ROOT / "build/image-translation-host/module-cache"),
                                "-o", str(binary)], check=True, capture_output=True)
                stamp.write_text(fingerprint)
        build_seconds = time.monotonic() - build_start
        command = [str(binary)]
        if args.input:
            candidate = args.input
            if candidate.suffix == ".gz":
                candidate = folder / "input.json"
                with gzip.open(args.input, "rb") as stream:
                    candidate.write_bytes(stream.read())
            command.append(str(candidate.resolve()))
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr[-2000:])
        value = json.loads(result.stdout)
        assert value["passed"] and value["canonicalRoundTripByteExact"]
        assert hashlib.sha256(source.read_bytes()).hexdigest() == pin
        report = {**value, "sourceSHA256": pin, "buildSeconds": build_seconds,
                  "buildReused": reused,
                  "scope": "production byte pool; no OCR/render/device measurement"}
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
        print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
