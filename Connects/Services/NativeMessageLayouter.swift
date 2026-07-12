import UIKit
import CoreText

struct NativeLayoutStyle {
    let width: CGFloat
    let bodyFontSize: CGFloat
    let appearance: String
    let colors: ThemeColors

    var keySuffix: String {
        "\(Int((width * 2).rounded()))|\(Int((bodyFontSize * 10).rounded()))|\(appearance)"
    }
}

final class NativeMessageLayouter {
    static let shared = NativeMessageLayouter()

    private final class Box: NSObject {
        let layout: NativeMessageLayout
        init(_ layout: NativeMessageLayout) { self.layout = layout }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 72
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func layout(document: NativeMarkdownDocument,
                style: NativeLayoutStyle,
                renderMissingFormulas: Bool = true) -> NativeMessageLayout {
        let phase = renderMissingFormulas ? "final" : "preview"
        let key = "native_layout_v8|\(phase)|\(document.stamp)|\(style.keySuffix)"
        if let hit = cache.object(forKey: key as NSString) {
            return hit.layout
        }
        let built = build(
            document: document,
            style: style,
            key: key,
            renderMissingFormulas: renderMissingFormulas
        )
        cache.setObject(Box(built), forKey: key as NSString, cost: Int(built.size.height * style.width))
        return built
    }

    func cachedLayout(document: NativeMarkdownDocument, style: NativeLayoutStyle) -> NativeMessageLayout? {
        let key = "native_layout_v8|final|\(document.stamp)|\(style.keySuffix)"
        return cache.object(forKey: key as NSString)?.layout
    }

    func clear() {
        cache.removeAllObjects()
    }

