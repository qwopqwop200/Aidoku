#!/usr/bin/env python3
"""Check canonical native JSON capture without the reflective duplicate graph."""
from pathlib import Path
import argparse
import subprocess
import tempfile
import time
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--diagnostics',type=Path,help='Actual saved native-render-diagnostics stage JSON')
args=parser.parse_args()
source=(ROOT/'Scripts/image-translation/HostSupport.swift').read_text()
context=source[source.index('final class HostDumpContext:'):source.index('\nenum HostDump {')]
json_method=source[source.index('    static func json(_ value: Any)'):source.index('\nenum HostError:')]
fixture=r'''
import Foundation
import CoreGraphics
import CoreFoundation
__CONTEXT__
enum HostDump {
__JSON__
enum HostError: Error { case message(String) }
@main struct Check {
    static func capture(_ mode: String, _ object: Any, _ stage: String, _ directory: URL) throws -> Data {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let ctx=HostDumpContext(directory:directory,quiet:true)
        if mode == "old" { ctx.capture(stage,object) } else { ctx.captureJSONObject(stage,object) }
        try ctx.requireComplete()
        return try Data(contentsOf:directory.appendingPathComponent("001-"+stage+".json"))
    }
    static func main() throws {
        let dir=URL(fileURLWithPath:CommandLine.arguments[1])
        let unicode: [String:Any] = ["한글": "<\"quote\">😀\\slash/\n", "values": [true,false,NSNull(),Double(-0.0),Double.leastNonzeroMagnitude,Double.greatestFiniteMagnitude,UInt64.max] as [Any]]
        // Both native paths consume the exact Foundation-decoded producer graph.
        let data=try JSONSerialization.data(withJSONObject:unicode,options:[.sortedKeys])
        let decoded=try JSONSerialization.jsonObject(with:data)
        let stage="native-진단 \"quotes\""
        let a=try capture("old",decoded,stage,dir.appendingPathComponent("old"))
        let b=try capture("new",decoded,stage,dir.appendingPathComponent("new"))
        precondition(a==b,"Changed canonical numeric/Unicode/stage envelope bytes")
        let badFolder=dir.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at:badFolder,withIntermediateDirectories:true)
        let bad=HostDumpContext(directory:badFolder,quiet:true)
        bad.captureJSONObject("invalid",["nonfinite":Double.infinity])
        do { try bad.requireComplete(); preconditionFailure("Dropped invalid diagnostic failure") } catch {}
        precondition(!FileManager.default.fileExists(atPath:badFolder.appendingPathComponent("001-invalid.json").path))
        bad.captureJSONObject("valid-after-error",["ok":true])
        precondition(FileManager.default.fileExists(atPath:badFolder.appendingPathComponent("002-valid-after-error.json").path))
        if CommandLine.arguments.count>2 {
            let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
            let value=envelope["value"]!,name=envelope["stage"] as! String
            let before=try capture("old",value,name,dir.appendingPathComponent("actual-old"))
            let after=try capture("new",value,name,dir.appendingPathComponent("actual-new"))
            precondition(before==after,"Changed actual native diagnostic bytes")
            let oldDir=dir.appendingPathComponent("benchmark-old"),newDir=dir.appendingPathComponent("benchmark-new")
            try FileManager.default.createDirectory(at:oldDir,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:newDir,withIntermediateDirectories:true)
            let oldCtx=HostDumpContext(directory:oldDir,quiet:true),newCtx=HostDumpContext(directory:newDir,quiet:true)
            var oldTime=0.0,newTime=0.0
            for iteration in 0..<10 {
                let oldFirst=iteration%2==0
                func runOld() { let start=Date();oldCtx.capture(name,value);oldTime+=Date().timeIntervalSince(start) }
                func runNew() { let start=Date();newCtx.captureJSONObject(name,value);newTime+=Date().timeIntervalSince(start) }
                if oldFirst { runOld();runNew() } else { runNew();runOld() }
            }
            try oldCtx.requireComplete();try newCtx.requireComplete()
            print("Actual diagnostic bytes \(before.count), mean write seconds old=\(oldTime/10) new=\(newTime/10)")
        }
        print("PASS canonical bytes, finite numeric edges, Unicode/stage escaping, atomic files and recorded failures")
    }
}
'''
fixture=fixture.replace('__CONTEXT__',context).replace('__JSON__',json_method)
with tempfile.TemporaryDirectory(prefix='aidoku-json-capture-') as tmp:
    folder=Path(tmp);file=folder/'Check.swift';file.write_text(fixture);binary=folder/'check'
    start=time.monotonic();subprocess.run(['xcrun','swiftc','-O','-parse-as-library',str(file),'-o',str(binary)],check=True)
    print('Build seconds',time.monotonic()-start,flush=True)
    subprocess.run([str(binary),str(folder/'outputs'),*([str(args.diagnostics)] if args.diagnostics else [])],check=True)
