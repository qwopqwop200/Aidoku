import Foundation

/// Private portable candidate kernel, not installed in the shipping graph until
/// a whole-TRAIN/frozen-DEV operating point justifies it. No model implementation.
enum WeakPrimaryRecoveryKernel {
    enum Support: String, CaseIterable {case none,rf10,nativeSeed}
    enum Failure: Error {case invalidInput}
    static func apply(primary:[Float],nativeSeed:[UInt8],rfText:[Float],coarse:[Float],
                      width:Int,height:Int,minimumPrimary:Float,radius:Int,support:Support) throws -> [UInt8] {
        guard width>0,height>0,width<=1_500_000/height,primary.count==width*height,
              nativeSeed.count==primary.count,rfText.count==primary.count,coarse.count==primary.count*4,
              minimumPrimary.isFinite,(0...0.25).contains(minimumPrimary),(1...2).contains(radius),
              primary.allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw Failure.invalidInput}
        let n=primary.count
        var nearby=[Bool](repeating:false,count:n),mask=[UInt8](repeating:0,count:n)
        // Only original strong p pixels are anchors; recovered pixels never
        // seed further growth. One bounded source-local square neighborhood.
        for y in 0..<height {for x in 0..<width where primary[y*width+x]>=0.25 {
            mask[y*width+x]=255
            for yy in max(0,y-radius)...min(height-1,y+radius) {
                for xx in max(0,x-radius)...min(width-1,x+radius) {nearby[yy*width+xx]=true}
            }
        }}
        for i in 0..<n where nearby[i] && mask[i]==0 && primary[i]>=minimumPrimary {
            let allow:Bool
            switch support {
            case .none:allow=true
            case .nativeSeed:allow=nativeSeed[i] != 0
            case .rf10:
                let text=rfText[i],a=coarse[i*4],b=coarse[i*4+1]
                guard text.isFinite,a.isFinite,b.isFinite else {throw Failure.invalidInput}
                allow=max(text,max(a,b))>=0.1
            }
            if allow {mask[i]=255}
        }
        return mask
    }
}

@main enum Smoke {
    static func main() throws {
        var random:UInt64=20261118,cases=[[String:Any]]()
        func next()->UInt64 {random=random &* 6364136223846793005 &+ 1;return random}
        let levels:[Float]=[0,0.001,0.01,0.03,0.05,0.1,0.2,0.25,0.5,1]
        for (w,h) in [(1,1),(8,1),(1,8),(7,9),(17,11)] {
            let n=w*h
            let p=(0..<n).map {_ in levels[Int(next()%UInt64(levels.count))]}
            let native=(0..<n).map {_ -> UInt8 in next()%3==0 ? 255 : 0}
            let rf=(0..<n).map {_ in levels[Int(next()%UInt64(levels.count))]}
            let codes=(0..<(n*4)).map {_ in UInt8(next()%256)}
            let coarse=codes.map {Float($0)/255}
            for (index,floor) in [Float(0.01),0.05,0.1].enumerated() {for radius in [1,2] {for support in WeakPrimaryRecoveryKernel.Support.allCases {
                let mask=try WeakPrimaryRecoveryKernel.apply(primary:p,nativeSeed:native,rfText:rf,coarse:coarse,
                    width:w,height:h,minimumPrimary:floor,radius:radius,support:support)
                cases.append(["width":w,"height":h,"p":p,"native":native,"rf":rf,"coarseCodes":codes,
                    "floorIndex":index,"radius":radius,"support":support.rawValue,"mask":mask])
            }}}
        }
        print(String(data:try JSONSerialization.data(withJSONObject:["cases":cases,"actualModelCalls":0],options:[.sortedKeys]),encoding:.utf8)!)
    }
}