    private func build(document: NativeMarkdownDocument,
                       style: NativeLayoutStyle,
                       key: String,
                       renderMissingFormulas: Bool) -> NativeMessageLayout {
        var commands = [NativeDrawCommand]()
        var y: CGFloat = 0
        let width = max(style.width, 40)
        var expectReferencesList = false

        for block in document.blocks {
            switch block {
            case .paragraph(let inlines):
                expectReferencesList = false
                let attributed = attributedString(
                    inlines,
                    style: style,
                    font: bodyFont(style),
                    renderMissingFormulas: renderMissingFormulas
                )
                let height = textHeight(attributed, width: width)
                commands.append(.text(fragment(attributed, frame: CGRect(x: 0, y: y, width: width, height: height))))
                y += height + 9

            case .heading(let level, let inlines):
                let headingText = plainText(inlines).trimmingCharacters(in: .whitespacesAndNewlines)
                let isReferences = headingText == "参考来源"
                if isReferences {
                    if y > 0 {
                        y += 10
                        let ruleY = y
                        commands.append(.line(
                            CGPoint(x: 0, y: ruleY),
                            CGPoint(x: width, y: ruleY),
                            style.colors.divider.withAlphaComponent(0.7),
                            1
                        ))
                        y += 10
                    }
                    let font = UIFont.systemFont(ofSize: max(13, style.bodyFontSize - 1), weight: .semibold)
                    let attributed = attributedString(
                        inlines,
                        style: style,
                        font: font,
                        color: style.colors.textSecondary,
                        renderMissingFormulas: renderMissingFormulas
                    )
                    let height = textHeight(attributed, width: width)
                    commands.append(.text(fragment(attributed, frame: CGRect(x: 0, y: y, width: width, height: height))))
                    y += height + 6
                    expectReferencesList = true
                } else {
                    expectReferencesList = false
                    if y > 0 { y += 7 }
                    let size = style.bodyFontSize + CGFloat(max(1, 6 - level))
                    let font = UIFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
                    let attributed = attributedString(
                        inlines,
                        style: style,
                        font: font,
                        renderMissingFormulas: renderMissingFormulas
                    )
                    let height = textHeight(attributed, width: width)
                    commands.append(.text(fragment(attributed, frame: CGRect(x: 0, y: y, width: width, height: height))))
                    y += height + 7
                }

            case .list(let kind, let items):
                let asReferences = expectReferencesList
                expectReferencesList = false
                var number = 1
                if case .ordered(let start) = kind { number = start }
                let itemFont: UIFont = asReferences
                    ? UIFont.systemFont(ofSize: max(13, style.bodyFontSize - 1), weight: .regular)
                    : bodyFont(style)
                for item in items {
                    let prefix: String
                    switch kind {
                    case .unordered:
                        prefix = asReferences ? "\(number).  " : "•  "
                        if asReferences { number += 1 }
                    case .ordered:
                        prefix = "\(number).  "
                        number += 1
                    }
                    let value = NSMutableAttributedString(
                        string: prefix,
                        attributes: baseAttributes(
                            font: itemFont,
                            color: asReferences ? style.colors.textSecondary : style.colors.textPrimary
                        )
                    )
                    value.append(attributedString(
                        item,
                        style: style,
                        font: itemFont,
                        color: asReferences ? style.colors.textSecondary : nil,
                        linkStyle: asReferences ? .reference : .default,
                        renderMissingFormulas: renderMissingFormulas
                    ))
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = 0
                    paragraph.headIndent = asReferences ? 20 : 22
                    paragraph.lineSpacing = asReferences ? 3 : 4
                    value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
                    let height = textHeight(value, width: width)
                    commands.append(.text(fragment(value, frame: CGRect(x: 0, y: y, width: width, height: height))))
                    y += height + (asReferences ? 3 : 4)
                }
                y += asReferences ? 2 : 4

            case .blockquote(let inlines):
                expectReferencesList = false
                let inset: CGFloat = 14
                let attributed = attributedString(
                    inlines,
                    style: style,
                    font: bodyFont(style),
                    color: style.colors.textSecondary,
                    renderMissingFormulas: renderMissingFormulas
                )
                let height = textHeight(attributed, width: width - inset - 2)
                commands.append(.line(
                    CGPoint(x: 1.5, y: y),
                    CGPoint(x: 1.5, y: y + height),
                    style.colors.border,
                    3
                ))
                commands.append(.text(fragment(
                    attributed,
                    frame: CGRect(x: inset, y: y, width: width - inset, height: height)
                )))
                y += height + 10

            case .codeBlock(_, let code):
                expectReferencesList = false
                let padding: CGFloat = 12
                let mono = DSTheme.monoFont(size: style.bodyFontSize * 0.88)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3
                paragraph.lineBreakMode = .byCharWrapping
                let attributed = NSAttributedString(string: code, attributes: [
                    .font: mono,
                    .foregroundColor: style.colors.textPrimary,
                    .paragraphStyle: paragraph
                ])
                let textH = textHeight(attributed, width: width - padding * 2)
                let frame = CGRect(x: 0, y: y, width: width, height: textH + padding * 2)
                commands.append(.fill(frame, style.colors.surfaceHover.withAlphaComponent(0.56), 10))
                commands.append(.text(fragment(
                    attributed,
                    frame: frame.insetBy(dx: padding, dy: padding)
                )))
                y += frame.height + 11

            case .displayMath(let tex):
                expectReferencesList = false
                if !renderMissingFormulas {
                    let structuralCommands = ["\\frac", "\\dfrac", "\\sum", "\\prod", "\\int", "\\begin"]
                        .reduce(0) { $0 + tex.components(separatedBy: $1).count - 1 }
                    let lineCount = max(1, tex.components(separatedBy: "\n").count)
                    let estimated = min(
                        220,
                        max(
                            72,
                            style.bodyFontSize
                                * (3.4 + CGFloat(structuralCommands) * 0.65 + CGFloat(lineCount - 1) * 0.55)
                        )
                    )
                    y += estimated + 18
                } else if let formula = NativeFormulaRenderer.shared.artifact(
                    tex: tex,
                    fontSize: style.bodyFontSize * 1.08,
                    color: style.colors.textPrimary,
                    display: true
                ) {
                    let drawWidth = min(formula.size.width, width)
                    let scale = drawWidth / max(formula.size.width, 1)
                    let drawHeight = formula.size.height * scale
                    let frame = CGRect(x: (width - drawWidth) / 2, y: y + 6, width: drawWidth, height: drawHeight)
                    commands.append(.image(formula.image, frame))
                    y += drawHeight + 18
                } else {
                    let placeholder = renderMissingFormulas ? tex : " "
                    let fallback = NSAttributedString(
                        string: placeholder,
                        attributes: baseAttributes(font: DSTheme.monoFont(size: style.bodyFontSize), color: style.colors.textPrimary)
                    )
                    let height = textHeight(fallback, width: width)
                    commands.append(.text(fragment(fallback, frame: CGRect(x: 0, y: y, width: width, height: height))))
                    y += height + 10
                }

            case .table(let table):
                expectReferencesList = false
                let tableResult = layoutTable(
                    table,
                    originY: y,
                    width: width,
                    style: style,
                    renderMissingFormulas: renderMissingFormulas
                )
                commands.append(contentsOf: tableResult.commands)
                y += tableResult.height + 12

            case .horizontalRule:
                expectReferencesList = false
                y += 7
                commands.append(.line(
                    CGPoint(x: 0, y: y),
                    CGPoint(x: width, y: y),
                    style.colors.border,
                    1 / UIScreen.main.scale
                ))
                y += 12
            }
        }

        if y > 0 { y += 8 }
        let links: [(CGRect, URL)] = commands.flatMap { command in
            if case .text(let fragment) = command { return fragment.linkRects }
            return []
        }
        let contentBottom = commands.reduce(CGFloat(0)) { bottom, command in
            let commandBottom: CGFloat
            switch command {
            case .text(let fragment): commandBottom = fragment.frame.maxY
            case .image(_, let frame), .fill(let frame, _, _), .stroke(let frame, _, _):
                commandBottom = frame.maxY
            case .line(let start, let end, _, let width):
                commandBottom = max(start.y, end.y) + width
            }
            return max(bottom, commandBottom)
        }
        let layout = NativeMessageLayout(
            key: key,
            size: CGSize(width: width, height: ceilToPixel(max(max(y, contentBottom + 8), 1))),
            commands: commands,
            linkRects: links
        )
        return layout
    }

