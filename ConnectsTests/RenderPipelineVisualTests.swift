import XCTest
import UIKit
@testable import Connects

/// Visual regression harness: run a real math-heavy markdown export through the
/// native chat pipeline (normalizeForRender → parse → layout → rasterize) and
/// write PNGs + a formula report onto the macOS host for inspection.
///
/// Pass 1 is immediate (iosMath previews / async KaTeX still queued).
/// Pass 2 re-layouts after a main-runloop spin so KaTeX snapshots can land
/// (`storeExternalArtifact` clears the layouter cache, so layout() rebuilds).
final class RenderPipelineVisualTests: XCTestCase {

    private struct MatrixEntry {
        let width: CGFloat
        let appearance: String
        let colors: ThemeColors

        var style: NativeLayoutStyle {
            NativeLayoutStyle(
                width: width,
                bodyFontSize: 17.5,
                appearance: appearance,
                colors: colors
            )
        }

        func fileStem(prefix: String) -> String { "\(prefix)_\(Int(width))_\(appearance)" }
    }

    private let matrix: [MatrixEntry] = [
        MatrixEntry(width: 330, appearance: "light", colors: DSTheme.light),
        MatrixEntry(width: 330, appearance: "dark", colors: DSTheme.dark),
        MatrixEntry(width: 380, appearance: "light", colors: DSTheme.light),
        MatrixEntry(width: 380, appearance: "dark", colors: DSTheme.dark)
    ]

    private let logTag = "[RenderVisual]"

    /// Diagnostic: why does KaTeX complete or not complete under XCTest?
    /// Probes key-window presence, katex bundle resources, and drives one direct snapshot job.
    func testKaTeXEnvironmentProbe() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let keyWindow = windows.first { $0.isKeyWindow }
        print("\(logTag) probe windows=\(windows.count) keyWindow=\(keyWindow != nil)")
        for window in windows {
            print("\(logTag) probe window: key=\(window.isKeyWindow) hidden=\(window.isHidden) alpha=\(window.alpha) frame=\(window.frame) class=\(type(of: window))")
        }
        let katexURL = Bundle.main.resourceURL?.appendingPathComponent("katex", isDirectory: true)
        print("\(logTag) probe katex bundle path=\(katexURL?.path ?? "nil") exists=\(katexURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
        print("\(logTag) probe Bundle.main=\(Bundle.main.bundlePath)")

        // Drive one job directly and watch for completion.
        let tex = "x^2+y^2"
        let color = UIColor.black
        let fontSize: CGFloat = 19.95
        let before = NativeFormulaRenderer.shared.hasCachedArtifact(
            tex: tex, fontSize: fontSize, color: color, display: true, maxWidth: 0
        )
        print("\(logTag) probe direct-job before=\(before)")
        _ = NativeFormulaRenderer.shared.artifact(
            tex: tex, fontSize: fontSize, color: color, display: true, maxWidth: 0
        )
        spinMainRunloop(seconds: 6)
        let memOnly = NativeFormulaRenderer.shared.hasMemoryArtifact(
            tex: tex, fontSize: fontSize, color: color, display: true, maxWidth: 0
        )
        // Wipe memory: whatever remains is disk-backed (= a completed KaTeX snapshot).
        NativeFormulaRenderer.shared.clear()
        let diskAfter = NativeFormulaRenderer.shared.hasCachedArtifact(
            tex: tex, fontSize: fontSize, color: color, display: true, maxWidth: 0
        )
        print("\(logTag) probe direct-job memoryHadArtifact=\(memOnly) katexDiskCompleted=\(diskAfter)")
    }

