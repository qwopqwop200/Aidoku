import Foundation

enum NativeAppearanceNumeric {
    /// CPython math.fsum partials and final half-even correction. Source width
    /// consensus uses this before rounding exactly on half-pixel boundaries.
    static func fsum(_ values:[Double])->Double {
        var partials:[Double]=[]
        for value in values {
            var x=value,index=0
            for original in partials {
                var y=original
                if abs(x)<abs(y) {swap(&x,&y)}
                let high=x+y,low=y-(high-x)
                if low != 0 {partials[index]=low;index+=1}
                x=high
            }
            partials.removeSubrange(index..<partials.count)
            if x != 0 {partials.append(x)}
        }
        guard var high=partials.popLast() else {return 0}
        var low=0.0
        while let y=partials.popLast() {
            let x=high;high=x+y;low=y-(high-x)
            if low != 0 {break}
        }
        if let last=partials.last,(low<0 && last<0) || (low>0 && last>0) {
            let y=low*2,x=high+y
            if y==x-high {high=x}
        }
        return high
    }
    static func quantile(_ values: [Double], _ probability: Double) -> Double {
        quantile(sorted: values.sorted(), probability)
    }

    static func quantile(sorted: [Double], _ probability: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let location=Double(sorted.count-1)*probability
        let low=Int(floor(location)),high=Int(ceil(location)),fraction=location-Double(low)
        return sorted[low]*(1-fraction)+sorted[high]*fraction
    }

    /// NumPy2.2 scalar aquicksort ordering, including equal-value palette bins.
    /// Introspection/insertion thresholds follow numpy/_core/src/npysort/quicksort.cpp.
    static func numpyArgSort(_ values: [Double]) -> [Int] {
        guard values.count>1 else {return Array(values.indices)}
        var order=Array(values.indices),stack:[(Int,Int,Int)]=[]
        var low=0,high=values.count-1,depth=Int(log2(Double(values.count)))*2
        func less(_ a:Int,_ b:Int)->Bool {values[a]<values[b] || (values[b].isNaN && !values[a].isNaN)}
        while true {
            if depth<0 {heap(&order,low:low,high:high,less:less)} else {
                while high-low>15 {
                    let middle=low+(high-low)/2
                    if less(order[middle],order[low]) {order.swapAt(middle,low)}
                    if less(order[high],order[middle]) {order.swapAt(high,middle)}
                    if less(order[middle],order[low]) {order.swapAt(middle,low)}
                    let pivot=order[middle]
                    var left=low,right=high-1
                    order.swapAt(middle,right)
                    while true {
                        repeat {left+=1} while less(order[left],pivot)
                        repeat {right-=1} while less(pivot,order[right])
                        if left>=right {break}
                        order.swapAt(left,right)
                    }
                    order.swapAt(left,high-1);depth-=1
                    if left-low<high-left {stack.append((left+1,high,depth));high=left-1}
                    else {stack.append((low,left-1,depth));low=left+1}
                }
                if high>low {
                    for i in (low+1)...high {
                        let value=order[i];var j=i
                        while j>low,less(value,order[j-1]) {order[j]=order[j-1];j-=1}
                        order[j]=value
                    }
                }
            }
            guard let next=stack.popLast() else {break}
            (low,high,depth)=next
        }
        return order
    }

    private static func heap(_ order:inout [Int],low:Int,high:Int,less:(Int,Int)->Bool) {
        let count=high-low+1
        guard count>1 else {return}
        var left=count/2,end=count
        while true {
            let value:Int
            if left>0 {left-=1;value=order[low+left]}
            else {
                end-=1;value=order[low+end];order[low+end]=order[low]
                if end==1 {order[low]=value;break}
            }
            var i=left,j=left*2+1
            while j<end {
                if j+1<end,less(order[low+j],order[low+j+1]) {j+=1}
                if !less(value,order[low+j]) {break}
                order[low+i]=order[low+j];i=j;j=i*2+1
            }
            order[low+i]=value
        }
    }
}
