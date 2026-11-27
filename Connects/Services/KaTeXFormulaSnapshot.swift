import UIKit
import WebKit

/// Off-screen KaTeX → PNG. Chat bubbles stay native bitmaps; these WKWebViews are never in a cell.
final class KaTeXFormulaSnapshot: NSObject, WKNavigationDelegate {
    static let shared = KaTeXFormulaSnapshot()

    private struct Job {
        let tex: String
        let fontSize: CGFloat
        let color: UIColor
        let display: Bool
        /// Layout width in points; 0 means "no shrink constraint".
        let maxWidth: CGFloat
        let shrinkFloor: CGFloat
        let scale: CGFloat
        let cacheKey: String
        let attempt: Int
    }

    private final class Lane {
        let canvasSize = CGSize(width: 1600, height: 900)
        var webView: WKWebView?
        var hostView: UIView?
        var ready = false
        var busy = false
    }

    private let laneCount = 2
    private var lanes: [Lane] = []
    private var started = false
    private var queue: [Job] = []
    private var queuedKeys = Set<String>()
    private var failedKeys = Set<String>()

    private override init() {
        super.init()
    }

    func prepare() {
        if Thread.isMainThread {
            startIfNeeded()
        } else {
            DispatchQueue.main.async { [weak self] in self?.startIfNeeded() }
        }
    }

    func hasFailed(cacheKey: String) -> Bool {
        failedKeys.contains(cacheKey)
    }

