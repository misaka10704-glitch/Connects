#if DEBUG
import UIKit
import PDFKit

/// Image-first Study / AI-edit visual QA.
/// Launch: `-StudyVisualQA`
/// Frames land in App Documents/`ConnectsVisualQA/<scenario>/`, then
/// `Scripts/pull-visual-qa.sh` copies them to `/tmp/connects_visual_qa/`.
/// Agent reads PNGs to judge PASS/FAIL — numeric checks are secondary.
enum StudyVisualQAHarness {
    private static let logTag = "[StudyVisualQA]"
    private static var didRun = false
    private static let visualRootName = "ConnectsVisualQA"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-StudyVisualQA") else { return }
        guard !didRun else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            runAll()
        }
    }

    private static func emit(_ message: String) {
        let line = "\(logTag) \(message)"
        NSLog("%@", line)
        fputs(line + "\n", stderr)
        fflush(stderr)
    }

    private static func visualDir(scenario: String) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs
            .appendingPathComponent(visualRootName, isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private static func capture(_ view: UIView,
                                scenario: String,
                                frame: String,
                                roi: CGRect? = nil) -> URL? {
        guard view.bounds.width > 2, view.bounds.height > 2 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(UIScreen.main.scale, 2)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let full = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let image: UIImage
        if let roi = roi, roi.width > 4, roi.height > 4 {
            let scale = full.scale
            let crop = CGRect(
                x: max(0, roi.minX) * scale,
                y: max(0, roi.minY) * scale,
                width: min(roi.width, view.bounds.width - max(0, roi.minX)) * scale,
                height: min(roi.height, view.bounds.height - max(0, roi.minY)) * scale
            )
            if let cg = full.cgImage?.cropping(to: crop) {
                image = UIImage(cgImage: cg, scale: scale, orientation: .up)
            } else {
                image = full
            }
        } else {
            image = full
        }
        guard let data = image.pngData(),
              let dir = visualDir(scenario: scenario) else { return nil }
        let url = dir.appendingPathComponent("\(frame).png")
        try? data.write(to: url, options: .atomic)
        emit("shot \(scenario)/\(frame).png \(Int(image.size.width))x\(Int(image.size.height))")
        return url
    }

    private static func runAll() {
        emit("begin visual suite → Documents/\(visualRootName)")
        runDiffVisual { diffOK in
            self.runSendScrollVisual { sendOK in
                self.runWebViewVisual { webOK in
                    self.runAIEditChainVisual { chainOK in
                        let ok = diffOK && sendOK && webOK && chainOK
                        if ok {
                            self.emit("PASS visual suite (diff+send+webview+ai-edit)")
                            self.emit("PULL /tmp/connects_visual_qa via Scripts/pull-visual-qa.sh")
                            exit(0)
                        } else {
                            self.emit("FAIL visual suite diff=\(diffOK) send=\(sendOK) web=\(webOK) chain=\(chainOK)")
                            self.emit("PULL /tmp/connects_visual_qa via Scripts/pull-visual-qa.sh")
                            exit(1)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Diff visual

    private static func runDiffVisual(completion: @escaping (Bool) -> Void) {
        let scenario = "diff"
        let editor = TextCodeEditorViewController()
        let hostVC = host(vc: editor)
        present(hostVC) {
            let before = (0..<90).map { "line_\($0)_pad_aaaaaaaa" }.joined(separator: "\n")
            let after = (0..<90).map { i -> String in
                if [12, 28, 44, 60, 76].contains(i) {
                    return "CHANGED_\(i)_xxxxxxxx"
                }
                return "line_\(i)_pad_aaaaaaaa"
            }.joined(separator: "\n")
            editor.presentInlineDiff(before: before, after: after)
            editor.view.layoutIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.capture(hostVC.view, scenario: scenario, frame: "00_t0")
                self.captureDiffROIs(editor: editor, host: hostVC.view, scenario: scenario, prefix: "00")

                func scrollStep(_ i: Int, done: @escaping () -> Void) {
                    guard i < 5 else {
                        done()
                        return
                    }
                    editor.debugScrollEditor(by: 140)
                    editor.view.layoutIfNeeded()
                    // Mid-scroll style: capture immediately after offset change.
                    self.capture(hostVC.view, scenario: scenario, frame: String(format: "01_scroll_%02d", i))
                    self.captureDiffROIs(
                        editor: editor,
                        host: hostVC.view,
                        scenario: scenario,
                        prefix: String(format: "01_scroll_%02d", i)
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollStep(i + 1, done: done)
                    }
                }

                scrollStep(0) {
                    self.capture(hostVC.view, scenario: scenario, frame: "02_scroll_end")
                    // Keep a visible on-screen hunk (first pending) without jumping viewport.
                    let pendingBefore = editor.diffPendingHunkCount
                    editor.diffKeepCurrentHunkForQA()
                    editor.view.layoutIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        self.capture(hostVC.view, scenario: scenario, frame: "03_after_keep_one")
                        self.captureDiffROIs(
                            editor: editor,
                            host: hostVC.view,
                            scenario: scenario,
                            prefix: "03_after_keep"
                        )
                        let pendingAfter = editor.diffPendingHunkCount
                        let nav = editor.debugDiffNavLabelText()
                        var ok = pendingAfter == pendingBefore - 1 || pendingAfter == 0
                        if pendingBefore < 2 { ok = false }
                        self.emit("diff pending \(pendingBefore)→\(pendingAfter) nav=\(nav) numericOK=\(ok)")
                        self.dismissPresented {
                            completion(ok)
                        }
                    }
                }
            }
        }
    }

    private static func captureDiffROIs(editor: TextCodeEditorViewController,
                                       host: UIView,
                                       scenario: String,
                                       prefix: String) {
        let bars = editor.debugDiffPerHunkBarFrames()
        for (seg, frame) in bars {
            let pad: CGFloat = 8
            let roi = frame.insetBy(dx: -pad, dy: -pad)
                .intersection(host.bounds)
            if !roi.isNull, roi.width > 4 {
                capture(host, scenario: scenario, frame: "\(prefix)_bar_seg\(seg)", roi: roi)
            }
            if let expectedY = editor.debugExpectedHunkBarY(segIdx: seg),
               let doc = editor.debugDiffHunkDocY()[seg] {
                // Hunk band: approximate vertical strip around bar + text above.
                let hunkH = max(40, doc.maxY - doc.minY + 20)
                let band = CGRect(
                    x: max(0, frame.minX - 220),
                    y: max(0, expectedY - hunkH),
                    width: min(host.bounds.width - 8, 340),
                    height: min(hunkH + 50, host.bounds.height)
                )
                capture(host, scenario: scenario, frame: "\(prefix)_hunk_seg\(seg)", roi: band)
            }
        }
    }

    // MARK: - Send scroll visual

    private static func runSendScrollVisual(completion: @escaping (Bool) -> Void) {
        let scenario = "send_scroll"
        guard let chat = findChatVC() else {
            emit("FAIL send_scroll: no ChatViewController")
            completion(false)
            return
        }
        let store = ConversationStore.shared
        // Dedicated conversation so we can reloadData cleanly (no mid-flight insert mismatch).
        _ = store.createConversation()
        store.updateCurrentQuietly { c in
            c.title = "VisualQA send-scroll"
            c.messages.removeAll()
            for i in 1...12 {
                c.messages.append(ChatMessage(role: .user, content: "Q\(i) pad " + String(repeating: "x", count: 40)))
                c.messages.append(ChatMessage(
                    role: .assistant,
                    content: "## A\(i)\n\n" + String(repeating: "Body line for visual scroll QA.\n", count: 8),
                    isStreaming: false
                ))
            }
        }
        // Sync table row count BEFORE any Study chrome / width layout that may beginUpdates.
        chat.reloadChat()
        DispatchQueue.main.async {
            chat.setStudyChrome(.documentReader)
            chat.debugSimulateLayoutWidthChange(tableWidth: 408) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    chat.debugSeedCommittedHeightsFromLayoutCache()
                    chat.debugPinToBottom {
                        chat.debugSimulateSlowScrollUp(distance: 600, duration: 0.25) {
                            self.capture(chat.view, scenario: scenario, frame: "00_away_from_bottom")
                            chat.debugVisualAppendOutgoingTurn(
                                user: "VISUAL_SEND_MARKER_USER",
                                assistant: "## VISUAL_SEND_MARKER\n\nNew bubble must appear at bottom immediately.\n\n" +
                                    String(repeating: "tail\n", count: 6)
                            ) {
                                self.capture(chat.view, scenario: scenario, frame: "01_t0_after_append")
                                DispatchQueue.main.async {
                                    self.capture(chat.view, scenario: scenario, frame: "02_t1frame")
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    self.capture(chat.view, scenario: scenario, frame: "03_t100ms")
                                    let inView = chat.debugLastAssistantNearBottom(tolerance: 120)
                                    self.emit("send_scroll lastNearBottom=\(inView)")
                                    chat.setStudyChrome(.none)
                                    chat.debugClearLayoutWidthOverride()
                                    completion(inView)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - WebView visual

    private static func runWebViewVisual(completion: @escaping (Bool) -> Void) {
        let scenario = "webview"
        let markdown = Self.tallMarkdownFixture()
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StudyVisualQA", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("visual_web.md")
            try markdown.write(to: file, atomically: true, encoding: .utf8)
            let doc = try StudyDocumentStore.shared.openDocument(from: file, forceText: false)
            let reader = MarkdownReaderViewController()
            let hostVC = host(vc: reader)
            present(hostVC) {
                reader.load(documentID: doc.id) { ok in
                    guard ok else {
                        self.emit("FAIL webview load")
                        self.dismissPresented { completion(false) }
                        return
                    }
                    self.waitReady(reader, attempts: 0) {
                        self.capture(hostVC.view, scenario: scenario, frame: "00_t0")
                        let h0 = reader.debugWebContentHeight()
                        func step(_ i: Int, done: @escaping () -> Void) {
                            guard i < 8 else {
                                done()
                                return
                            }
                            reader.debugScrollWeb(by: 180, animated: false)
                            self.capture(hostVC.view, scenario: scenario, frame: String(format: "01_mid_%02d", i))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                                step(i + 1, done: done)
                            }
                        }
                        step(0) {
                            let h1 = reader.debugWebContentHeight()
                            self.capture(hostVC.view, scenario: scenario, frame: "02_end")
                            reader.debugProbeNestedDocumentScroll { nested in
                                // contentSize may still grow slightly after KaTeX; allow modest growth.
                                let jump = abs(h1 - h0)
                                self.emit("webview h0=\(Int(h0)) h1=\(Int(h1)) jump=\(Int(jump)) nested=\(nested)")
                                let ok = h0 > 400 && !nested && jump < 1200
                                self.dismissPresented { completion(ok) }
                            }
                        }
                    }
                }
            }
        } catch {
            emit("FAIL webview open \(error.localizedDescription)")
            completion(false)
        }
    }

    private static func waitReady(_ reader: MarkdownReaderViewController, attempts: Int, done: @escaping () -> Void) {
        let h = reader.debugWebContentHeight()
        if (reader.debugWebContentReady() && h > 800) || attempts > 60 {
            // One more settle frame so KaTeX-driven contentSize stops growing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                done()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            waitReady(reader, attempts: attempts + 1, done: done)
        }
    }

    private static func tallMarkdownFixture() -> String {
        let body = (1...100).map { i in
            "Paragraph \(i): visual web QA pad text aaa bbb ccc. $x_{\(i)}$.\n"
        }.joined(separator: "\n")
        return """
        # Visual Web QA

        $$\\int_0^1 x^2\\,dx=\\frac{1}{3}$$

        ```verilog
        module v(input a, output b); assign b = a; endmodule
        ```

        \(body)
        """
    }

    // MARK: - AI edit chain (blank .v → Diff → Keep → edit)

    private static func runAIEditChainVisual(completion: @escaping (Bool) -> Void) {
        let scenario = "ai_edit_chain"
        let blankPath = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("-StudyQACode=") })
            .map { String($0.dropFirst("-StudyQACode=".count)) }
            ?? NSString(string: "~/Documents/Workspace/Engineer_Tex/.workspace/tmp/connects_blank.v").expandingTildeInPath

        let source: URL
        if FileManager.default.fileExists(atPath: blankPath) {
            source = URL(fileURLWithPath: blankPath)
        } else {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("connects_blank.v")
            try? "".write(to: tmp, atomically: true, encoding: .utf8)
            source = tmp
            emit("ai_edit using temp blank.v")
        }

        do {
            let staged = try stagingURL(for: source)
            let doc = try StudyDocumentStore.shared.openDocument(from: staged, forceText: true)
            let editor = TextCodeEditorViewController()
            let hostVC = host(vc: editor)
            present(hostVC) {
                editor.load(documentID: doc.id) { ok in
                    guard ok else {
                        self.emit("FAIL ai_edit load")
                        self.dismissPresented { completion(false) }
                        return
                    }
                    editor.debugSetEditMode(true)
                    editor.view.layoutIfNeeded()
                    self.capture(hostVC.view, scenario: scenario, frame: "00_blank_edit")
                    let proposal = """
                    module blank_fill(
                      input  wire clk,
                      output reg  q
                    );
                      always @(posedge clk) q <= ~q;
                    endmodule
                    """
                    editor.presentInlineDiff(before: "", after: proposal)
                    editor.view.layoutIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.capture(hostVC.view, scenario: scenario, frame: "01_diff_open")
                        self.captureDiffROIs(editor: editor, host: hostVC.view, scenario: scenario, prefix: "01")
                        editor.diffKeepAll()
                        editor.view.layoutIfNeeded()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.capture(hostVC.view, scenario: scenario, frame: "02_after_keep_all")
                            editor.debugSetEditMode(true)
                            editor.debugShowTabSuggestion("posedge")
                            editor.view.layoutIfNeeded()
                            self.capture(hostVC.view, scenario: scenario, frame: "03_tab_chip")
                            editor.debugAcceptTabSuggestion()
                            self.capture(hostVC.view, scenario: scenario, frame: "04_tab_accepted")
                            let pending = editor.diffPendingHunkCount
                            let chipGone = editor.debugTabSuggestChipFrame().isNull
                            let ok = pending == 0 && chipGone
                            self.emit("ai_edit pending=\(pending) chipGone=\(chipGone)")
                            self.dismissPresented { completion(ok) }
                        }
                    }
                }
            }
        } catch {
            emit("FAIL ai_edit \(error.localizedDescription)")
            completion(false)
        }
    }

    // MARK: - Host helpers (shared patterns)

    private static func stagingURL(for source: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyVisualQA", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private static func host(vc: UIViewController) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = DSTheme.c.background
        host.addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])
        vc.didMove(toParent: host)
        return host
    }

    private static func present(_ vc: UIViewController, completion: @escaping () -> Void) {
        guard let root = UIApplication.connectsKeyWindow?.rootViewController
            ?? UIApplication.connectsWindows.first?.rootViewController else {
            emit("FAIL no key window root")
            completion()
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        vc.modalPresentationStyle = .fullScreen
        top.present(vc, animated: false, completion: completion)
    }

    private static func dismissPresented(completion: @escaping () -> Void) {
        guard let root = UIApplication.connectsKeyWindow?.rootViewController
            ?? UIApplication.connectsWindows.first?.rootViewController else {
            completion()
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        if top === root {
            completion()
            return
        }
        top.dismiss(animated: false, completion: completion)
    }

    private static func findChatVC() -> ChatViewController? {
        guard let root = UIApplication.connectsKeyWindow?.rootViewController
            ?? UIApplication.connectsWindows.first?.rootViewController else {
            return nil
        }
        func walk(_ vc: UIViewController?) -> ChatViewController? {
            if let c = vc as? ChatViewController { return c }
            if let n = vc as? UINavigationController {
                for c in n.viewControllers { if let f = walk(c) { return f } }
            }
            if let t = vc as? UITabBarController {
                for c in t.viewControllers ?? [] { if let f = walk(c) { return f } }
            }
            for c in vc?.children ?? [] { if let f = walk(c) { return f } }
            if let p = vc?.presentedViewController, let f = walk(p) { return f }
            return nil
        }
        return walk(root)
    }
}
#endif
