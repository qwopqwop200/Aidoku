import Foundation
struct Input:Codable {
 var text:String;var font:Double;var lineHeightRatio:Double;var usableWidth:Double;var usableHeight:Double
 var automaticRecovery:Bool;var hasReference:Bool;var vertical:Bool;var sourceVertical:Bool;var script:String
 var fittedFont:Double;var lines:Int?;var refinement:Int;var readable:Int;var probe:Int
}
let entries=try JSONDecoder().decode([Input].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
let output=entries.map { i -> [String:Any] in
 var session=NativeParagraphReferenceRecovery.Session(probeRemaining:i.probe)
 var trace:[String]=[]
 let entry=NativeParagraphReferenceRecovery.Entry(text:i.text,font:i.font,lineHeightRatio:i.lineHeightRatio,usableWidth:i.usableWidth,usableHeight:i.usableHeight,automaticRecovery:i.automaticRecovery,hasReference:i.hasReference,vertical:i.vertical,sourceVertical:i.sourceVertical,script:i.script)
 let proposal=NativeParagraphReferenceRecovery.propose(entry,session:&session,refinementRemaining:i.refinement,readableRemaining:i.readable,
  fitFont:{trace.append("fit");return i.fittedFont},measureLines:{font in trace.append("profile");return i.lines})
 let record:[String:Any]?=proposal.map {["font":$0.font,"additionalLines":$0.additionalLines,"maximum":12]}
 return ["proposal":record ?? NSNull(),"probe":session.probeRemaining,"trace":trace]
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