    private func layoutTable(_ table: NativeTable,
                             originY: CGFloat,
                             width: CGFloat,
                             style: NativeLayoutStyle,
                             renderMissingFormulas: Bool) -> (commands: [NativeDrawCommand], height: CGFloat) {
        let rows = [table.header] + table.rows
        let columnCount = max(rows.map(\.count).max() ?? 1, 1)
        let columnWidth = width / CGFloat(columnCount)
        var commands = [NativeDrawCommand]()
        var y = originY
        let padding: CGFloat = 7

        for (rowIndex, row) in rows.enumerated() {
            var cellTexts = [NSAttributedString]()
            var rowHeight: CGFloat = 34
            for column in 0..<columnCount {
                let inlines = column < row.count ? row[column] : []
                let font = UIFont.systemFont(
                    ofSize: style.bodyFontSize * 0.92,
                    weight: rowIndex == 0 ? .semibold : .regular
                )
                let text = attributedString(
                    inlines,
                    style: style,
                    font: font,
                    renderMissingFormulas: renderMissingFormulas
                )
                cellTexts.append(text)
                rowHeight = max(rowHeight, textHeight(text, width: columnWidth - padding * 2) + padding * 2)
            }
            for column in 0..<columnCount {
                let cell = CGRect(
                    x: CGFloat(column) * columnWidth,
                    y: y,
                    width: columnWidth,
                    height: rowHeight
                )
                if rowIndex == 0 {
                    commands.append(.fill(cell, style.colors.surfaceHover.withAlphaComponent(0.45), 0))
                }
                commands.append(.stroke(cell, style.colors.border, 1 / UIScreen.main.scale))
                commands.append(.text(fragment(
                    cellTexts[column],
                    frame: cell.insetBy(dx: padding, dy: padding)
                )))
            }
            y += rowHeight
        }
        return (commands, y - originY)
    }

    private enum LinkStyle {
        case `default`
        case reference
    }