    func enqueue(tex: String,
                 fontSize: CGFloat,
                 color: UIColor,
                 display: Bool,
                 maxWidth: CGFloat,
                 shrinkFloor: CGFloat,
                 scale: CGFloat,
                 cacheKey: String) {
        prepare()
        let work = {
            if self.failedKeys.contains(cacheKey) || self.queuedKeys.contains(cacheKey) { return }
            self.queuedKeys.insert(cacheKey)
            self.queue.append(
                Job(
                    tex: tex,
                    fontSize: fontSize,
                    color: color,
                    display: display,
                    maxWidth: maxWidth,
                    shrinkFloor: shrinkFloor,
                    scale: scale,
                    cacheKey: cacheKey,
                    attempt: 0
                )
            )
            self.pump()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func startIfNeeded() {
        if !started {
            started = true
            for _ in 0..<laneCount {
                let lane = Lane()
                installWebView(on: lane)
                lanes.append(lane)
            }
        }
        attachToKeyWindow()
    }

    private func installWebView(on lane: Lane) {
        if lane.webView != nil { return }
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("katex", isDirectory: true) else {
            return
        }
        let config = ConnectsWebKit.makeConfiguration()
        let canvas = lane.canvasSize
        let wv = WKWebView(frame: CGRect(origin: .zero, size: canvas), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.minimumZoomScale = 1
        wv.scrollView.maximumZoomScale = 1
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.navigationDelegate = self
        let host = UIView(frame: CGRect(x: -canvas.width - 80, y: 0, width: canvas.width, height: canvas.height))
        // Must stay in the window and un-hidden: takeSnapshot skips fonts in hidden WKWebViews.
        host.isHidden = false
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        host.addSubview(wv)
        wv.frame = host.bounds
        lane.hostView = host
        lane.webView = wv
        wv.loadHTMLString(Self.shellHTML, baseURL: base)
    }

    /// Under xcodebuild test, takeSnapshot of any in-window WKWebView comes back
    /// blank (the test-host window never really composites), while a detached
    /// webview snapshots fine. Production keeps the attached-offscreen lanes —
    /// hidden/detached webviews lose font rendering on device.
    private static let runningTests = NSClassFromString("XCTestCase") != nil

    private func attachToKeyWindow() {
        if Self.runningTests { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.windows.first { $0.isKeyWindow }
        for (index, lane) in lanes.enumerated() {
            guard let host = lane.hostView else { continue }
            if host.superview == nil {
                window?.addSubview(host)
            }
            host.frame = CGRect(
                x: -lane.canvasSize.width - 80,
                y: CGFloat(index) * 8,
                width: lane.canvasSize.width,
                height: lane.canvasSize.height
            )
            lane.webView?.frame = host.bounds
        }
    }

    /// Font faces a formula can reference. Rendering with a face that is still
    /// loading measures fallback metrics, so lanes must not accept jobs until
    /// these are cached. `#preload` only covers the base families.
    private static let preloadFaces = [
        "16px KaTeX_Main", "bold 16px KaTeX_Main", "italic 16px KaTeX_Main", "bold italic 16px KaTeX_Main",
        "16px KaTeX_Math", "italic 16px KaTeX_Math", "bold italic 16px KaTeX_Math",
        "16px KaTeX_AMS", "16px KaTeX_Caligraphic", "16px KaTeX_Fraktur", "bold 16px KaTeX_Fraktur",
        "16px KaTeX_SansSerif", "bold 16px KaTeX_SansSerif", "italic 16px KaTeX_SansSerif",
        "16px KaTeX_Script", "16px KaTeX_Typewriter",
        "16px KaTeX_Size1", "16px KaTeX_Size2", "16px KaTeX_Size3", "16px KaTeX_Size4"
    ]

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Kick off every face load. The boolean result bridges fine — unlike a
        // Promise, which evaluateJavaScript cannot marshal (WKErrorDomain 5).
        let faces = Self.preloadFaces.map { "'\($0)'" }.joined(separator: ",")
        webView.evaluateJavaScript(
            """
            (function(){
              if (!(document.fonts && document.fonts.load)) { return false; }
              [\(faces)].forEach(function(f){ document.fonts.load(f); });
              return true;
            })()
            """
        ) { [weak self] _, _ in
            guard let self, let lane = self.lanes.first(where: { $0.webView === webView }) else { return }
            self.pollFontReadiness(lane, attempt: 0)
        }
    }

    /// Promise-free font readiness: poll until no loads are pending and the key
    /// faces check out. Marks the lane ready even on timeout — a degraded render
    /// beats never rendering at all.
    private func pollFontReadiness(_ lane: Lane, attempt: Int) {
        guard let webView = lane.webView else { return }
        webView.evaluateJavaScript(
            """
            (document.fonts && document.fonts.status === "loaded")
              && document.fonts.check("16px KaTeX_Main")
              && document.fonts.check("italic 16px KaTeX_Math")
              && document.fonts.check("16px KaTeX_Size1")
            """
        ) { [weak self] result, _ in
            guard let self else { return }
            let settled = (result as? Bool) == true
            if settled || attempt >= 50 {
                lane.ready = true
                self.pump()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.pollFontReadiness(lane, attempt: attempt + 1)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lanes.first(where: { $0.webView === webView })?.ready = false
    }

    private func pump() {
        attachToKeyWindow()
        while let job = queue.first, let lane = lanes.first(where: { $0.ready && !$0.busy && $0.webView != nil }) {
            queue.removeFirst()
            lane.busy = true
            render(job, on: lane)
        }
    }

    private func render(_ job: Job, on lane: Lane) {
        guard let webView = lane.webView else {
            finish(job, artifact: nil, lane: lane)
            return
        }
        webView.frame = CGRect(origin: .zero, size: lane.canvasSize)
        webView.bounds = CGRect(origin: .zero, size: lane.canvasSize)
        let payload: [String: Any] = [
            "tex": job.tex,
            "display": job.display,
            "fontSize": Double(job.fontSize),
            "maxWidth": Double(job.maxWidth),
            "shrinkFloor": Double(job.shrinkFloor),
            "color": cssColor(job.color)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            finish(job, artifact: nil, lane: lane)
            return
        }
        webView.evaluateJavaScript("window.__connectsRenderFormula(\(json))") { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.logFailure(job, stage: "js-eval", detail: error.localizedDescription)
                self.finish(job, artifact: nil, lane: lane)
                return
            }
            let dict: [String: Any]
            if let object = result as? [String: Any] {
                dict = object
            } else if let text = result as? String,
                      let bytes = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                dict = object
            } else {
                self.logFailure(job, stage: "js-marshal", detail: String(describing: type(of: result)))
                self.finish(job, artifact: nil, lane: lane)
                return
            }
            guard dict["ok"] as? Bool == true,
                  let width = dict["width"] as? Double,
                  let height = dict["height"] as? Double,
                  width > 0, height > 0 else {
                self.logFailure(job, stage: "measure", detail: String(describing: dict))
                self.finish(job, artifact: nil, lane: lane)
                return
            }
            let pad: CGFloat = 3
            // `top`/`left` mark where the painted ink actually starts inside the
            // web view (element ∪ range union). Capture that region + pad so ink
            // overflowing the element box — underbrace labels below, radicals
            // above — is no longer clipped out of the bitmap.
            let inkTop = CGFloat((dict["top"] as? Double) ?? Double(pad))
            let inkLeft = CGFloat((dict["left"] as? Double) ?? Double(pad))
            let size = CGSize(
                width: ceil(CGFloat(width) + pad * 2),
                height: ceil(CGFloat(height) + pad * 2)
            )
            let captureRect = CGRect(
                x: max(0, inkLeft - pad),
                y: max(0, inkTop - pad),
                width: size.width,
                height: size.height
            )
            let viewSize = CGSize(
                width: max(captureRect.maxX, size.width),
                height: max(captureRect.maxY, size.height)
            )
            webView.frame = CGRect(origin: .zero, size: viewSize)
            webView.bounds = CGRect(origin: .zero, size: viewSize)
            lane.hostView?.frame.size = viewSize
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
            DispatchQueue.main.async {
                self.snapshot(job, in: webView, rect: captureRect, size: size, lane: lane)
            }
        }
    }

    private func logFailure(_ job: Job, stage: String, detail: String) {
        #if DEBUG
        let escaped = job.tex.replacingOccurrences(of: "\n", with: "\\n")
        print("KATEXJOB-FAIL[\(stage)] attempt=\(job.attempt) len=\(job.tex.count) tex=\(escaped) :: \(detail.prefix(200))")
        #endif
    }

    private func snapshot(_ job: Job, in webView: WKWebView, rect: CGRect, size: CGSize, lane: Lane) {
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: Double(rect.width))
        webView.takeSnapshot(with: config) { image, error in
            guard let image, let cg = image.cgImage else {
                self.logFailure(job, stage: "snapshot", detail: error?.localizedDescription ?? "nil-image")
                self.finish(job, artifact: nil, lane: lane)
                return
            }
            let snap = UIImage(cgImage: cg, scale: max(job.scale, 1), orientation: .up)
            let baseline: CGFloat
            if job.display {
                baseline = min(size.height, job.fontSize * 1.05)
            } else {
                baseline = min(size.height * 0.82, job.fontSize * 0.82)
            }
            let artifact = NativeFormulaArtifact(image: snap, size: size, baseline: baseline)
            self.finish(job, artifact: artifact, lane: lane)
        }
    }

    private func finish(_ job: Job, artifact: NativeFormulaArtifact?, lane: Lane) {
        queuedKeys.remove(job.cacheKey)
        if let artifact {
            NativeFormulaRenderer.shared.storeExternalArtifact(artifact, cacheKey: job.cacheKey)
        } else if job.attempt < 2 {
            queuedKeys.insert(job.cacheKey)
            queue.append(
                Job(
                    tex: job.tex,
                    fontSize: job.fontSize,
                    color: job.color,
                    display: job.display,
                    maxWidth: job.maxWidth,
                    shrinkFloor: job.shrinkFloor,
                    scale: job.scale,
                    cacheKey: job.cacheKey,
                    attempt: job.attempt + 1
                )
            )
        } else {
            failedKeys.insert(job.cacheKey)
        }
        lane.webView?.frame = CGRect(origin: .zero, size: lane.canvasSize)
        lane.hostView?.frame.size = lane.canvasSize
        lane.busy = false
        pump()
    }

    private func cssColor(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "rgba(%d,%d,%d,%.3f)", Int(r * 255), Int(g * 255), Int(b * 255), Double(a))
        }
        return "rgba(0,0,0,1)"
    }

