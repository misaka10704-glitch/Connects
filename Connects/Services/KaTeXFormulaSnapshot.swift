import UIKit
import WebKit

/// Off-screen KaTeX → PNG. Chat bubbles stay native bitmaps; this WKWebView is never in a cell.
final class KaTeXFormulaSnapshot: NSObject, WKNavigationDelegate {
    static let shared = KaTeXFormulaSnapshot()

    private struct Job {
        let tex: String
        let fontSize: CGFloat
        let color: UIColor
        let display: Bool
        let scale: CGFloat
        let cacheKey: String
    }

    private let canvasSize = CGSize(width: 1600, height: 900)
    private var webView: WKWebView?
    private var ready = false
    private var started = false
    private var busy = false
    private var queue: [Job] = []
    private var queuedKeys = Set<String>()
    private var failedKeys = Set<String>()
    private var hostView: UIView?

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
                    cacheKey: cacheKey
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
            installWebView()
        }
        attachToKeyWindow()
    }

    private func installWebView() {
        if webView != nil { return }
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("katex", isDirectory: true) else {
            return
        }
        let config = ConnectsWebKit.makeConfiguration()
        let wv = WKWebView(frame: CGRect(origin: .zero, size: canvasSize), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.minimumZoomScale = 1
        wv.scrollView.maximumZoomScale = 1
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.navigationDelegate = self
        let host = UIView(frame: CGRect(x: -canvasSize.width - 80, y: 0, width: canvasSize.width, height: canvasSize.height))
        // Must stay in the window and un-hidden: iOS 15 takeSnapshot skips fonts in hidden WKWebViews.
        host.isHidden = false
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        host.addSubview(wv)
        wv.frame = host.bounds
        hostView = host
        webView = wv
        attachToKeyWindow()
        wv.loadHTMLString(Self.shellHTML, baseURL: base)
    }

    private func attachToKeyWindow() {
        guard let host = hostView, host.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.windows.first { $0.isKeyWindow }
        window?.addSubview(host)
        host.frame = CGRect(
            x: -canvasSize.width - 80,
            y: 0,
            width: canvasSize.width,
            height: canvasSize.height
        )
        webView?.frame = host.bounds
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.fonts.ready.then(function(){ return true; })") { [weak self] _, _ in
            self?.ready = true
            self?.pump()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ready = false
    }

    private func pump() {
        attachToKeyWindow()
        guard ready, !busy, let job = queue.first, let webView else { return }
        busy = true
        queue.removeFirst()
        render(job, in: webView)
    }

    private func render(_ job: Job, in webView: WKWebView) {
        webView.frame = CGRect(origin: .zero, size: canvasSize)
        webView.bounds = CGRect(origin: .zero, size: canvasSize)
        let payload: [String: Any] = [
            "tex": job.tex,
            "display": job.display,
            "fontSize": Double(job.fontSize),
            "color": cssColor(job.color)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            finish(job, artifact: nil)
            return
        }
        webView.evaluateJavaScript("window.__connectsRenderFormula(\(json))") { [weak self] result, error in
            guard let self else { return }
            if error != nil {
                self.finish(job, artifact: nil)
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
                self.finish(job, artifact: nil)
                return
            }
            guard dict["ok"] as? Bool == true,
                  let width = dict["width"] as? Double,
                  let height = dict["height"] as? Double,
                  width > 0, height > 0 else {
                self.finish(job, artifact: nil)
                return
            }
            let pad: CGFloat = 3
            let size = CGSize(
                width: ceil(CGFloat(width) + pad * 2),
                height: ceil(CGFloat(height) + pad * 2)
            )
            webView.frame = CGRect(origin: .zero, size: size)
            webView.bounds = CGRect(origin: .zero, size: size)
            if let host = self.hostView {
                host.frame.size = size
            }
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
            DispatchQueue.main.async {
                self.snapshot(job, in: webView, size: size)
            }
        }
    }

    private func snapshot(_ job: Job, in webView: WKWebView, size: CGSize) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        // snapshotWidth is in *points*. Multiplying by screen scale made attachments 2×/3×.
        if #available(iOS 13.0, *) {
            config.snapshotWidth = NSNumber(value: Double(size.width))
        }
        webView.takeSnapshot(with: config) { image, _ in
            guard let image, let cg = image.cgImage else {
                self.finish(job, artifact: nil)
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
            self.finish(job, artifact: artifact)
        }
    }

    private func finish(_ job: Job, artifact: NativeFormulaArtifact?) {
        queuedKeys.remove(job.cacheKey)
        if let artifact {
            NativeFormulaRenderer.shared.storeExternalArtifact(artifact, cacheKey: job.cacheKey)
        } else {
            failedKeys.insert(job.cacheKey)
        }
        webView?.frame = CGRect(origin: .zero, size: canvasSize)
        hostView?.frame.size = canvasSize
        busy = false
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
      #preload {
        position:absolute; left:-9999px; top:0; opacity:0;
        font-family: KaTeX_Main, KaTeX_Math, KaTeX_Size1, KaTeX_Size2, KaTeX_Size3, KaTeX_Size4, KaTeX_AMS;
      }
    </style>
    <script src="katex.min.js"></script>
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
              throwOnError: true,
              strict: "ignore",
              output: "html"
            });
          } catch (e) {
            return {ok: false, error: String(e && e.message ? e.message : e)};
          }
          var el = host.querySelector(".katex-display") || host.querySelector(".katex") || host;
          var r = el.getBoundingClientRect();
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
