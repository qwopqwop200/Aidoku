import CoreText
import Foundation
var rows:[[String:Any]] = []
for name in ["HiraginoSans-W6","HiraginoSans-W7","HiraginoSans-W3","AppleSDGothicNeo-Bold","AppleSDGothicNeo-SemiBold"] {
    for size in [6.0,7,8.5,10,12,14,20,31.5] {
        let face = CTFontCreateWithName(name as CFString,size,nil)
        rows.append(["requested":name,"face":CTFontCopyPostScriptName(face) as String,"family":CTFontCopyFamilyName(face) as String,
                     "size":CTFontGetSize(face),"ascent":CTFontGetAscent(face),"descent":CTFontGetDescent(face),"leading":CTFontGetLeading(face)])
    }
}
print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]),encoding:.utf8)!)
