import Foundation

@main enum NativeSegmentationConnectedWeakSmoke {
    static func reference(_ mask:[UInt8],_ p:[Float],_ q:[Float],_ w:Int,_ h:Int)->[UInt8] {
        var visited=[Bool](repeating:false,count:mask.count),result=[UInt8](repeating:0,count:mask.count)
        let limit=NativeSegmentationFinalPolicy.accepted.auxiliaryPixelGate.maximumSourceStrengthCode
        for start in mask.indices where mask[start] != 0 && !visited[start] {
            var component=[start],head=0,anchored=false;visited[start]=true
            while head<component.count {
                let i=component[head];head += 1
                if min(64,Int(ceil(max(p[i],q[i])*64-1e-6)))>limit {anchored=true}
                for j in mask.indices where !visited[j] && mask[j] != 0 && abs(j%w-i%w)<=1 && abs(j/w-i/w)<=1 {
                    visited[j]=true;component.append(j)
                }
            }
            if anchored {for i in component {result[i]=255}}
        }
        return result
    }
    static func floats(_ path:String)throws->[Float] {
        let data=try Data(contentsOf:URL(fileURLWithPath:path));precondition(data.count%4==0)
        return data.withUnsafeBytes {Array($0.bindMemory(to:Float.self))}
    }
    static func main() async throws {
        var cases=0,rejected=0,packets=0,packetPixels=0
        for (w,h) in [(1,1),(1,19),(23,1),(7,9),(17,13)] {
            let n=w*h
            for kind in 0..<8 {
                let mask=(0..<n).map { i -> UInt8 in
                    kind==0 ? 0 : kind==1 ? 255 : (i*37+kind*13)%11<6 ? 255:0
                }
                let p=(0..<n).map {i -> Float in kind==2 ? 0 : kind==3 ? 1 : Float((i*29+kind)%64)/256}
                let q=(0..<n).map {i -> Float in kind==4 ? 0 : Float((i*7+kind)%64)/256}
                let result=try NativeSegmentationFinalPolicy.connectedWeak(mask:mask,primary:p,boundary:q,width:w,height:h)
                precondition(result.mask==reference(mask,p,q,w,h))
                precondition(result.auxiliaryRemoved==mask.filter{$0 != 0}.count-result.mask.filter{$0 != 0}.count)
                precondition(zip(mask,result.mask).allSatisfy {$1==0 || $0==255})
                cases += 1
            }
        }
        // Eight-connected diagonal bridge, no flat-index row wrapping, orphan
        // nonweak observations outside the contextual mask cannot seed ownership.
        for (mask,p) in [([255,0,0,255] as [UInt8],[1,0,0,0] as [Float]),
                         ([0,255,255,0],[0,1,0,0]),([255,0,0,255],[0,1,0,0])] {
            let q=[Float](repeating:0,count:4)
            let result=try NativeSegmentationFinalPolicy.connectedWeak(mask:mask,primary:p,boundary:q,width:2,height:2)
            precondition(result.mask==reference(mask,p,q,2,2));cases += 1
        }
        // Exact original Float32 strength boundary; no new numerical gate.
        for v in [Float(12)/64,(Float(12)/64).nextUp,(Float(12)/64).nextDown,Float(13)/64] {
            let result=try NativeSegmentationFinalPolicy.connectedWeak(mask:[255],primary:[v],boundary:[0],width:1,height:1)
            precondition(result.mask==reference([255],[v],[0],1,1));cases += 1
        }
        func reject(_ m:[UInt8],_ p:[Float],_ q:[Float],_ w:Int,_ h:Int) {
            do {_=try NativeSegmentationFinalPolicy.connectedWeak(mask:m,primary:p,boundary:q,width:w,height:h);preconditionFailure("invalid accepted")}
            catch {rejected += 1}
        }
        reject([],[],[],0,1);reject([],[],[],1,0);reject([],[],[],1_500_001,1)
        reject([1],[0],[0],1,1);reject([255],[],[0],1,1);reject([255],[0],[],1,1)
        for v in [Float.nan,.infinity,-0.1,1.1] {reject([255],[v],[0],1,1);reject([255],[0],[v],1,1)}
        let cancelled=await Task.detached { () -> Bool in
            withUnsafeCurrentTask {$0?.cancel()}
            do {_=try NativeSegmentationFinalPolicy.connectedWeak(mask:[255],primary:[1],boundary:[0],width:1,height:1);return false}
            catch is CancellationError {return true} catch {return false}
        }.value
        precondition(cancelled)
        if CommandLine.arguments.count>1 {
            let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
            for row in fixtures {
                let m=Array(try Data(contentsOf:URL(fileURLWithPath:row["mask"] as! String)))
                let expected=Array(try Data(contentsOf:URL(fileURLWithPath:row["expected"] as! String)))
                let p=try floats(row["primary"] as! String),q=try floats(row["boundary"] as! String)
                let actual=try NativeSegmentationFinalPolicy.connectedWeak(mask:m,primary:p,boundary:q,width:row["width"] as! Int,height:row["height"] as! Int)
                precondition(actual.mask==expected);packets += 1;packetPixels += m.count
            }
        }
        let report:[String:Any]=["passed":true,"syntheticCases":cases,"invalidRejected":rejected,"cancelledTaskRejected":cancelled,
            "actualSavedProbabilityPackets":packets,"actualPacketPixels":packetPixels,"modelInferenceCalls":0,"trainingRuns":0]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