    private func plainText(_ inlines: [NativeInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let text): return text
            case .bold(let children), .italic(let children), .link(let children, _):
                return plainText(children)
            case .inlineCode(let code): return code
            case .inlineMath(let tex): return tex
            case .lineBreak: return "\n"
            }
        }.joined()
    }

    private func attributedString(_ inlines: [NativeInline],
                                  style: NativeLayoutStyle,
                                  font: UIFont,
                                  color: UIColor? = nil,
                                  linkStyle: LinkStyle = .default,
                                  renderMissingFormulas: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let foreground = color ?? style.colors.textPrimary
        for inline in inlines {
            switch inline {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: baseAttributes(font: font, color: foreground)))
            case .bold(let children):
                let bold = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                result.append(attributedString(
                    children,
                    style: style,
                    font: bold,
                    color: foreground,
                    linkStyle: linkStyle,
                    renderMissingFormulas: renderMissingFormulas
                ))
            case .italic(let children):
                let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) ?? font.fontDescriptor
                result.append(attributedString(
                    children,
                    style: style,
                    font: UIFont(descriptor: descriptor, size: font.pointSize),
                    color: foreground,
                    linkStyle: linkStyle,
                    renderMissingFormulas: renderMissingFormulas
                ))
            case .inlineCode(let code):
                result.append(NSAttributedString(string: code, attributes: [
                    .font: DSTheme.monoFont(size: font.pointSize * 0.9),
                    .foregroundColor: foreground,
                    .backgroundColor: style.colors.surfaceHover.withAlphaComponent(0.65)
                ]))
            case .link(let children, let url):
                let start = result.length
                let linkColor = linkStyle == .reference ? style.colors.accent : style.colors.accent
                result.append(attributedString(
                    children,
                    style: style,
                    font: font,
                    color: linkColor,
                    linkStyle: linkStyle,
                    renderMissingFormulas: renderMissingFormulas
                ))
                let range = NSRange(location: start, length: result.length - start)
                if range.length > 0 {
                    if linkStyle == .reference {
                        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                        result.addAttribute(.underlineColor, value: linkColor.withAlphaComponent(0.35), range: range)
                    }
                    if let url = url {
                        result.addAttribute(.link, value: url, range: range)
                        result.addAttribute(.foregroundColor, value: linkColor, range: range)
                    }
                }
            case .inlineMath(let tex):
                if renderMissingFormulas, let formula = NativeFormulaRenderer.shared.artifact(
                    tex: tex,
                    fontSize: font.pointSize,
                    color: foreground,
                    display: false
                ) {
                    let attachment = NSTextAttachment()
                    attachment.image = formula.image
                    let maxHeight = font.lineHeight * 1.32
                    let heightScale = maxHeight / max(formula.size.height, 1)
                    let widthScale = (style.width * 0.92) / max(formula.size.width, 1)
                    let scale = min(min(1, heightScale), widthScale)
                    let size = CGSize(width: formula.size.width * scale, height: formula.size.height * scale)
                    let baselineOffset = (font.capHeight - size.height) / 2 - 1
                    attachment.bounds = CGRect(
                        x: 0,
                        y: baselineOffset,
                        width: size.width,
                        height: size.height
                    )
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    if renderMissingFormulas {
                        result.append(NSAttributedString(
                            string: tex,
                            attributes: baseAttributes(
                                font: DSTheme.monoFont(size: font.pointSize),
                                color: foreground
                            )
                        ))
                    } else {
                        let attachment = NSTextAttachment()
                        attachment.image = UIImage()
                        let estimatedWidth = min(
                            style.width * 0.92,
                            max(font.pointSize * 1.8, CGFloat(tex.count) * font.pointSize * 0.5)
                        )
                        attachment.bounds = CGRect(
                            x: 0,
                            y: (font.capHeight - font.lineHeight * 1.38) / 2 - 1,
                            width: estimatedWidth,
                            height: font.lineHeight * 1.38
                        )
                        result.append(NSAttributedString(attachment: attachment))
                    }
                }
            case .lineBreak:
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, color: foreground)))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(3, font.pointSize * 0.28)
        paragraph.lineBreakMode = .byWordWrapping
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func baseAttributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    private func bodyFont(_ style: NativeLayoutStyle) -> UIFont {
        UIFont.systemFont(ofSize: style.bodyFontSize)
    }

    private func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let bounds = text.boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceilToPixel(max(bounds.height + 4, 1))
    }

    private func fragment(_ text: NSAttributedString, frame: CGRect) -> NativeTextFragment {
        var linkRects = [(CGRect, URL)]()
        if text.length > 0 {
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: frame.size)
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let url = value as? URL else { return }
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                manager.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    linkRects.append((rect.offsetBy(dx: frame.minX, dy: frame.minY), url))
                }
            }
        }
        return NativeTextFragment(
            attributedText: text,
            frame: frame,
            lines: [],
            lineOrigins: [],
            linkRects: linkRects
        )
    }

    private func ceilToPixel(_ value: CGFloat) -> CGFloat {
        let scale = UIScreen.main.scale
        return ceil(value * scale) / scale
    }
}
