#!/usr/bin/env swift
import Foundation
import WebKit
import AppKit

final class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private var cont: CheckedContinuation<String, Never>?
    private var done = false

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 1200), configuration: config)
        super.init()
        config.userContentController.add(self, name: "foliate")
        webView.navigationDelegate = self
    }

    func open(htmlURL: URL, timeout: TimeInterval) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            cont = c
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish("TIMEOUT")
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            let n = (body["toc"] as? [Any])?.count ?? 0
            finish("READY toc=\(n)")
        case "error":
            finish("ERROR \(body["message"] as? String ?? "?")")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.webView.evaluateJavaScript(
                "JSON.stringify({has:!!window.ConnectsFoliate,view:!!document.querySelector('foliate-view'),body:(document.body&&document.body.innerText||'').slice(0,80)})"
            ) { result, _ in
                if let s = result as? String {
                    self?.finish("FALLBACK \(s)")
                }
            }
        }
    }

    private func finish(_ value: String) {
        guard !done else { return }
        done = true
        cont?.resume(returning: value)
        cont = nil
    }
}

func buildHTML(iife: String, book: Data, name: String) -> String {
    let src = iife.replacingOccurrences(of: "</script>", with: "<\\/script>", options: .caseInsensitive)
    let b64 = book.base64EncodedString()
    let nameJSON: String = {
        let data = try! JSONSerialization.data(withJSONObject: [name], options: [])
        let s = String(data: data, encoding: .utf8)!
        return String(s.dropFirst().dropLast())
    }()
    return """
    <!DOCTYPE html><html><head><meta charset="utf-8"/></head><body>
    <script>
    try { \(src) } catch (e) {
      window.webkit.messageHandlers.foliate.postMessage({type:'error', message:'IIFE:'+((e&&e.message)||String(e))})
    }
    </script>
    <script>
    (async () => {
      try {
        if (!window.ConnectsFoliate) throw new Error('ConnectsFoliate missing after inline IIFE')
        const name = \(nameJSON)
        const b64 = "\(b64)"
        const bin = atob(b64)
        const bytes = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
        await window.ConnectsFoliate.openFromArrayBuffer(bytes.buffer, name)
      } catch (e) {
        window.webkit.messageHandlers.foliate.postMessage({
          type: 'error',
          message: (e && e.message) ? e.message : String(e)
        })
      }
    })()
    </script>
    </body></html>
    """
}

let iifePath = URL(fileURLWithPath: "/Users/misaka10704/Documents/Workspace/Connects/Connects/Resources/Foliate/foliate.iife.js")
let books = [
    "/Users/misaka10704/Documents/Workspace/Engineer_Tex/Reading/Philosophy/新教伦理与资本主义精神.epub",
    "/Users/misaka10704/Documents/Workspace/Engineer_Tex/Reading/Philosophy/极权主义的起源.epub",
]

let iife = try String(contentsOf: iifePath, encoding: .utf8)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Runner {
    var failures = 0
    func run() async {
        for path in books {
            let url = URL(fileURLWithPath: path)
            let data = try! Data(contentsOf: url)
            let name = url.lastPathComponent
            print("==> \(name) (\(data.count) bytes)")
            let html = buildHTML(iife: iife, book: data, name: name)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let htmlURL = dir.appendingPathComponent("reader.html")
            try! html.write(to: htmlURL, atomically: true, encoding: .utf8)

            let probe = await MainActor.run { Probe() }
            let result = await probe.open(htmlURL: htmlURL, timeout: 25)
            print("    \(result)")
            if !result.hasPrefix("READY") {
                failures += 1
            }
        }
        print(failures == 0 ? "ALL PASS" : "FAILURES=\(failures)")
        exit(failures == 0 ? 0 : 2)
    }
}

let runner = Runner()
Task { await runner.run() }
app.run()
