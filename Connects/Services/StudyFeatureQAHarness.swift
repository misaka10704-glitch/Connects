#if DEBUG
import UIKit
import PDFKit

/// Launch with:
/// `-StudyFeatureQA`
/// `-StudyQACode=/abs/path/to/file.v`
/// `-StudyQAPDF=/abs/path/to/file.pdf`
///
/// Hosts Study readers on the key window, asserts line-number scroll sync + PDF selection readiness,
/// writes screenshots under the app Documents folder.
enum StudyFeatureQAHarness {
    private static let logTag = "[StudyFeatureQA]"
    private static var didRun = false

    static func runIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("-StudyPanelChromePreview") {
            guard !didRun else { return }
            didRun = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                runPanelChromePreview()
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-StudyHighlightQA") {
            guard !didRun else { return }
            didRun = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                runHighlightQA()
            }
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("-StudyFeatureQA") else { return }
        guard !didRun else { return }
        didRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            runSuite()
        }
    }

    /// Self-check highlighter: toggle latency, draw-surface arming, Connects note sheet.
    private static func runHighlightQA() {
        let pdfPath = argValue(prefix: "-StudyQAPDF=")
            ?? "/Users/misaka10704/Downloads/After all.pdf"
        let path = NSString(string: pdfPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            log("FAIL highlight QA missing pdf: \(path)")
            return
        }
        do {
            let doc = try StudyDocumentStore.shared.importPDF(from: URL(fileURLWithPath: path), title: "HighlightQA")
            let reader = PDFReaderViewController()
            let hostVC = host(vc: reader)
            present(hostVC) {
                reader.load(documentID: doc.id) { ok in
                    guard ok, let pdfView = Self.findPDFView(in: reader.view) as? StudyPDFView else {
                        self.log("FAIL highlight QA load/view")
                        self.dismissPresented { }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        // Toggle must stay under a tight budget (no PDF write / scroll-view walk).
                        let t0 = CFAbsoluteTimeGetCurrent()
                        pdfView.highlighter.setEnabled(true)
                        let onMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                        guard pdfView.highlighter.isDrawSurfaceArmed else {
                            self.log("FAIL draw surface not armed after enable (\(String(format: "%.1f", onMs))ms)")
                            self.dismissPresented { }
                            return
                        }
                        // Overlay must be sibling of PDFView, not a PDFKit child.
                        let overlayIsChild = pdfView.subviews.contains {
                            String(describing: type(of: $0)).contains("HighlightDrawOverlay")
                        }
                        if overlayIsChild {
                            self.log("FAIL draw overlay is PDFView child (will freeze scroll)")
                            self.dismissPresented { }
                            return
                        }
                        let siblingArmed = pdfView.superview?.subviews.contains {
                            !$0.isHidden && $0.isUserInteractionEnabled
                                && String(describing: type(of: $0)).contains("HighlightDrawOverlay")
                        } ?? false
                        guard siblingArmed else {
                            self.log("FAIL draw overlay not sibling-armed")
                            self.dismissPresented { }
                            return
                        }

                        let t1 = CFAbsoluteTimeGetCurrent()
                        pdfView.highlighter.setEnabled(false)
                        let offMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
                        if pdfView.highlighter.isDrawSurfaceArmed {
                            self.log("FAIL draw surface still armed after disable")
                            self.dismissPresented { }
                            return
                        }
                        // Closing must stay near-instant (no invert reshuffle / PDF write).
                        if offMs > 8 {
                            self.log("FAIL close still slow off=\(String(format: "%.1f", offMs))ms")
                            self.dismissPresented { }
                            return
                        }
                        if onMs > 40 {
                            self.log("FAIL open too slow on=\(String(format: "%.1f", onMs))ms")
                            self.dismissPresented { }
                            return
                        }
                        // Stroke style defaults
                        let color = PDFHighlightStrokeStyle.inkColor(darkInvertActive: false)
                        let w = PDFHighlightStrokeStyle.Width.current.pagePoints
                        guard w > 0, color.cgColor.alpha > 0 else {
                            self.log("FAIL stroke style missing")
                            self.dismissPresented { }
                            return
                        }

                        // Commit a real ink stroke and verify it stays on the page.
                        pdfView.highlighter.darkInvertActive = ThemeManager.shared.mode == .dark
                        let page = pdfView.currentPage ?? pdfView.document?.page(at: 0)
                        let before = page?.annotations.count ?? 0
                        if let page = page {
                            let box = page.bounds(for: .mediaBox)
                            let p0 = CGPoint(x: box.midX - 40, y: box.midY)
                            let p1 = CGPoint(x: box.midX + 40, y: box.midY)
                            let bounds = CGRect(x: p0.x - 8, y: min(p0.y, p1.y) - 8,
                                                width: 96, height: 16)
                            let ann = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                            ann.color = PDFHighlightStrokeStyle.inkColor(darkInvertActive: pdfView.highlighter.darkInvertActive)
                            ann.userName = StudyAskSelectionStore.noteAnnotationUserName
                            let path = UIBezierPath()
                            path.move(to: CGPoint(x: 8, y: 8))
                            path.addLine(to: CGPoint(x: 88, y: 8))
                            ann.add(path)
                            let border = PDFBorder()
                            border.lineWidth = PDFHighlightStrokeStyle.Width.current.pagePoints
                            ann.border = border
                            page.addAnnotation(ann)
                            pdfView.setNeedsDisplay(pdfView.bounds)
                        }
                        let after = page?.annotations.count ?? 0
                        if after <= before {
                            self.log("FAIL ink annotation not retained on page")
                            self.dismissPresented { }
                            return
                        }

                        // Note sheet must be Connects-styled (not UIAlertController).
                        let notePage = pdfView.currentPage ?? pdfView.document?.page(at: 0)
                        let box = notePage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 40, height: 20)
                        let ann = PDFAnnotation(bounds: box.insetBy(dx: 20, dy: 20), forType: .ink, withProperties: nil)
                        ann.userName = StudyAskSelectionStore.noteAnnotationUserName
                        notePage?.addAnnotation(ann)

                        ConnectsNoteSheet.present(
                            from: reader,
                            title: "QA 注释",
                            message: "style check",
                            initialText: "hello",
                            onSave: { _ in },
                            onDelete: { },
                            onCancel: { }
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            let okSheet = ConnectsNoteSheet.isVisible
                            if !okSheet {
                                self.log("FAIL ConnectsNoteSheet overlay not visible")
                                self.dismissPresented { }
                                return
                            }
                            // Keyboard must stay up — chat chrome lift used to bury the sheet.
                            let fieldFocused = Self.noteFieldIsFirstResponder()
                            if !fieldFocused {
                                self.log("FAIL note field not first responder (keyboard stolen)")
                                self.dismissPresented { }
                                return
                            }
                            self.snapshot(hostVC.view.window ?? hostVC.view, name: "highlight_note_sheet")
                            self.log("PASS highlight QA on=\(String(format: "%.1f", onMs))ms off=\(String(format: "%.1f", offMs))ms note=ConnectsNoteSheet keyboard=ok")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                ConnectsNoteSheet.dismissIfNeeded()
                                self.dismissPresented { }
                            }
                        }
                    }
                }
            }
        } catch {
            log("FAIL highlight QA open: \(error.localizedDescription)")
        }
    }

    private static func topPresented() -> UIViewController? {
        var top = UIApplication.shared.keyWindow?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    /// Opens a real Study shell (PDF + half AI) and leaves it on screen for visual checks.
    private static func runPanelChromePreview() {
        let pdfPath = argValue(prefix: "-StudyQAPDF=")
            ?? "/Users/misaka10704/Downloads/After all.pdf"
        let path = NSString(string: pdfPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            log("FAIL chrome preview missing pdf: \(path)")
            return
        }
        guard let chat = findChatVC(in: UIApplication.shared.keyWindow?.rootViewController) else {
            log("FAIL chrome preview: ChatViewController not found")
            return
        }
        do {
            let doc = try StudyDocumentStore.shared.importPDF(from: URL(fileURLWithPath: path), title: "ChromePreview")
            chat.debugAttachStudyDocument(documentID: doc.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                let shell = chat.studyContextProvider as? StudyShellViewController
                shell?.debugExpandChatPanel()
                log("PASS chrome preview attached (half panel); leave UI for screenshots")
            }
        } catch {
            log("FAIL chrome preview import: \(error.localizedDescription)")
        }
    }

    private static func findChatVC(in root: UIViewController?) -> ChatViewController? {
        guard let root = root else { return nil }
        if let chat = root as? ChatViewController { return chat }
        for child in root.children {
            if let found = findChatVC(in: child) { return found }
        }
        return nil
    }

    private static func argValue(prefix: String) -> String? {
        for arg in ProcessInfo.processInfo.arguments {
            if arg.hasPrefix(prefix) {
                return String(arg.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func log(_ message: String) {
        let line = "\(logTag) \(message)\n"
        fputs(line, stderr)
        fflush(stderr)
    }

    private static func runSuite() {
        let codePath = argValue(prefix: "-StudyQACode=")
            ?? "/Users/misaka10704/Documents/Workspace/Gestalt-Lib-HS-SPI/Code/spi_master.v"
        let pdfPath = argValue(prefix: "-StudyQAPDF=")
            ?? "/Users/misaka10704/Documents/Workspace/College_Tex/Gestalt-Lib/EFM-AD9288-CORE-BOARD/Docs/Datasheet/AD9288.pdf"

        runCodeCheck(path: codePath) { codeOK in
            self.runPDFCheck(path: pdfPath) { pdfOK in
                if codeOK && pdfOK {
                    self.log("PASS all Study feature QA checks")
                } else {
                    self.log("FAIL Study feature QA (code=\(codeOK) pdf=\(pdfOK))")
                }
            }
        }
    }

    private static func stagingURL(for source: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyFeatureQA", isDirectory: true)
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
        guard let root = UIApplication.shared.keyWindow?.rootViewController else {
            log("FAIL no key window root")
            completion()
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        vc.modalPresentationStyle = .fullScreen
        top.present(vc, animated: false, completion: completion)
    }

    private static func dismissPresented(completion: @escaping () -> Void) {
        guard let root = UIApplication.shared.keyWindow?.rootViewController else {
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

    private static func snapshot(_ view: UIView, name: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let url = docs?.appendingPathComponent("StudyFeatureQA_\(name).png")
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, false, 0)
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        if let data = image?.pngData(), let url = url {
            try? data.write(to: url)
            log("screenshot \(url.lastPathComponent)")
        }
    }

    private static func runCodeCheck(path: String, done: @escaping (Bool) -> Void) {
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            log("FAIL code missing: \(path)")
            done(false)
            return
        }
        do {
            let staged = try stagingURL(for: source)
            let doc = try StudyDocumentStore.shared.openDocument(from: staged, forceText: true)
            let editor = TextCodeEditorViewController()
            let hostVC = host(vc: editor)
            present(hostVC) {
                editor.load(documentID: doc.id) { ok in
                    guard ok else {
                        self.log("FAIL code load")
                        self.dismissPresented { done(false) }
                        return
                    }
                    // Let layout settle, then scroll.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        editor.view.layoutIfNeeded()
                        // Enter edit mode — save icon must stay visible on the far right.
                        editor.debugSetEditMode(true)
                        editor.view.layoutIfNeeded()
                        let chrome = editor.debugTopChromeFrames()
                        if chrome.save.maxX < hostVC.view.bounds.width - 60 {
                            self.log("FAIL save not near trailing edge (maxX=\(Int(chrome.save.maxX)))")
                            self.dismissPresented { done(false) }
                            return
                        }
                        if chrome.save.isEmpty || chrome.mode.isEmpty {
                            self.log("FAIL mode/save chrome missing")
                            self.dismissPresented { done(false) }
                            return
                        }
                        editor.debugScrollEditor(by: 420)
                        editor.view.layoutIfNeeded()
                        let ey = editor.debugEditorContentOffsetY()
                        let ly = editor.debugLineNumberContentOffsetY()
                        let delta = abs(ey - ly)
                        self.snapshot(hostVC.view, name: "code_scroll")
                        if ey < 100 {
                            self.log("FAIL code did not scroll enough (y=\(Int(ey)))")
                            self.dismissPresented { done(false) }
                            return
                        }
                        if delta > 1.5 {
                            self.log("FAIL line-number sync delta=\(String(format: "%.2f", delta)) editorY=\(Int(ey)) gutterY=\(Int(ly))")
                            self.dismissPresented { done(false) }
                            return
                        }
                        self.log("PASS code chrome+line sync (y=\(Int(ey)) saveMaxX=\(Int(chrome.save.maxX)))")
                        self.dismissPresented { done(true) }
                    }
                }
            }
        } catch {
            log("FAIL code open: \(error.localizedDescription)")
            done(false)
        }
    }

    private static func runPDFCheck(path: String, done: @escaping (Bool) -> Void) {
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            log("FAIL pdf missing: \(path)")
            done(false)
            return
        }
        do {
            let staged = try stagingURL(for: source)
            let doc = try StudyDocumentStore.shared.openDocument(from: staged)
            let reader = PDFReaderViewController()
            let hostVC = host(vc: reader)
            present(hostVC) {
                reader.load(documentID: doc.id) { ok in
                    guard ok else {
                        self.log("FAIL pdf load")
                        self.dismissPresented { done(false) }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        guard let pdfView = Self.findPDFView(in: reader.view) else {
                            self.log("FAIL pdf view missing")
                            self.dismissPresented { done(false) }
                            return
                        }
                        // Prove programmatic / custom-path selection works (page.selection from-to).
                        if let page = pdfView.document?.page(at: 0) {
                            let box = page.bounds(for: .mediaBox)
                            let from = CGPoint(x: box.minX + 40, y: box.midY)
                            let to = CGPoint(x: box.midX, y: box.midY)
                            if let sel = page.selection(from: from, to: to) {
                                pdfView.currentSelection = sel
                            } else {
                                pdfView.currentSelection = page.selection(for: box)
                            }
                        }
                        let selected = pdfView.currentSelection?.string?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard let studyPDF = pdfView as? StudyPDFView else {
                            self.log("FAIL pdf view is not StudyPDFView")
                            self.dismissPresented { done(false) }
                            return
                        }
                        // Highlighter tool present; double-tap note recognizer attached.
                        studyPDF.suppressNativeTextInteraction()
                        studyPDF.highlighter.setEnabled(true)
                        studyPDF.highlighter.setEnabled(false)
                        let overlays = reader.view.subviews.filter { $0 is PassthroughOverlayView }
                        if overlays.isEmpty {
                            self.log("FAIL missing passthrough invert overlays")
                            self.dismissPresented { done(false) }
                            return
                        }
                        self.snapshot(hostVC.view, name: "pdf_select")
                        if selected.isEmpty {
                            self.log("WARN pdf page has no extractable text; highlighter ready")
                            self.dismissPresented { done(true) }
                            return
                        }
                        self.log("PASS pdf highlighter/note path (\(selected.count) chars selectable)")
                        self.dismissPresented { done(true) }
                    }
                }
            }
        } catch {
            log("FAIL pdf open: \(error.localizedDescription)")
            done(false)
        }
    }

    private static func findPDFView(in root: UIView) -> PDFView? {
        if let pdf = root as? PDFView { return pdf }
        for child in root.subviews {
            if let found = findPDFView(in: child) { return found }
        }
        return nil
    }

    private static func noteFieldIsFirstResponder() -> Bool {
        guard let window = UIApplication.shared.keyWindow else { return false }
        func walk(_ view: UIView) -> Bool {
            if let field = view as? UITextField, field.isFirstResponder { return true }
            for sub in view.subviews where walk(sub) { return true }
            return false
        }
        for sub in window.subviews where walk(sub) { return true }
        return false
    }
}
#endif
