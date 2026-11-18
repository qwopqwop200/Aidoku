"""Cross-language binding regression using the actual host hash and consumer."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import operational_appearance as live


class HostAppearanceBindingTests(unittest.TestCase):
    def test_fresh_python_packet_matches_host_hashes_and_rejects_tampering(self):
        repo=Path(__file__).resolve().parents[2]
        source=(repo/'Scripts/image-translation/HostOperationalAppearance.swift').read_text()
        method=source[source.index('    static func checkpointBinding('):source.index('    private final class RFResult:')]
        with tempfile.TemporaryDirectory(prefix='aidoku-host-style-binding-') as temp:
            folder=Path(temp);assets=folder/'assets';assets.mkdir()
            names=live.MODEL_FILES+live.POLICY_FILES
            for name in names:(assets/name).write_bytes(('independent artifact '+name).encode())
            runtime=live.OperationalAppearance(assets)
            rgb=np.full((8,9,3),240,np.uint8);mask=np.ones((8,9),np.uint8)
            arrays=dict(rgb=rgb,mask=mask,context=mask.copy(),rf=np.full((8,9,27),.25,np.float32),
                        segPrimary=np.full((8,9),.8,np.float32),segBoundary=np.full((8,9),.7,np.float32),
                        ocr=np.zeros((8,9,8),np.float32))
            geometry=dict(polygons=[[[1.,1.],[7.5,1.],[7.,6.],[1.,6.]]],
                          mergedPolygon=[[1.,1.],[7.5,1.],[7.,6.],[1.,6.]],fontPixels=12.)
            prediction=dict(fill=dict(rgb=[20,30,40]),outline=dict(present=False,rgb=[255]*3,widthPx=0),
                            background=dict(rgb=[240]*3),shadow=dict(present=False,rgb=None,offsetPx=None))
            with patch('operational_appearance._run_source_inference',return_value=prediction):
                packet=runtime.estimate(rgb=rgb,mask=mask,context_mask=arrays['context'],rf=arrays['rf'],
                    primary=arrays['segPrimary'],boundary=arrays['segBoundary'],ocr=arrays['ocr'],geometry=geometry,
                    rf_model_weights_sha256='a'*64)
            (folder/'packet.json').write_text(json.dumps(packet))
            (folder/'geometry.json').write_bytes(live.canonical(geometry))
            (folder/'names.json').write_text(json.dumps(names))
            for name,array in arrays.items():array.tofile(folder/(name+'.raw'))
            swift='''import Foundation
import CryptoKit
enum HostOperationalAppearance {
'''+method+'''}
@main enum BindingSmoke {
    static func main() throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1])
        func read(_ name:String) throws -> Data {try Data(contentsOf:folder.appendingPathComponent(name))}
        func sha(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
        let names=try JSONDecoder().decode([String].self,from:read("names.json"))
        let artifacts=try Dictionary(uniqueKeysWithValues:names.map {($0,sha(try read("assets/"+$0)))})
        let checkpoint=try HostOperationalAppearance.checkpointBinding(artifacts)
        // Reproduce the old Foundation ordering bug so this regression cannot
        // accidentally pass without exercising mixed-case canonicalization.
        let old=sha(try JSONSerialization.data(withJSONObject:artifacts,options:[.sortedKeys,.withoutEscapingSlashes]))
        precondition(old != checkpoint)
        var expected:[String:String]=[:]
        for name in ["rgb","mask","context","rf","segPrimary","segBoundary","ocr"] {
            expected[name+"SHA256"]=sha(try read(name+".raw"))
        }
        expected["geometrySHA256"]=sha(try read("geometry.json"))
        expected["rfModelWeightsSHA256"]=String(repeating:"a",count:64)
        expected["checkpointSHA256"]=checkpoint
        let packet=try read("packet.json")
        _ = try NativeOperationalAppearance.apply(packet:packet,expectedBinding:expected,to:[:])
        expected["checkpointSHA256"]=old
        var rejected=false
        do {_ = try NativeOperationalAppearance.apply(packet:packet,expectedBinding:expected,to:[:])}
        catch NativeOperationalAppearance.Failure.sourceMismatch {rejected=true}
        precondition(rejected,"Mismatched checkpoint binding was admitted")
        print("PASS all10 independent host hashes, canonical mixed-case checkpoint, tampering refusal")
    }
}
'''
            main=folder/'BindingSmoke.swift';main.write_text(swift);binary=folder/'binding'
            subprocess.run(['swiftc',str(main),str(repo/'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeOperationalAppearance.swift'),
                            '-o',str(binary)],check=True,capture_output=True,text=True)
            result=subprocess.run([str(binary),str(folder)],check=True,capture_output=True,text=True)
            self.assertIn('PASS all10',result.stdout)


if __name__=='__main__':unittest.main()
