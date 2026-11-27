import Foundation
import UIKit

#if DEBUG
enum RenderAuditChecks {
    struct Issue {
        let caseID: String
        let kind: String
        let detail: String
    }

    static func auditAssistantContent(_ content: String, caseID: String) -> [Issue] {
        var issues: [Issue] = []
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(caseID: caseID, kind: "empty-response", detail: "no assistant text"))
            return issues
        }
        let normalized = MarkdownHTMLRenderer.normalizeForRender(content)
        let document = NativeMarkdownParser.shared.parse(normalized)
        if document.blocks.isEmpty {
            issues.append(Issue(caseID: caseID, kind: "parse", detail: "no blocks"))
            return issues
        }
        let widths: [CGFloat] = [360, 520, 680]
        let fontSizes: [CGFloat] = [14, 16, 18]
        for width in widths {
            for fontSize in fontSizes {
                let style = NativeLayoutStyle(
                    width: width,
                    bodyFontSize: fontSize,
                    appearance: SettingsManager.shared.appearanceMode.rawValue,
                    colors: DSTheme.c
                )
                let preview = NativeMessageLayouter.shared.layout(
                    document: document,
                    style: style,
                    renderMissingFormulas: false
                )
                let final = NativeMessageLayouter.shared.layout(document: document, style: style)
                if final.size.height < 24 {
                    issues.append(Issue(
                        caseID: caseID,
                        kind: "layout-height",
                        detail: "w=\(Int(width)) h=\(final.size.height)"
                    ))
                }
                if final.size.height > preview.size.height + 8 {
                    issues.append(Issue(
                        caseID: caseID,
                        kind: "preview-clipped",
                        detail: "w=\(Int(width)) preview=\(preview.size.height) final=\(final.size.height)"
                    ))
                }
                let missing = countMissingFormulas(document: document, style: style)
                if missing > 0 {
                    issues.append(Issue(
                        caseID: caseID,
                        kind: "formula",
                        detail: "w=\(Int(width)) missing=\(missing)"
                    ))
                }
            }
        }
        return issues
    }

    private static func countMissingFormulas(document: NativeMarkdownDocument,
                                           style: NativeLayoutStyle) -> Int {
        var formulas: [(String, Bool)] = []
        func scan(_ inlines: [NativeInline]) {
            for inline in inlines {
                switch inline {
                case .inlineMath(let tex): formulas.append((tex, false))
                case .mathWithScript(let base, _, _): formulas.append((base, false))
                case .bold(let c), .italic(let c), .link(let c, _): scan(c)
                default: break
                }
            }
        }
        for block in document.blocks {
            switch block {
            case .displayMath(let tex): formulas.append((tex, true))
            case .displayMathComposite(let inlines): scan(inlines)
            case .paragraph(let inlines), .heading(_, let inlines), .blockquote(let inlines): scan(inlines)
            case .list(_, let items, _): items.forEach(scan)
            case .table(let table):
                table.header.forEach(scan)
                table.rows.flatMap { $0 }.forEach(scan)
            default: break
            }
        }
        return formulas.filter { tex, display in
            if tex.contains("\\begin{") || tex.contains("\\color{") || tex.contains("\\multicolumn") {
                return false
            }
            return NativeFormulaRenderer.shared.artifact(
                tex: tex,
                fontSize: style.bodyFontSize * (display
                    ? NativeMessageLayouter.displayMathScale
                    : NativeMessageLayouter.inlineMathScale),
                color: style.colors.textPrimary,
                display: display,
                maxWidth: max(style.width, 40)
            ) == nil
        }.count
    }
}
#endif