    /// Step-by-step WKWebView probe: which layer of the offscreen-snapshot
    /// pipeline breaks under XCTest — navigation, JS evaluation, or takeSnapshot?
    func testWebViewSnapshotLayerProbe() {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        print("\(logTag) layerprobe keyWindow=\(keyWindow != nil)")

        for attached in [true, false] {
            let tag = attached ? "attached" : "detached"
            let config = ConnectsWebKit.makeConfiguration()
            let size = CGSize(width: 300, height: 120)
            let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            var host: UIView?
            if attached, let keyWindow {
                let hostView = UIView(frame: CGRect(x: -size.width - 80, y: 40, width: size.width, height: size.height))
                hostView.isHidden = false
                hostView.isUserInteractionEnabled = false
                hostView.backgroundColor = .clear
                hostView.addSubview(webView)
                webView.frame = hostView.bounds
                keyWindow.addSubview(hostView)
                host = hostView
            }

            var navFinished = false
            let delegate = ProbeNavDelegate { navFinished = true }
            webView.navigationDelegate = delegate

            webView.loadHTMLString(
                "<html><body style='margin:0;background:rgba(0,0,0,0)'><div id='host' style='font-size:20px;color:rgb(200,0,0)'>x^2 probe</div></body></html>",
                baseURL: nil
            )
            spinMainRunloop(seconds: 1.5)
            print("\(logTag) layerprobe \(tag): navFinished=\(navFinished)")

            var jsResult: Any?
            var jsError: Error?
            var jsDone = false
            webView.evaluateJavaScript("document.getElementById('host').getBoundingClientRect().width") { result, error in
                jsResult = result
                jsError = error
                jsDone = true
            }
            spinMainRunloop(seconds: 1.5)
            print("\(logTag) layerprobe \(tag): jsDone=\(jsDone) result=\(String(describing: jsResult)) error=\(String(describing: jsError))")

            var snapshotImage: UIImage?
            var snapshotError: Error?
            var snapshotDone = false
            let snapConfig = WKSnapshotConfiguration()
            snapConfig.rect = CGRect(origin: .zero, size: size)
            webView.takeSnapshot(with: snapConfig) { image, error in
                snapshotImage = image
                snapshotError = error
                snapshotDone = true
            }
            spinMainRunloop(seconds: 2)
            var nonBlank = false
            if let image = snapshotImage, let cg = image.cgImage,
               let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                // Sample pixels: a blank transparent snapshot is all zeros.
                let length = CFDataGetLength(data)
                var sum = 0
                var index = 0
                while index < min(length, 40000) {
                    sum += Int(bytes[index])
                    index += 97
                }
                nonBlank = sum > 0
                print("\(logTag) layerprobe \(tag): snapshot bytes sample sum=\(sum)")
            }
            print("\(logTag) layerprobe \(tag): snapshotDone=\(snapshotDone) image=\(snapshotImage != nil) size=\(snapshotImage?.size ?? .zero) nonBlank=\(nonBlank) error=\(String(describing: snapshotError))")
            host?.removeFromSuperview()
        }
    }

    /// Replica of the production KaTeX shell: check katex.min.js loading, font readiness,
    /// katex.render measurement, and snapshot — for attached-offscreen vs detached webviews.
    func testKaTeXShellReplicaProbe() {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("katex", isDirectory: true),
              FileManager.default.fileExists(atPath: base.path) else {
            XCTFail("katex bundle resources missing")
            return
        }
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        let shell = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <link rel="stylesheet" href="katex.min.css"/>
        <style>html,body{margin:0;padding:3px;background:transparent}#host{display:inline-block;line-height:1}.katex-display{margin:0}
        #preload{position:absolute;left:-9999px;top:0;opacity:0;font-family:KaTeX_Main,KaTeX_Math,KaTeX_Size1,KaTeX_AMS;}</style>
        <script src="katex.min.js"></script>
        </head>
        <body>
        <div id="preload">0∑∫α</div>
        <div id="host"></div>
        </body>
        </html>
        """

        for mode in ["attached-offscreen", "attached-visible", "detached"] {
            let size = CGSize(width: 400, height: 160)
            let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: ConnectsWebKit.makeConfiguration())
            webView.isOpaque = false
            webView.backgroundColor = .clear
            var host: UIView?
            if mode != "detached", let keyWindow {
                let x: CGFloat = mode == "attached-visible" ? 0 : -size.width - 80
                let hostView = UIView(frame: CGRect(x: x, y: 30, width: size.width, height: size.height))
                hostView.isHidden = false
                hostView.isUserInteractionEnabled = false
                hostView.backgroundColor = .clear
                hostView.addSubview(webView)
                webView.frame = hostView.bounds
                keyWindow.addSubview(hostView)
                host = hostView
            }
            var navFinished = false
            let delegate = ProbeNavDelegate { navFinished = true }
            webView.navigationDelegate = delegate
            webView.loadHTMLString(shell, baseURL: base)
            spinMainRunloop(seconds: 2)
            print("\(logTag) shell \(mode): navFinished=\(navFinished)")

            func eval(_ script: String, _ label: String, seconds: TimeInterval = 2) {
                var done = false
                var result: Any?
                var error: Error?
                webView.evaluateJavaScript(script) { r, e in
                    result = r
                    error = e
                    done = true
                }
                spinMainRunloop(seconds: seconds)
                print("\(logTag) shell \(mode): \(label) done=\(done) result=\(String(describing: result)) error=\(String(describing: error))")
            }

            eval("typeof katex", "typeof-katex")
            eval("document.fonts ? document.fonts.status : 'no-fonts-api'", "fonts-status")
            eval("(document.fonts && document.fonts.load) ? document.fonts.load('16px KaTeX_Main').then(function(){return 'loaded'}).catch(function(e){return 'err:'+e}) : Promise.resolve('no-api')", "fonts-load", seconds: 3)
            eval(
                """
                (function(){
                  var host = document.getElementById('host');
                  host.style.fontSize = '16px';
                  host.style.color = 'rgba(13,13,13,1)';
                  try {
                    katex.render('x^2+y^2', host, {displayMode:true, throwOnError:true, strict:'ignore', output:'html'});
                  } catch (e) { return 'render-err:'+e; }
                  var el = host.querySelector('.katex-display') || host.querySelector('.katex') || host;
                  var r = el.getBoundingClientRect();
                  return 'w='+r.width+' h='+r.height;
                })()
                """,
                "katex-render",
                seconds: 2
            )
            eval("document.fonts ? document.fonts.size : -1", "fonts-size")

            var snapshotImage: UIImage?
            var snapDone = false
            let snapConfig = WKSnapshotConfiguration()
            snapConfig.rect = CGRect(origin: .zero, size: size)
            webView.takeSnapshot(with: snapConfig) { image, error in
                snapshotImage = image
                if let error { print("\(self.logTag) shell \(mode): snapshot error \(error.localizedDescription)") }
                snapDone = true
            }
            spinMainRunloop(seconds: 2)
            var ink = 0
            if let cg = snapshotImage?.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                let length = CFDataGetLength(data)
                var index = 0
                while index < length {
                    ink += Int(bytes[index])
                    index += 401
                }
            }
            print("\(logTag) shell \(mode): snapshotDone=\(snapDone) image=\(snapshotImage != nil) inkSum=\(ink)")
            host?.removeFromSuperview()
        }
    }

    /// Does `.katex-display`'s getBoundingClientRect cover everything KaTeX paints?
    /// User-reported: underbrace labels clip at the artifact's bottom edge, so compare
    /// the element border box against the union of all descendant rects and a Range rect.
    func testUnderbraceMeasurementProbe() {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("katex", isDirectory: true),
              FileManager.default.fileExists(atPath: base.path) else {
            XCTFail("katex bundle resources missing")
            return
        }
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        let shell = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <link rel="stylesheet" href="katex.min.css"/>
        <style>html,body{margin:0;padding:3px;background:transparent}#host{display:inline-block;line-height:1}.katex-display{margin:0}.katex{-webkit-text-stroke:0.2px currentColor}
        #preload{position:absolute;left:-9999px;top:0;opacity:0;font-family:KaTeX_Main,KaTeX_Math,KaTeX_Size1,KaTeX_AMS;}</style>
        <script src="katex.min.js"></script>
        </head>
        <body>
        <div id="preload">0∑∫α</div>
        <div id="host"></div>
        </body>
        </html>
        """

        let formulas: [(String, Bool)] = [
            ("y(t) = \\\\underbrace{\\\\text{自由响应} + \\\\text{强迫响应}}_{\\\\text{经典法（齐次解+特解）}}", true),
            ("y(t) = \\\\underbrace{\\\\sum_{i=1}^{n} C_i e^{\\\\lambda_i t}}_{\\\\text{自由响应}} + \\\\underbrace{y_p(t)}_{\\\\text{强迫响应}}", true),
            ("\\\\dfrac{a}{b} x^{2} + \\\\sqrt{x}", true),
            ("x_{i} + \\\\tfrac{1}{2}", false)
        ]

        for (tex, display) in formulas {
            let size = CGSize(width: 500, height: 200)
            let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: ConnectsWebKit.makeConfiguration())
            webView.isOpaque = false
            webView.backgroundColor = .clear
            if let keyWindow {
                let hostView = UIView(frame: CGRect(x: -size.width - 80, y: 30, width: size.width, height: size.height))
                hostView.isUserInteractionEnabled = false
                hostView.backgroundColor = .clear
                hostView.addSubview(webView)
                webView.frame = hostView.bounds
                keyWindow.addSubview(hostView)
                defer { hostView.removeFromSuperview() }
            }
            let delegate = ProbeNavDelegate {}
            webView.navigationDelegate = delegate
            webView.loadHTMLString(shell, baseURL: base)
            spinMainRunloop(seconds: 2)

            var result: Any?
            var error: Error?
            var done = false
            let script = """
            (function(){
              var host = document.getElementById('host');
              host.style.fontSize = '16.4px';
              host.style.color = 'rgba(235,235,235,1)';
              try {
                katex.render('\(tex)', host, {displayMode:\(display), throwOnError:true, strict:'ignore', output:'html'});
              } catch (e) { return JSON.stringify({error:String(e)}); }
              var el = host.querySelector('.katex-display') || host.querySelector('.katex') || host;
              var r = el.getBoundingClientRect();
              var minY = r.top, maxY = r.bottom, minX = r.left, maxX = r.right;
              var all = el.querySelectorAll('*');
              for (var i = 0; i < all.length; i++) {
                var rr = all[i].getBoundingClientRect();
                if (rr.height === 0 && rr.width === 0) continue;
                if (rr.top < minY) minY = rr.top;
                if (rr.bottom > maxY) maxY = rr.bottom;
                if (rr.left < minX) minX = rr.left;
                if (rr.right > maxX) maxX = rr.right;
              }
              var range = document.createRange();
              range.selectNodeContents(el);
              var rangeR = range.getBoundingClientRect();
              var hostR = host.getBoundingClientRect();
              return JSON.stringify({
                display: \(display),
                elH: r.height, elTop: r.top, elBottom: r.bottom,
                unionH: maxY - minY, unionTop: minY, unionBottom: maxY,
                unionW: maxX - minX, elW: r.width,
                rangeH: rangeR.height, rangeTop: rangeR.top, rangeBottom: rangeR.bottom,
                rangeW: rangeR.width, rangeLeft: rangeR.left, rangeRight: rangeR.right,
                elLeft: r.left, elRight: r.right,
                hostH: hostR.height, hostTop: hostR.top, hostBottom: hostR.bottom,
                scrollH: document.scrollingElement.scrollHeight
              });
            })()
            """
            webView.evaluateJavaScript(script) { r, e in
                result = r
                error = e
                done = true
            }
            spinMainRunloop(seconds: 3)
            print("\(logTag) underbrace-probe done=\(done) result=\(String(describing: result)) error=\(String(describing: error)) tex=\(tex)")
        }
    }

    /// Does evaluateJavaScript await promises at all under XCTest?
    /// Distinguishes "promises unsupported" from "font promises never settle".
    func testPromiseBridgingProbe() {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                configuration: ConnectsWebKit.makeConfiguration())
        var navFinished = false
        let delegate = ProbeNavDelegate { navFinished = true }
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<html><body>probe</body></html>", baseURL: nil)
        spinMainRunloop(seconds: 1)
        print("\(logTag) promise-probe navFinished=\(navFinished)")

        let cases: [(String, String)] = [
            ("plain-value", "42"),
            ("promise-resolve", "Promise.resolve(42)"),
            ("promise-timeout", "new Promise(function(res){setTimeout(function(){res(7)},150)})"),
            ("fonts-ready", "document.fonts.ready.then(function(){return 'fonts-ok'})"),
            ("plain-string-object", "JSON.stringify({a:1})")
        ]
        for (label, script) in cases {
            var done = false
            var result: Any?
            var error: Error?
            webView.evaluateJavaScript(script) { r, e in
                result = r
                error = e
                done = true
            }
            spinMainRunloop(seconds: 2)
            print("\(logTag) promise-probe \(label): done=\(done) result=\(String(describing: result)) error=\(String(describing: error))")
        }
    }

    // MARK: - Fixture sanity

    func testFixtureLoadsAndParses() throws {
        let content = try fixtureMarkdown(named: "vandermonde-answer")
        let document = NativeMarkdownParser.shared.parse(
            MarkdownHTMLRenderer.normalizeForRender(content)
        )
        XCTAssertFalse(document.blocks.isEmpty, "fixture must parse into blocks")
        let displayCount = document.blocks.filter {
            if case .displayMath = $0 { return true }
            return false
        }.count
        XCTAssertGreaterThan(displayCount, 3, "vandermonde fixture is display-math heavy")
    }

    // MARK: - Matrix render

    func testVandermondeMatrixProducesPNGs() throws {
        try runVisualMatrix(
            fixtureName: "vandermonde-answer",
            outputPrefix: "vander",
            reportFileName: "vander_report.txt",
            reportTitle: "Connects native render visual regression — vandermonde-answer.md"
        )
    }

    func testTfracInlineProducesPNGs() throws {
        try runVisualMatrix(
            fixtureName: "tfrac-inline",
            outputPrefix: "tfrac",
            reportFileName: "tfrac_report.txt",
            reportTitle: "Connects native render visual regression — tfrac-inline.md"
        )
    }

    func testUnderbraceCJKProducesPNGs() throws {
        try runVisualMatrix(
            fixtureName: "underbrace-cjk",
            outputPrefix: "underbrace",
            reportFileName: "underbrace_report.txt",
            reportTitle: "Connects native render visual regression — underbrace-cjk.md"
        )
    }

    private func runVisualMatrix(fixtureName: String,
                                 outputPrefix: String,
                                 reportFileName: String,
                                 reportTitle: String) throws {
        let content = try fixtureMarkdown(named: fixtureName)
        let normalized = MarkdownHTMLRenderer.normalizeForRender(content)
        let document = NativeMarkdownParser.shared.parse(normalized)
        XCTAssertFalse(document.blocks.isEmpty)

        // Cold-start determinism: disk-persisted KaTeX PNGs from earlier app runs
        // would blur the pass1-vs-pass2 comparison. Cache only — rebuilt on demand.
        NativeFormulaRenderer.shared.clearDisk()
        NativeMessageLayouter.shared.clear()

        let output = resolveOutputDirectory()
        print("\(logTag) output directory: \(output.url.path) (hostTmp=\(output.isHostTmp))")

        var report = ReportWriter()
        report.line(reportTitle)
        report.line("date: \(ISO8601DateFormatter().string(from: Date()))")
        report.line("outputDir: \(output.url.path)")
        report.line("outputIsHostSlashTmp: \(output.isHostTmp)")
        report.line("screenScale: \(UIScreen.main.scale) rasterScale: 2 bodyFontSize: 17.5")
        report.line("fixtureChars: \(content.count) blocks: \(document.blocks.count)")
        report.line("blockKinds: \(blockKindSummary(document))")
        report.line("")

        // ---- Pass 1: immediate layout+paint (KaTeX still queued, iosMath previews) ----
        var pass1PNGs = [String: Data]()
        var pass1Heights = [String: CGFloat]()
        for entry in matrix {
            let layout = NativeMessageLayouter.shared.layout(
                document: document,
                style: entry.style,
                renderMissingFormulas: true
            )
            pass1Heights[entry.fileStem(prefix: outputPrefix)] = layout.size.height
            guard let image = rasterizeWithScrollBands(layout: layout, scale: 2),
                  let data = image.pngData() else {
                XCTFail("pass1 rasterize failed for \(entry.fileStem(prefix: outputPrefix)) height=\(layout.size.height)")
                continue
            }
            pass1PNGs[entry.fileStem(prefix: outputPrefix)] = data
            let url = output.url.appendingPathComponent("\(entry.fileStem(prefix: outputPrefix))_pass1.png")
            try data.write(to: url, options: .atomic)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "pass1 PNG missing after write: \(url.path)"
            )
            print("\(logTag) wrote \(url.path) (\(data.count) bytes, h=\(Int(layout.size.height)))")
        }

        // ---- Runloop spin: let offscreen KaTeX WKWebViews snapshot enqueued jobs ----
        // Progress metric: `.nativeFormulaDidRender` fires only from storeExternalArtifact,
        // which only KaTeX snapshot completion calls — iosMath previews never post it.
        var katexCompletions = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .nativeFormulaDidRender,
            object: nil,
            queue: nil
        ) { _ in katexCompletions += 1 }
        spinMainRunloop(seconds: 5)
        let completionsAt5s = katexCompletions
        var extraSpun = 0.0
        var lastCount = katexCompletions
        var quietPeriods = 0
        while extraSpun < 12, quietPeriods < 2 {
            spinMainRunloop(seconds: 1)
            extraSpun += 1
            if katexCompletions == lastCount {
                quietPeriods += 1
            } else {
                quietPeriods = 0
                lastCount = katexCompletions
            }
        }
        NotificationCenter.default.removeObserver(observer)
        print("\(logTag) KaTeX completions: \(completionsAt5s) at 5s, \(katexCompletions) after +\(Int(extraSpun))s extra spin")

        // ---- Probe: memory+disk first, then memory-wipe to expose disk(=KaTeX)-only keys ----
        var seenWidths = Set<CGFloat>()
        let probeWidths = matrix.map(\.width).filter { seenWidths.insert($0).inserted }
        let requests = dedupedFormulaRequests(document: document)
        var probeResults = [FormulaProbe]()
        for request in requests {
            probeResults.append(probeFormula(tex: request.tex, warmDisplay: request.display, widths: probeWidths))
        }
        NativeFormulaRenderer.shared.clear() // iosMath previews are memory-only; what survives is disk=KaTeX
        for index in probeResults.indices {
            for (slot, key) in probeResults[index].bestKey {
                probeResults[index].diskBacked[slot] = NativeFormulaRenderer.shared
                    .hasCachedArtifact(
                        tex: probeResults[index].tex,
                        fontSize: key.fontSize,
                        color: key.color,
                        display: key.display,
                        maxWidth: key.maxWidth,
                        shrinkFloor: key.shrinkFloor
                    )
            }
        }

        // ---- Pass 2: re-layout (layouter cache was cleared as KaTeX artifacts landed) ----
        var passLines = [String]()
        var scrollBandCounts = [String: Int]()
        var pass2Layouts = [String: NativeMessageLayout]()
        for entry in matrix {
            let layout = NativeMessageLayouter.shared.layout(
                document: document,
                style: entry.style,
                renderMissingFormulas: true
            )
            pass2Layouts[entry.fileStem(prefix: outputPrefix)] = layout
            scrollBandCounts[entry.fileStem(prefix: outputPrefix)] = layout.commands.filter {
                if case .mathScroll = $0 { return true }
                return false
            }.count
            guard let image = rasterizeWithScrollBands(layout: layout, scale: 2),
                  let data = image.pngData() else {
                XCTFail("pass2 rasterize failed for \(entry.fileStem(prefix: outputPrefix))")
                continue
            }
            let url = output.url.appendingPathComponent("\(entry.fileStem(prefix: outputPrefix))_pass2.png")
            try data.write(to: url, options: .atomic)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "pass2 PNG missing after write: \(url.path)"
            )
            let pass1 = pass1PNGs[entry.fileStem(prefix: outputPrefix)] ?? Data()
            let verdict: String
            if data == pass1 {
                verdict = "IDENTICAL (no KaTeX influence — either complete already or never arrived)"
            } else {
                verdict = "DIFFERENT (pass2 picked up KaTeX bitmaps)"
            }
            passLines.append(
                "\(entry.fileStem(prefix: outputPrefix)): pass1=\(pass1.count)B pass2=\(data.count)B h1=\(Int(pass1Heights[entry.fileStem(prefix: outputPrefix)] ?? 0)) h2=\(Int(layout.size.height)) → \(verdict)"
            )
            print("\(logTag) wrote \(url.path) (\(data.count) bytes) \(verdict)")
        }

        // ---- Shrink-to-fit proof data: exact layouter keys per displayMath block ----
        // displayMath blocks render at body×displayMathScale, display=true, maxWidth=width.
        var displayTexes = [String]()
        var seenDisplay = Set<String>()
        for block in document.blocks {
            guard case .displayMath(let tex) = block, seenDisplay.insert(tex).inserted else { continue }
            displayTexes.append(tex)
        }

        // ---- Report ----
        report.line("== KaTeX completions during runloop spin ==")
        report.line("at 5s: \(completionsAt5s); after extra \(Int(extraSpun))s spin: \(katexCompletions)")
        report.line("")
        report.line("== pass comparison ==")
        passLines.forEach { report.line($0) }
        report.line("")
        report.line("== scroll bands in pass-2 layouts (wide formulas that still overflow after shrink floor 0.55) ==")
        for entry in matrix {
            report.line("\(entry.fileStem(prefix: outputPrefix)): \(scrollBandCounts[entry.fileStem(prefix: outputPrefix)] ?? 0) mathScroll band(s)")
        }
        report.line("")
        report.line("== shrink-to-fit proof (per display math, exact layouter cache keys) ==")
        report.line("artifact width must be ≤ layout width unless even the 0.55 floor overflows (then a scroll band)")
        var fitIndex = 0
        var fitFailCount = 0
        var fitMissingCount = 0
        for tex in displayTexes {
            fitIndex += 1
            var segments = [String]()
            for width in probeWidths {
                let fontSize = 17.5 * NativeMessageLayouter.displayMathScale
                let size = NativeFormulaRenderer.shared.knownArtifactSize(
                    tex: tex,
                    fontSize: fontSize,
                    color: DSTheme.light.textPrimary,
                    display: true,
                    maxWidth: width
                )
                if let size {
                    let fits = size.width <= width + 0.5
                    if !fits { fitFailCount += 1 }
                    segments.append("@\(Int(width)): \(Int(size.width))pt \(fits ? "FITS" : "OVERFLOW")")
                } else {
                    fitMissingCount += 1
                    segments.append("@\(Int(width)): no-artifact")
                }
            }
            let preview = tex.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            report.line("[display \(fitIndex)] \(segments.joined(separator: "  |  ")) — \(preview.prefix(48))")
        }
        report.line("fit-proof summary: \(fitFailCount) overflow(s), \(fitMissingCount) missing artifact(s) across \(displayTexes.count) display tex(es) × \(probeWidths.count) width(s)")
        report.line("")
        report.line("== formulas (per parsed math span, deduped) ==")
        report.line("state values: KaTeX = disk-backed bitmap (final truth); iosMath-only = preview only, KaTeX missing; none = no artifact")
        var proseFallbacks = [String]()
        var rawFallbacks = [String]()
        for (index, probe) in probeResults.enumerated() {
            let kind = probe.warmDisplay ? "display" : "inline "
            report.line("")
            report.line("[\(kind) \(index + 1)] tex: \(probe.preview)")
            for appearance in ["light", "dark"] {
                var segments = [String]()
                for width in probeWidths {
                    let slot = FormulaProbe.slot(appearance, width)
                    if let key = probe.bestKey[slot] {
                        let sizeText = probe.bestSize[slot].map {
                            "\(Int($0.width))×\(Int($0.height))pt"
                        } ?? "size-unknown"
                        let disk = probe.diskBacked[slot] == true
                        let state = disk ? "KaTeX" : "iosMath-only"
                        let fitText = probe.bestSize[slot].map {
                            $0.width <= width + 0.5 ? "fits" : "overflow"
                        } ?? "?"
                        segments.append("@\(Int(width)) \(state) \(sizeText) \(fitText) fs=\(String(format: "%.2f", key.fontSize))")
                    } else {
                        segments.append("@\(Int(width)) none")
                    }
                }
                report.line("    \(appearance): \(segments.joined(separator: "  |  "))")
            }
            if probe.bestKey.isEmpty {
                if NativeMathProse.needsExpansion(probe.tex) {
                    proseFallbacks.append(probe.preview)
                } else {
                    rawFallbacks.append(probe.preview)
                }
            }
        }
        report.line("")
        report.line("== fallbacks (no artifact key in any candidate) ==")
        report.line("NativeMathProse expansion (\(proseFallbacks.count)):")
        proseFallbacks.forEach { report.line("  - \($0)") }
        report.line("raw mono TeX text (\(rawFallbacks.count)):")
        rawFallbacks.forEach { report.line("  - \($0)") }
        report.line("")
        report.line("== notes ==")
        report.line("mathScroll bands: wide display formulas are painted blank by NativeMessagePainter;")
        report.line("this harness composites band.image at scroll-offset 0 into the PNGs (faithful at-rest view).")
        report.line("KaTeX-first: CJK/prose inside $$..$$ stays ONE displayMath block (see blockKinds) and")
        report.line("reaches KaTeX whole; NativeMathProse expansion survives only as the can't-render fallback.")

        let reportURL = output.url.appendingPathComponent(reportFileName)
        try report.text.write(to: reportURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        print("\(logTag) wrote \(reportURL.path)")
        print("\(logTag) REPORT BEGIN\n\(report.text)\n\(logTag) REPORT END")

        // If /tmp was not usable the fallback path must be visible in test output.
        if !output.isHostTmp {
            print("\(logTag) HOST /tmp write FAILED — PNGs are inside the simulator container:")
            print("\(logTag) \(output.url.path)")
        }
    }

    // MARK: - Formula probing

    private struct ProbeKey {
        let fontSize: CGFloat
        let color: UIColor
        let display: Bool
        let maxWidth: CGFloat
        let shrinkFloor: CGFloat?
    }

    private struct FormulaProbe {
        let tex: String
        let warmDisplay: Bool
        let preview: String
        var bestKey: [String: ProbeKey] = [:]      // "appearance|width" → first hitting cache key
        var bestSize: [String: CGSize] = [:]       // "appearance|width" → knownArtifactSize at that key
        var diskBacked: [String: Bool] = [:]       // "appearance|width" → disk(=KaTeX) after memory wipe

        static func slot(_ appearance: String, _ width: CGFloat) -> String {
            "\(appearance)|\(Int(width))"
        }
    }

    /// Same scan the layouter warms: displayMath blocks + inline math everywhere.
    private func dedupedFormulaRequests(document: NativeMarkdownDocument) -> [NativeFormulaWarmRequest] {
        NativeMessageLayouter.formulaWarmRequests(document: document)
    }

    /// Candidate cache keys mirror every context the layouter can place math in:
    /// body (17.5), composite display font (×1.02), headings (×1.32/1.2/1.1),
    /// references (16.5) — times inlineMathScale 1.0 or displayMathScale 1.1,
    /// display flag false/true (tall inline math is promoted to display),
    /// maxWidth per matrix width (shrink-to-fit keys are width-specific).
    private func probeFormula(tex: String, warmDisplay: Bool, widths: [CGFloat]) -> FormulaProbe {
        let body: CGFloat = 17.5
        let baseFactors: [CGFloat] = [1.0, 1.02, 1.1, 1.2, 1.32, 16.5 / 17.5]
        let mathScales: [CGFloat] = warmDisplay
            ? [NativeMessageLayouter.displayMathScale]
            : [NativeMessageLayouter.inlineMathScale, NativeMessageLayouter.displayMathScale]
        var probe = FormulaProbe(
            tex: tex,
            warmDisplay: warmDisplay,
            preview: tex.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(60)
                .description
        )
        for (appearance, colors) in [("light", DSTheme.light), ("dark", DSTheme.dark)] {
            for width in widths {
                let slot = FormulaProbe.slot(appearance, width)
                outer: for factor in baseFactors {
                    for mathScale in mathScales {
                        for display in (warmDisplay ? [true] : [false, true]) {
                            // Tall inline math renders with display=true but keys floor 0.7;
                            // display blocks key the 0.55 default. Scan both.
                            let floorCandidates: [CGFloat?] = display
                                ? [nil, NativeFormulaRenderer.inlineShrinkFloor]
                                : [nil]
                            for floor in floorCandidates {
                                let fontSize = body * factor * mathScale
                                if NativeFormulaRenderer.shared.hasCachedArtifact(
                                    tex: tex,
                                    fontSize: fontSize,
                                    color: colors.textPrimary,
                                    display: display,
                                    maxWidth: width,
                                    shrinkFloor: floor
                                ) {
                                    probe.bestKey[slot] = ProbeKey(
                                        fontSize: fontSize,
                                        color: colors.textPrimary,
                                        display: display,
                                        maxWidth: width,
                                        shrinkFloor: floor
                                    )
                                    probe.bestSize[slot] = NativeFormulaRenderer.shared.knownArtifactSize(
                                        tex: tex,
                                        fontSize: fontSize,
                                        color: colors.textPrimary,
                                        display: display,
                                        maxWidth: width,
                                        shrinkFloor: floor
                                    )
                                    break outer
                                }
                            }
                        }
                    }
                }
            }
        }
        return probe
    }

    // MARK: - Rasterize

    /// NativeMessagePainter skips `.mathScroll` bands (they are interactive scroll views
    /// in live cells). Composite the band image at scroll offset 0 so the PNG shows what
    /// a user sees before touching the band.
    private func rasterizeWithScrollBands(layout: NativeMessageLayout, scale: CGFloat) -> UIImage? {
        guard let base = NativeMessagePainter.rasterize(
            commands: layout.commands,
            size: layout.size,
            scale: scale
        ) else { return nil }
        let bands = layout.commands.compactMap { command -> NativeMathScrollFragment? in
            if case .mathScroll(let band) = command { return band }
            return nil
        }
        guard !bands.isEmpty else { return base }
        UIGraphicsBeginImageContextWithOptions(layout.size, false, scale)
        defer { UIGraphicsEndImageContext() }
        base.draw(in: CGRect(origin: .zero, size: layout.size))
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        for band in bands {
            context.saveGState()
            context.clip(to: band.viewportFrame)
            band.image.draw(in: CGRect(
                x: band.viewportFrame.minX,
                y: band.viewportFrame.minY,
                width: band.contentSize.width,
                height: band.contentSize.height
            ))
            context.restoreGState()
        }
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // MARK: - Helpers

    private func fixtureMarkdown(named name: String) throws -> String {
        let bundle = Bundle(for: RenderPipelineVisualTests.self)
        guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: "md") else {
            throw XCTSkip("\(name).md fixture missing from test bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func spinMainRunloop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private struct OutputLocation {
        let url: URL
        let isHostTmp: Bool
    }

    /// Prefer host-visible /tmp/connects-render (simulator processes share the host FS).
    /// Probe-write before trusting it; fall back to the container tmp and print the path.
    private func resolveOutputDirectory() -> OutputLocation {
        let primary = URL(fileURLWithPath: "/tmp/connects-render")
        if directoryIsWritable(primary) {
            return OutputLocation(url: primary, isHostTmp: true)
        }
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("connects-render", isDirectory: true)
        let writable = directoryIsWritable(fallback)
        print("\(logTag) fallback output directory: \(fallback.path) writable=\(writable)")
        return OutputLocation(url: fallback, isHostTmp: false)
    }

    private func directoryIsWritable(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".write-probe")
            try "probe".write(to: probe, atomically: true, encoding: .utf8)
            let exists = FileManager.default.fileExists(atPath: probe.path)
            try? FileManager.default.removeItem(at: probe)
            return exists
        } catch {
            print("\(logTag) directory not writable: \(url.path) — \(error.localizedDescription)")
            return false
        }
    }

    private func blockKindSummary(_ document: NativeMarkdownDocument) -> String {
        var counts = [String: Int]()
        for block in document.blocks {
            let name: String
            switch block {
            case .paragraph: name = "paragraph"
            case .heading(let level, _): name = "heading\(level)"
            case .list: name = "list"
            case .blockquote: name = "blockquote"
            case .codeBlock: name = "codeBlock"
            case .table: name = "table"
            case .displayMath: name = "displayMath"
            case .displayMathComposite: name = "displayMathComposite"
            case .horizontalRule: name = "horizontalRule"
            }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    private struct ReportWriter {
        private(set) var text = ""
        mutating func line(_ value: String) {
            text += value + "\n"
        }
    }
}

// MARK: - Probe helpers

import WebKit

private final class ProbeNavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
