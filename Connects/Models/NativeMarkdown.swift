import UIKit
import CoreText

enum NativeInline {
    case text(String)
    case bold([NativeInline])
    case italic([NativeInline])
    case inlineCode(String)
    case link([NativeInline], URL?)
    case inlineMath(String)
    case lineBreak
}

enum NativeListKind {
    case unordered
    case ordered(start: Int)
}

struct NativeTable {
    enum Alignment { case left, center, right }
    let header: [[NativeInline]]
    let rows: [[[NativeInline]]]
    let alignments: [Alignment]
}

enum NativeMessageBlock {
    case paragraph([NativeInline])
    case heading(level: Int, inlines: [NativeInline])
    case list(kind: NativeListKind, items: [[NativeInline]])
    case blockquote([NativeInline])
    case codeBlock(language: String?, code: String)
    case table(NativeTable)
    case displayMath(String)
    case horizontalRule
}

struct NativeMarkdownDocument {
    let stamp: String
    let blocks: [NativeMessageBlock]
}

struct NativeFormulaArtifact {
    let image: UIImage
    let size: CGSize
    let baseline: CGFloat
}

struct NativeTextFragment {
    let attributedText: NSAttributedString
    let frame: CGRect
    let lines: [CTLine]
    let lineOrigins: [CGPoint]
    let linkRects: [(CGRect, URL)]
}

enum NativeDrawCommand {
    case text(NativeTextFragment)
    case image(UIImage, CGRect)
    case fill(CGRect, UIColor, CGFloat)
    case stroke(CGRect, UIColor, CGFloat)
    case line(CGPoint, CGPoint, UIColor, CGFloat)
}

struct NativeMessageLayout {
    let key: String
    let size: CGSize
    let commands: [NativeDrawCommand]
    let linkRects: [(CGRect, URL)]
}
