import UIKit
import WebKit

/// Spins WebKit + marked (and optionally KaTeX) once at launch so the first
/// rich message cell is not a cold start on iPad Air 1.
enum WebKitRenderWarmup {
    /// Shared by every MessageCell WKWebView — keeps one WebContent process warm.
    static let processPool = WKProcessPool()

    private static var host: UIView?
    private static var lightWebView: WKWebView?
    private static var mathWebView: WKWebView?
    private static var started = false
    private(set) static var lightReady = false
    private(set) static var mathReady = false

    /// Call as early as possible. Light shell (marked only) installs immediately;
    /// KaTeX shell warms in the background.
    static func prepare() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async {
            prefetchBundleAssets(includeMath: false)
            DispatchQueue.main.async {
                installShell(includeMath: false)
            }
            prefetchBundleAssets(includeMath: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                installShell(includeMath: true)
            }
        }
    }

    private static func prefetchBundleAssets(includeMath: Bool) {
        guard let base = MarkdownHTMLRenderer.resourceBaseURL else { return }
        var names = ["markdown/marked.min.js"]
        if includeMath {
            names += ["katex/katex.min.js", "katex/auto-render.min.js", "katex/katex.min.css"]
        }
        for name in names {
            _ = try? Data(contentsOf: base.appendingPathComponent(name))
        }
    }

    private static func installShell(includeMath: Bool) {
        if includeMath, mathWebView != nil { return }
        if !includeMath, lightWebView != nil { return }

        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.preferences.javaScriptEnabled = true
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 1), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false

        if host == nil {
            let h = UIView(frame: CGRect(x: -8, y: -8, width: 8, height: 8))
            h.isUserInteractionEnabled = false
            h.alpha = 0.01
            h.clipsToBounds = true
            UIApplication.shared.keyWindow?.addSubview(h)
            host = h
        }
        guard let host = host else { return }
        host.addSubview(wv)
        wv.frame = CGRect(x: 0, y: includeMath ? 4 : 0, width: 4, height: 4)

        let c = DSTheme.c
        let html = MarkdownHTMLRenderer.shellHTML(
            textColor: c.textPrimary,
            backgroundColor: c.background,
            secondaryColor: c.textSecondary,
            fontSize: 16,
            includeMath: includeMath
        )
        wv.loadHTMLString(html, baseURL: MarkdownHTMLRenderer.resourceBaseURL)
        wv.evaluateJavaScript("1+1") { _, _ in
            DispatchQueue.main.async {
                if includeMath { mathReady = true } else { lightReady = true }
            }
        }

        if includeMath {
            mathWebView = wv
        } else {
            lightWebView = wv
        }
    }
}
