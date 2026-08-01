import UIKit
import WebKit

/// Shared iOS 15+ WKWebView setup for Study reading and offscreen snapshot workers.
/// Chat bubbles stay on Native bitmaps; WebKit must stay out of recycled table cells.
enum ConnectsWebKit {
    static func makeConfiguration(userContentController: WKUserContentController? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.suppressesIncrementalRendering = false
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if let userContentController {
            config.userContentController = userContentController
        }
        return config
    }

    /// Tune scrolling / compositing for long Study documents (WKWebView owns scroll).
    static func applyReadingSurfaceTuning(_ webView: WKWebView, background: UIColor) {
        webView.isOpaque = true
        webView.backgroundColor = background
        webView.underPageBackgroundColor = background
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }

        let scroll = webView.scrollView
        scroll.isScrollEnabled = true
        scroll.backgroundColor = background
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = true
        scroll.alwaysBounceHorizontal = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.decelerationRate = .normal
        // false = finger drag scrolls immediately (Safari-like). true waits ~150ms for
        // nested controls and feels like "滑了之后页面才跟着动".
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        scroll.keyboardDismissMode = .interactive
        // Avoid a direction-ambiguity pause at gesture start on long docs.
        scroll.isDirectionalLockEnabled = false
        scroll.panGestureRecognizer.delaysTouchesBegan = false
        scroll.panGestureRecognizer.delaysTouchesEnded = false
        // Avoid nested zoom fighting Study pinch elsewhere.
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.bouncesZoom = false
        if #available(iOS 15.0, *) {
            scroll.automaticallyAdjustsScrollIndicatorInsets = false
        }
    }

    /// CSS for long fences / blocks: skip offscreen layout work (Safari 15+).
    static var scrollPerformanceCSS: String {
        """
        @supports (content-visibility: auto) {
          #c pre, #c table, #c blockquote, #c .katex-display {
            content-visibility: auto;
            contain-intrinsic-size: auto 160px;
          }
        }
        #c pre { contain: layout style paint; }
        #c pre code { white-space: pre; tab-size: 4; }
        """
    }
}

/// Spins WebKit + marked (and optionally KaTeX) once at launch so the first
/// rich snapshot worker is not a cold start on iPad Air 1.
enum WebKitRenderWarmup {
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

        let config = ConnectsWebKit.makeConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 1), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false

        if host == nil {
            let h = UIView(frame: CGRect(x: -8, y: -8, width: 8, height: 8))
            h.isUserInteractionEnabled = false
            h.alpha = 0.01
            h.clipsToBounds = true
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
                ?? UIApplication.shared.windows.first
            window?.addSubview(h)
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
