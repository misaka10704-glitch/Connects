import Foundation
import UIKit
import PDFKit

#if DEBUG
/// Full render + UI audit using Kimi K2.6 and local study-material prompts.
/// Launch: `-RenderAudit` [optional corpus.json path]
enum RenderAuditHarness {
    private static let logTag = "[ConnectsRenderAudit]"
    private static var didStart = false

    private struct AuditCase: Codable {
        let id: String
        let source: String
        let prompt: String
    }

    private struct AuditCorpus: Codable {
        let model: String?
        let pdfPaths: [String]?
        let cases: [AuditCase]
    }

    private struct AuditIssue: Codable {
        let caseID: String
        let kind: String
        let detail: String
    }

    static func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-RenderAudit") else { return }
        guard !didStart else { return }
        didStart = true
        DebugAPIBootstrap.loadKimiKeyIfNeeded(logTag: logTag)
        let path = corpusPath()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            run(corpusURL: path)
        }
    }

    private static func corpusPath() -> URL {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-RenderAudit"), index + 1 < args.count {
            let candidate = args[index + 1]
            if !candidate.hasPrefix("-") {
                return URL(fileURLWithPath: NSString(string: candidate).expandingTildeInPath)
            }
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return downloads.appendingPathComponent("connects-audit-corpus.json")
    }

    private static func run(corpusURL: URL) {
        let corpus = loadCorpus(url: corpusURL)
        let model = resolveModel(id: corpus.model ?? AIModelOption.kimi26.modelId)
        print("\(logTag) begin model=\(model.displayName) cases=\(corpus.cases.count)")

        var issues: [AuditIssue] = []
        issues.append(contentsOf: auditPDFs(paths: corpus.pdfPaths ?? []))

        runCasesSequentially(
            cases: corpus.cases,
            model: model,
            index: 0,
            issues: issues
        ) { finalIssues in
            writeReport(issues: finalIssues)
            let failCount = finalIssues.count
            if failCount == 0 {
                print("\(logTag) PASS all checks")
            } else {
                print("\(logTag) FAIL \(failCount) issue(s)")
                for issue in finalIssues {
                    print("\(logTag) [\(issue.kind)] \(issue.caseID): \(issue.detail)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                exit(failCount == 0 ? 0 : 1)
            }
        }
    }

    private static func loadCorpus(url: URL) -> AuditCorpus {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AuditCorpus.self, from: data),
           !decoded.cases.isEmpty {
            return decoded
        }
        print("\(logTag) using built-in corpus (missing \(url.path))")
        return AuditCorpus(
            model: AIModelOption.kimi26.modelId,
            pdfPaths: [],
            cases: [
                AuditCase(
                    id: "builtin-math",
                    source: "builtin",
                    prompt: "用 Markdown 推导样本均值方差公式，含表格、列表、块级与行内 TeX。"
                )
            ]
        )
    }

    private static func resolveModel(id: String) -> AIModelOption {
        AIModelOption.all.first { $0.modelId == id } ?? .kimi26
    }

    private static func auditPDFs(paths: [String]) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        for raw in paths {
            let path = NSString(string: raw).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard FileManager.default.fileExists(atPath: path) else {
                issues.append(AuditIssue(caseID: name, kind: "pdf-missing", detail: path))
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            do {
                _ = try StudyDocumentStore.shared.importPDF(from: url, title: name)
                print("\(logTag) pdf-import OK \(name) (\(size / 1024) KB)")
                if let doc = PDFDocument(url: url), doc.pageCount < 1 {
                    issues.append(AuditIssue(caseID: name, kind: "pdf-empty", detail: "pageCount=0"))
                }
            } catch {
                issues.append(AuditIssue(caseID: name, kind: "pdf-import", detail: error.localizedDescription))
                print("\(logTag) pdf-import FAIL \(name): \(error.localizedDescription)")
            }
        }
        return issues
    }

    private static func runCasesSequentially(
        cases: [AuditCase],
        model: AIModelOption,
        index: Int,
        issues: [AuditIssue],
        completion: @escaping ([AuditIssue]) -> Void
    ) {
        guard index < cases.count else {
            completion(issues)
            return
        }
        let item = cases[index]
        print("\(logTag) case \(index + 1)/\(cases.count): \(item.id)")
        let prompt = ChatMessage(role: .user, content: item.prompt)
        APIClient.shared.complete(
            messages: [prompt],
            model: model,
            maxTokens: 3_500,
            timeout: 180
        ) { result in
            var nextIssues = issues
            switch result {
            case .failure(let error):
                nextIssues.append(AuditIssue(caseID: item.id, kind: "api", detail: error.localizedDescription))
            case .success(let content):
                nextIssues.append(contentsOf: auditRenderedContent(content, caseID: item.id))
                seedConversationTurn(user: item.prompt, assistant: content)
            }
            runCasesSequentially(
                cases: cases,
                model: model,
                index: index + 1,
                issues: nextIssues,
                completion: completion
            )
        }
    }

    private static func auditRenderedContent(_ content: String, caseID: String) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(AuditIssue(caseID: caseID, kind: "empty-response", detail: "model returned empty"))
            return issues
        }

        let normalized = MarkdownHTMLRenderer.normalizeForRender(content)
        let document = NativeMarkdownParser.shared.parse(normalized)
        if document.blocks.isEmpty {
            issues.append(AuditIssue(caseID: caseID, kind: "parse", detail: "no blocks after parse"))
        }

        let widths: [CGFloat] = [360, 520, 680, 820]
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
                    issues.append(AuditIssue(
                        caseID: caseID,
                        kind: "layout-height",
                        detail: "w=\(Int(width)) fs=\(Int(fontSize)) height=\(final.size.height)"
                    ))
                }
                if preview.size.height > final.size.height + 8 {
                    issues.append(AuditIssue(
                        caseID: caseID,
                        kind: "preview-clips",
                        detail: "w=\(Int(width)) preview=\(preview.size.height) final=\(final.size.height)"
                    ))
                }
                let missing = countMissingFormulas(document: document, style: style)
                if missing > 0 {
                    issues.append(AuditIssue(
                        caseID: caseID,
                        kind: "formula",
                        detail: "w=\(Int(width)) missing=\(missing)"
                    ))
                }
            }
        }

        if issues.isEmpty {
            print("\(logTag) render OK \(caseID) (\(content.count) chars)")
        }
        return issues
    }

    private static func countMissingFormulas(document: NativeMarkdownDocument,
                                           style: NativeLayoutStyle) -> Int {
        var formulas: [(String, Bool)] = []
        func scan(_ inlines: [NativeInline]) {
            for inline in inlines {
                switch inline {
                case .inlineMath(let tex):
                    formulas.append((tex, false))
                case .bold(let children), .italic(let children), .link(let children, _):
                    scan(children)
                default:
                    break
                }
            }
        }
        for block in document.blocks {
            switch block {
            case .displayMath(let tex):
                formulas.append((tex, true))
            case .paragraph(let inlines), .heading(_, let inlines), .blockquote(let inlines):
                scan(inlines)
            case .list(_, let items):
                items.forEach(scan)
            case .table(let table):
                table.header.forEach(scan)
                table.rows.flatMap { $0 }.forEach(scan)
            default:
                break
            }
        }
        return formulas.filter { tex, display in
            NativeFormulaRenderer.shared.artifact(
                tex: tex,
                fontSize: style.bodyFontSize * (display ? 1.08 : 1),
                color: style.colors.textPrimary,
                display: display
            ) == nil
        }.count
    }

    private static func seedConversationTurn(user: String, assistant: String) {
        ConversationStore.shared.updateCurrentQuietly { conversation in
            conversation.model = AIModelOption.kimi26
            conversation.title = "Render Audit"
            conversation.messages.append(ChatMessage(role: .user, content: user))
            conversation.messages.append(ChatMessage(
                role: .assistant,
                content: assistant,
                isStreaming: false
            ))
        }
    }

    private static func writeReport(issues: [AuditIssue]) {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("connects-audit-report.json")
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "issueCount": issues.count,
            "issues": issues.map { ["caseID": $0.caseID, "kind": $0.kind, "detail": $0.detail] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url)
            print("\(logTag) report → \(url.path)")
        }
    }
}
#endif
