import Foundation
import CoreGraphics
let cases:[(String,[String])] = [
("아름다운 우리 세상 함께 출발하자",["아름다운우리","세상함께","출발하자"]),
("너희 먼저 먹어.",["너희먼저","먹어."]),
("우리 세상 아름다운 미래 함께 출발하자",["우리세상","아름다운미래","함께출발하자"]),
("먼저 아름다운 우리 친구들이 함께 출발하자",["먼저아름다운","우리친구들이","함께출발하자"])]
let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:20,lineHeight:24,optimizesKoreanWrapping:false,balancesHorizontalLines:true,keepsWholeWords:true)
for (text,rows) in cases {
 let layout=NativeTranslationTypography.layout(text:text,in:CGSize(width:110,height:180),style:style)
 let actual=layout.shapedText.components(separatedBy:"\n").map { $0.filter { !$0.isWhitespace } }
 precondition(actual==rows,"Captured CSSkeepall balance differs \(actual) \(rows)")
}
let text="아주긴단어를절대로중간분할하지않는것"
let overflow=NativeTranslationTypography.layout(text:text,in:CGSize(width:35,height:200),style:style)
precondition(overflow.lineCount == 1 && overflow.shapedText == text && !overflow.fits)
print("{\"capturedWKCases\":4,\"longWordOverflow\":true,\"passed\":true,\"scope\":\"Actual macOS WK CSSkeepall balance rows, Korean 20px font,110px columns; not full page raster equality\"}")