    private static let shellHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=1600, initial-scale=1, maximum-scale=1, user-scalable=no"/>
    <link rel="stylesheet" href="katex.min.css"/>
    <style>
      html, body {
        margin:0; padding:3px; background:transparent;
        -webkit-text-size-adjust:100%; text-size-adjust:100%;
      }
      #host { display:inline-block; line-height:1; margin:14px 0 0 14px; }
      .katex-display { margin:0; }
      .katex { -webkit-text-stroke: 0.2px currentColor; }
      .katex-error { color: #c0392b; }
      #preload {
        position:absolute; left:-9999px; top:0; opacity:0;
        font-family: KaTeX_Main, KaTeX_Math, KaTeX_Size1, KaTeX_Size2, KaTeX_Size3, KaTeX_Size4, KaTeX_AMS;
      }
    </style>
    <script src="katex.min.js"></script>
    <script src="mhchem.min.js"></script>
    </head>
    <body>
    <div id="preload">0∑∫α</div>
    <div id="host"></div>
    <script>
      var __connectsKaTeXMacros = {
        "\\\\Var": "\\\\operatorname{Var}",
        "\\\\Cov": "\\\\operatorname{Cov}",
        "\\\\Tr": "\\\\operatorname{Tr}",
        "\\\\tr": "\\\\operatorname{tr}",
        "\\\\sgn": "\\\\operatorname{sgn}",
        "\\\\sign": "\\\\operatorname{sign}",
        "\\\\rank": "\\\\operatorname{rank}",
        "\\\\diag": "\\\\operatorname{diag}",
        "\\\\grad": "\\\\operatorname{grad}",
        "\\\\curl": "\\\\operatorname{curl}",
        "\\\\sinc": "\\\\operatorname{sinc}",
        "\\\\erf": "\\\\operatorname{erf}",
        "\\\\rect": "\\\\operatorname{rect}",
        "\\\\span": "\\\\operatorname{span}",
        "\\\\E": "\\\\mathbb{E}",
        "\\\\mathbbm": "\\\\mathbb",
        "\\\\mathds": "\\\\mathbb",
        "\\\\mbox": "\\\\text",
        "\\\\emph": "\\\\textit",
        "\\\\textsc": "\\\\text",
        "\\\\dddot": "\\\\overset{\\\\cdots}{#1}",
        "\\\\hdots": "\\\\ldots",
        "\\\\qed": "\\\\square",
        "\\\\lb": "\\\\log_2",
        "\\\\abs": "\\\\left|#1\\\\right|",
        "\\\\norm": "\\\\left\\\\lVert#1\\\\right\\\\rVert",
        "\\\\bra": "\\\\left\\\\langle#1\\\\right|",
        "\\\\ket": "\\\\left|#1\\\\right\\\\rangle",
        "\\\\braket": "\\\\left\\\\langle#1\\\\middle|#2\\\\right\\\\rangle",
        "\\\\label": "\\\\vphantom{#1}",
        "\\\\nonumber": "",
        "\\\\notag": "",
        "\\\\vspace": "\\\\vphantom{#1}",
        "\\\\hfill": "\\\\quad",
        "\\\\eqref": "(\\\\text{#1})",
        "\\\\ref": "\\\\text{#1}"
      };
      window.__connectsRenderFormula = function(job) {
        var run = function() {
          var host = document.getElementById("host");
          host.style.color = job.color;
          // Mirrors the Swift-side padding added around the measured box.
          var pad = 3;
          // maxWidth/fontSize share units (UIKit points == CSS px in this shell).
          var maxWidth = (job.maxWidth && job.maxWidth > 0) ? job.maxWidth : 0;
          var floor = (job.shrinkFloor && job.shrinkFloor > 0)
            ? job.shrinkFloor
            : (job.display ? 0.55 : 0.7);
          var renderOnce = function(factor) {
            // .katex { font-size: 1.21em } — divide so the glyph size matches UIKit points.
            host.style.fontSize = (job.fontSize * factor / 1.21) + "px";
            host.innerHTML = "";
            try {
              katex.render(job.tex, host, {
                displayMode: !!job.display,
                throwOnError: true,
                strict: "ignore",
                trust: true,
                output: "html",
                macros: __connectsKaTeXMacros
              });
            } catch (e) {
              return {error: String(e)};
            }
            var el = host.querySelector(".katex-display") || host.querySelector(".katex") || host;
            var r = el.getBoundingClientRect();
            if (!r.width || !r.height) {
              return {error: "empty-katex"};
            }
            var top = r.top, bottom = r.bottom, left = r.left, right = r.right;
            // Painted ink overflows the element border box: underbrace labels
            // reach below it, radicals/superscripts above it. A Range rect unions
            // every rendered content box, so union the two for the true extent.
            try {
              var range = document.createRange();
              range.selectNodeContents(el);
              var rr = range.getBoundingClientRect();
              if (rr.width > 0 && rr.height > 0) {
                top = Math.min(top, rr.top);
                bottom = Math.max(bottom, rr.bottom);
                left = Math.min(left, rr.left);
                right = Math.max(right, rr.right);
              }
            } catch (e) {}
            return {width: right - left, height: bottom - top, top: top, left: left};
          };
          var result = renderOnce(1);
          if (result.error) {
            return {ok: false, error: result.error};
          }
          var factor = 1;
          if (maxWidth > 0 && floor < 1 && result.width + pad * 2 > maxWidth) {
            var candidates = [0.85, 0.75, 0.65, 0.55].filter(function(f) {
              return f >= floor - 0.001;
            });
            if (!candidates.length || Math.abs(candidates[candidates.length - 1] - floor) > 0.001) {
              candidates.push(floor);
            }
            // Largest fitting factor wins. Even when nothing fits, the loop ends on
            // the smallest render: scroll band (display) / attachment scaling
            // (inline) stays the last resort — never shrink below the floor.
            for (var i = 0; i < candidates.length; i++) {
              var attempt = renderOnce(candidates[i]);
              if (attempt.error) {
                return {ok: false, error: attempt.error};
              }
              result = attempt;
              factor = candidates[i];
              if (attempt.width + pad * 2 <= maxWidth) {
                break;
              }
            }
          }
          // The host still holds exactly what was measured — one snapshot pass,
          // no iterative relayout.
          return {ok: true, width: result.width, height: result.height,
                  top: result.top, left: result.left, factor: factor};
        };
        // Synchronous only: evaluateJavaScript cannot marshal a returned Promise
        // (WKErrorDomain 5 — reproduced under XCTest). Lanes only accept jobs
        // after the font preload poll confirms every face is cached.
        return run();
      };
    </script>
    </body>
    </html>
    """
}
