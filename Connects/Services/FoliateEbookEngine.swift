import UIKit
import WebKit

/// WKWebView host for Foliate-js EPUB / MOBI / AZW3 reading.
///
/// Working constraints on iOS WKWebView:
/// - `file://` fetch of book bytes → "Load failed"
/// - Multi‑MB book as `WKUserScript` → IIFE batch dropped → "ConnectsFoliate missing"
/// - `fetch(custom-scheme://…)` from an `https` document → "Load failed"
///
/// Strategy that survives those:
/// 1. Inline Foliate IIFE in `loadHTMLString` (https baseURL for blob iframes)
/// 2. Page exposes `__connectsPushChunk` / `__connectsOpen`
/// 3. After `didFinish`, native pushes book base64 in chunks, then opens
final class FoliateEbookEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct TOCItem {
        let title: String
        let href: String?
    }

    var onReady: (([TOCItem]) -> Void)?
    var onRelocate: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var webView: WKWebView!
    private var lastLocationJSON: String?
    private var pendingBook: (data: Data, fileName: String)?
    private var openGeneration = 0
    private static let pageBaseURL = URL(string: "https://connects.foliate.local/")!
    private static let chunkSize = 240_000

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "foliate")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        #if DEBUG
        if #available(iOS 16.4, macCatalyst 16.4, *) {
            webView.isInspectable = true
        }
        #endif
    }

    func loadBook(data: Data, fileName: String) {
        guard let iifeRaw = Self.loadBundledIIFE() else {
            onError?("缺少 Foliate 资源（Resources/Foliate/foliate.iife.js）")
            return
        }
        let iife = iifeRaw.replacingOccurrences(of: "</script>", with: "<\\/script>", options: .caseInsensitive)
        openGeneration &+= 1
        let gen = openGeneration
        pendingBook = (data, fileName)

        let html = """
        <!DOCTYPE html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no" />
          <meta http-equiv="Content-Security-Policy" content="default-src * blob: data: 'unsafe-inline' 'unsafe-eval'; script-src * 'unsafe-inline' 'unsafe-eval' blob:; frame-src * blob: data:; img-src * blob: data:; style-src * 'unsafe-inline'; worker-src * blob:;" />
          <style>
            html, body { margin: 0; height: 100%; width: 100%; background: #ffffff; overflow: hidden; }
            foliate-view { display: block; width: 100%; height: 100%; }
          </style>
        </head>
        <body>
          <script>
          try {
          \(iife)
          } catch (e) {
            try {
              window.webkit.messageHandlers.foliate.postMessage({
                type: 'error',
                message: 'Foliate IIFE: ' + ((e && e.message) ? e.message : String(e))
              })
            } catch (_) {}
          }
          </script>
          <script>
            window.__CONNECTS_BOOK_CHUNKS = [];
            window.__connectsPushChunk = function (chunk) {
              window.__CONNECTS_BOOK_CHUNKS.push(String(chunk));
              return window.__CONNECTS_BOOK_CHUNKS.length;
            };
            window.__connectsApplyViewport = function (w, h) {
              var W = Math.max(1, Math.floor(w));
              var H = Math.max(1, Math.floor(h));
              document.documentElement.style.width = W + 'px';
              document.documentElement.style.height = H + 'px';
              document.body.style.width = W + 'px';
              document.body.style.height = H + 'px';
              var view = document.querySelector('foliate-view') || window.__foliateView;
              if (view) {
                view.style.display = 'block';
                view.style.width = W + 'px';
                view.style.height = H + 'px';
              }
              try { window.dispatchEvent(new Event('resize')); } catch (_) {}
              return [W, H];
            };
            window.__connectsOpen = async function (name) {
              const report = (message) => {
                try {
                  window.webkit.messageHandlers.foliate.postMessage({ type: 'error', message: String(message) })
                } catch (_) {}
              }
              try {
                if (!window.ConnectsFoliate || !window.ConnectsFoliate.openFromArrayBuffer) {
                  throw new Error('ConnectsFoliate missing after inline IIFE')
                }
                const b64 = window.__CONNECTS_BOOK_CHUNKS.join('')
                window.__CONNECTS_BOOK_CHUNKS = []
                if (!b64 || b64.length < 16) throw new Error('Book payload empty after chunks')
                const bin = atob(b64)
                const bytes = new Uint8Array(bin.length)
                for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
                await window.ConnectsFoliate.openFromArrayBuffer(bytes.buffer, name || 'book.epub')
              } catch (e) {
                report((e && e.message) ? e.message : String(e))
              }
            };
          </script>
        </body>
        </html>
        """
        webView.accessibilityValue = "\(gen)"
        webView.loadHTMLString(html, baseURL: Self.pageBaseURL)
    }

    /// Push current UIKit bounds into the page so Foliate's paginator gets a real size.
    func syncViewportFromWebViewBounds() {
        let b = webView.bounds
        guard b.width > 32, b.height > 32 else { return }
        webView.evaluateJavaScript(
            "window.__connectsApplyViewport && window.__connectsApplyViewport(\(b.width), \(b.height))",
            completionHandler: nil
        )
    }

    func clear() {
        openGeneration &+= 1
        pendingBook = nil
        lastLocationJSON = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func goNext() {
        webView.evaluateJavaScript("window.ConnectsFoliate && ConnectsFoliate.next()", completionHandler: nil)
    }

    func goPrev() {
        webView.evaluateJavaScript("window.ConnectsFoliate && ConnectsFoliate.prev()", completionHandler: nil)
    }

    func goTo(href: String) {
        let escaped = href
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.ConnectsFoliate && ConnectsFoliate.goTo('\(escaped)')", completionHandler: nil)
    }

    func setFontScale(_ scale: Double) {
        webView.evaluateJavaScript("window.ConnectsFoliate && ConnectsFoliate.setFontSize(\(scale))", completionHandler: nil)
    }

    func setChromeColors(backgroundHex: String, foregroundHex: String) {
        if let bg = UIColor(foliateHex: backgroundHex) {
            webView.backgroundColor = bg
            webView.scrollView.backgroundColor = bg
        }
        webView.evaluateJavaScript(
            """
            (function(){
              document.documentElement.style.background='\(backgroundHex)';
              document.body.style.background='\(backgroundHex)';
              document.body.style.color='\(foregroundHex)';
              var v=window.__foliateView;
              if(v&&v.renderer){
                try{
                  v.renderer.setAttribute('style',
                    (v.renderer.getAttribute('style')||'')+
                    ';--background-color:\(backgroundHex);--text-color:\(foregroundHex);background:\(backgroundHex);color:\(foregroundHex);');
                }catch(e){}
              }
            })();
            """,
            completionHandler: nil
        )
    }

    func restoreLocationJSON(_ json: String) {
        lastLocationJSON = json
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let frac = obj["fraction"] as? Double {
            webView.evaluateJavaScript(
                "window.__foliateView && window.__foliateView.goToFraction(\(frac))",
                completionHandler: nil
            )
        } else if let cfi = obj["cfi"] as? String {
            let escaped = cfi.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("window.ConnectsFoliate && ConnectsFoliate.goTo('\(escaped)')", completionHandler: nil)
        }
    }

    var locationJSON: String? { lastLocationJSON }

    func evaluateVisibleTextLength(completion: @escaping (Int) -> Void) {
        let js = """
        (function(){
          try {
            var view = window.__foliateView;
            if (!view || !view.renderer || typeof view.renderer.getContents !== 'function') return 0;
            var contents = view.renderer.getContents() || [];
            var text = '';
            for (var i = 0; i < contents.length; i++) {
              var c = contents[i];
              if (c && c.doc && c.doc.body) text += (c.doc.body.innerText || '');
            }
            return String(text).replace(/\\s+/g, ' ').trim().length;
          } catch (e) { return 0; }
        })()
        """
        webView.evaluateJavaScript(js) { result, _ in
            completion((result as? Int) ?? (result as? Double).map { Int($0) } ?? 0)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        deliverPendingBookIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError?("页面导航失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onError?("页面加载失败：\(error.localizedDescription)")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "foliate",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            var items: [TOCItem] = []
            if let toc = body["toc"] as? [[String: Any]] {
                items = flattenTOC(toc)
            }
            onReady?(items)
        case "relocate":
            if let detail = body["detail"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: detail),
               let json = String(data: data, encoding: .utf8) {
                lastLocationJSON = json
            }
            if let detail = body["detail"] as? [String: Any] {
                onRelocate?(detail)
            }
        case "error":
            onError?(body["message"] as? String ?? "Foliate error")
        default:
            break
        }
    }

    // MARK: - Book delivery

    private func deliverPendingBookIfNeeded() {
        guard let pending = pendingBook else { return }
        pendingBook = nil
        let gen = openGeneration
        let b64 = pending.data.base64EncodedString()
        let nameJSON = FoliateJSON.string(pending.fileName)
        let chunks: [String] = stride(from: 0, to: b64.count, by: Self.chunkSize).map { start in
            let s = b64.index(b64.startIndex, offsetBy: start)
            let e = b64.index(s, offsetBy: min(Self.chunkSize, b64.distance(from: s, to: b64.endIndex)))
            return String(b64[s..<e])
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait until the WKWebView has a real layout box (paginator needs it).
            for _ in 0 ..< 40 {
                self.webView.superview?.layoutIfNeeded()
                self.webView.layoutIfNeeded()
                if self.webView.bounds.width > 32, self.webView.bounds.height > 32 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            let b = self.webView.bounds
            _ = await self.eval(
                "window.__connectsApplyViewport && window.__connectsApplyViewport(\(max(b.width, 320)), \(max(b.height, 480)))"
            )

            let resetErr = await self.eval("window.__CONNECTS_BOOK_CHUNKS = []; true")
            if let resetErr {
                self.onError?("准备书数据失败：\(resetErr)")
                return
            }
            for chunk in chunks {
                guard self.openGeneration == gen else { return }
                let payload = FoliateJSON.string(chunk)
                if let err = await self.eval("window.__connectsPushChunk(\(payload))") {
                    self.onError?("注入书数据失败：\(err)")
                    return
                }
            }
            guard self.openGeneration == gen else { return }
            // async __connectsOpen returns a Promise — WK cannot bridge it; ignore return.
            if let err = await self.eval("void window.__connectsOpen(\(nameJSON))") {
                self.onError?("打开电子书失败：\(err)")
                return
            }
            // Re-assert viewport after foliate-view is created.
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.syncViewportFromWebViewBounds()
        }
    }

    @MainActor
    private func eval(_ js: String) async -> String? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    cont.resume(returning: error.localizedDescription)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func loadBundledIIFE() -> String? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Foliate", isDirectory: true) else {
            return nil
        }
        return try? String(contentsOf: root.appendingPathComponent("foliate.iife.js"), encoding: .utf8)
    }

    private func flattenTOC(_ nodes: [[String: Any]], prefix: String = "") -> [TOCItem] {
        var out: [TOCItem] = []
        for node in nodes {
            let title = (node["label"] as? String)
                ?? (node["title"] as? String)
                ?? "Untitled"
            let href = node["href"] as? String
            out.append(TOCItem(title: prefix + title, href: href))
            if let children = node["subitems"] as? [[String: Any]] ?? node["children"] as? [[String: Any]] {
                out.append(contentsOf: flattenTOC(children, prefix: prefix + "  "))
            }
        }
        return out
    }
}

private enum FoliateJSON {
    static func string(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let arrayJSON = String(data: data, encoding: .utf8),
           arrayJSON.count >= 2 {
            return String(arrayJSON.dropFirst().dropLast())
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private extension UIColor {
    convenience init?(foliateHex: String) {
        var s = foliateHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: 1
        )
    }
}
