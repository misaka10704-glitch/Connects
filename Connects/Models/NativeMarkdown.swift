import UIKit
import CoreText

enum NativeMathScriptKind {
    case sub
    case sup
}

enum NativeInline {
    case text(String)
    case bold([NativeInline])
    case italic([NativeInline])
    case inlineCode(String)
    case link([NativeInline], URL?)
    case inlineMath(String)
    /// Latin/math base via iosMath + CJK script drawn with UIKit (XITS has no Han glyphs).
    case mathWithScript(base: String, script: String, kind: NativeMathScriptKind)
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
    /// Centered display row mixing iosMath fragments and CJK sub/superscripts.
    case displayMathComposite([NativeInline])
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

/// Compact Cursor-style code card in chat; tap opens a keyword-highlighted popup.
struct NativeCodeFenceFragment {
    let fullCode: String
    let language: StudyTextLanguage
    let languageLabel: String
    let previewLines: [String]
    /// Keyword-colored preview (same count as `previewLines`); drawn in the bubble bitmap.
    let previewAttributedLines: [NSAttributedString]
    let totalLineCount: Int
    let cardFrame: CGRect
    let headerFrame: CGRect
    let previewFrame: CGRect
    let font: UIFont
    let color: UIColor
    let mutedColor: UIColor
    let cardFill: UIColor
    let cardBorder: UIColor
    let lineStep: CGFloat
    let showsFade: Bool
}

struct NativeCodeFenceHit {
    let frame: CGRect
    let code: String
    let language: StudyTextLanguage
    let title: String
}

/// Wide display formula: viewport stays in the bubble; content scrolls horizontally.
struct NativeMathScrollFragment {
    let image: UIImage
    /// Visible band inside the message column.
    let viewportFrame: CGRect
    /// Natural formula size (width may exceed the viewport).
    let contentSize: CGSize
}

enum NativeDrawCommand {
    case text(NativeTextFragment)
    case codeFence(NativeCodeFenceFragment)
    case image(UIImage, CGRect)
    case mathScroll(NativeMathScrollFragment)
    case fill(CGRect, UIColor, CGFloat)
    case stroke(CGRect, UIColor, CGFloat)
    case line(CGPoint, CGPoint, UIColor, CGFloat)
}

struct NativeMessageLayout {
    let key: String
    let size: CGSize
    let commands: [NativeDrawCommand]
    let linkRects: [(CGRect, URL)]
    let codeFenceHits: [NativeCodeFenceHit]
}
