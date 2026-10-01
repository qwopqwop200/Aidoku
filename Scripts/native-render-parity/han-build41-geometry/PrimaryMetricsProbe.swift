import CoreText
import Foundation
let rows = [19.0,20,20.5,21].map { s -> [String:Any] in
 let f=CTFontCreateWithName("PingFangSC-Semibold" as CFString,s,nil)
 return ["size":s,"ascent":CTFontGetAscent(f),"descent":CTFontGetDescent(f),"leading":CTFontGetLeading(f),"name":CTFontCopyPostScriptName(f) as String]
}
print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
