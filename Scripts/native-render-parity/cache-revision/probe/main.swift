import Foundation
import CoreGraphics
let size = CGSize(width:2,height:2)
let value = NativeTranslationLayout(imageSize:size,sourceRect:CGRect(origin:.zero,size:size),viewport:size,items:[])
let outputs = try (0..<32).map { _ in try JSONEncoder().encode(value) }
let different = Set(outputs).count
let roundTrips = try outputs.map { try JSONDecoder().decode(NativeTranslationLayout.self,from:$0) }
precondition(roundTrips.allSatisfy { $0 == value })
print("encodes",outputs.count,"distinct byte serializations",different,"all decoded layouts equal",true)
precondition(different > 1)
