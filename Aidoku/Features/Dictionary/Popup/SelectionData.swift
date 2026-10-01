import CoreGraphics

struct SelectionData {
    let text: String
    let sentence: String
    let rect: CGRect
    var normalizedOffset: Int?
    var clozeOffset: Int?
}
