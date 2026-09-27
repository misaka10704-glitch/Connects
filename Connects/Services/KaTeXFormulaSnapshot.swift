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

    private func attachToKeyWindow() {
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            """
            (document.fonts && document.fonts.load)
              ? document.fonts.load('16px KaTeX_Main').then(function(){ return true; })
              : Promise.resolve(true)
            """
        ) { [weak self] _, _ in
            guard let self, let lane = self.lanes.first(where: { $0.webView === webView }) else { return }
            lane.ready = true
            self.pump()
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
            "color": cssColor(job.color)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            finish(job, artifact: nil, lane: lane)
            return
        }
        webView.evaluateJavaScript("window.__connectsRenderFormula(\(json))") { [weak self] result, error in
            guard let self else { return }
            if error != nil {
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
                self.finish(job, artifact: nil, lane: lane)
                return
            }
            guard dict["ok"] as? Bool == true,
                  let width = dict["width"] as? Double,
                  let height = dict["height"] as? Double,
                  width > 0, height > 0 else {
                self.finish(job, artifact: nil, lane: lane)
                return
            }
            let pad: CGFloat = 3
            let size = CGSize(
                width: ceil(CGFloat(width) + pad * 2),
                height: ceil(CGFloat(height) + pad * 2)
            )
            webView.frame = CGRect(origin: .zero, size: size)
            webView.bounds = CGRect(origin: .zero, size: size)
            lane.hostView?.frame.size = size
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
            DispatchQueue.main.async {
                self.snapshot(job, in: webView, size: size, lane: lane)
            }
        }
    }

    private func snapshot(_ job: Job, in webView: WKWebView, size: CGSize, lane: Lane) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        config.snapshotWidth = NSNumber(value: Double(size.width))
        webView.takeSnapshot(with: config) { image, _ in
            guard let image, let cg = image.cgImage else {
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
      #host { display:inline-block; line-height:1; }
      .katex-display { margin:0; }
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
      window.__connectsRenderFormula = function(job) {
        var run = function() {
          var host = document.getElementById("host");
          // .katex { font-size: 1.21em } — divide so the glyph size matches UIKit points.
          host.style.fontSize = (job.fontSize / 1.21) + "px";
          host.style.color = job.color;
          host.innerHTML = "";
          try {
            katex.render(job.tex, host, {
              displayMode: !!job.display,
              throwOnError: false,
              strict: "ignore",
              trust: true,
              output: "html"
            });
          } catch (e) {
            host.textContent = job.tex;
            host.style.color = "#c0392b";
          }
          var el = host.querySelector(".katex-display") || host.querySelector(".katex") || host;
          var r = el.getBoundingClientRect();
          if (!r.width || !r.height) {
            return {ok: false, error: "empty-katex"};
          }
          return {ok: true, width: r.width, height: r.height};
        };
        if (document.fonts && document.fonts.ready) {
          return document.fonts.ready.then(run);
        }
        return run();
      };
    </script>
    </body>
    </html>
    """
}
