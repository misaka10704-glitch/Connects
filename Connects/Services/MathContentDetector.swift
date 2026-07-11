import Foundation
import UIKit

enum MathContentDetector {
    static func containsMath(_ text: String) -> Bool {
        if text.contains("$$") || text.contains("\\[") || text.contains("\\(") { return true }
        if text.contains("\\begin{") { return true }
        guard let regex = try? NSRegularExpression(pattern: #"\$[^$\n]+\$"#) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Bundle folder that holds katex.min.* and fonts/ (offline, works on iOS 12 / 无 CDN).
    static var katexBaseURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("katex", isDirectory: true)
    }

    /// Escape HTML; convert newlines to &lt;br&gt; only outside math delimiters.
    static func htmlBody(from markdownish: String) -> String {
        let placeholders = extractMathPlaceholders(markdownish)
        var s = placeholders.masked
        s = s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\n", with: "<br>\n")
        for (token, original) in placeholders.map {
            let escaped = original
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            s = s.replacingOccurrences(of: token, with: escaped)
        }
        return s
    }

    static func fullHTML(content: String, textColor: UIColor, backgroundColor: UIColor, fontSize: CGFloat = 16) -> String {
        let body = htmlBody(from: content)
        let fg = cssColor(textColor)
        let bg = cssColor(backgroundColor)
        let css = loadResource("katex.min.css") ?? ""
        let katexJS = loadResource("katex.min.js") ?? ""
        let autoJS = loadResource("auto-render.min.js") ?? ""
        // Prefer inlined scripts so WKWebView on iOS 12 doesn't need network.
        // Fonts still resolve relative to katexBaseURL (fonts/...).
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1"/>
        <style>
        \(css)
        </style>
        <style>
          html, body { margin:0; padding:0; background:\(bg); color:\(fg);
            font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size:\(Int(fontSize))px; line-height:1.55; word-wrap:break-word; overflow-wrap:break-word; -webkit-text-size-adjust:100%; }
          .katex-display { margin: 0.6em 0; overflow-x: auto; overflow-y: hidden; }
          #c { padding: 0; }
        </style>
        <script>\(katexJS)</script>
        <script>\(autoJS)</script>
        </head>
        <body>
        <div id="c">\(body)</div>
        <script>
          function reportHeight() {
            var el = document.getElementById("c");
            var h = Math.max(
              el ? el.scrollHeight : 0,
              document.body.scrollHeight,
              document.documentElement.scrollHeight
            );
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
              window.webkit.messageHandlers.height.postMessage(h);
            }
          }
          function run() {
            try {
              if (typeof renderMathInElement === "function") {
                renderMathInElement(document.getElementById("c"), {
                  delimiters: [
                    {left: "$$", right: "$$", display: true},
                    {left: "\\\\[", right: "\\\\]", display: true},
                    {left: "\\\\(", right: "\\\\)", display: false},
                    {left: "$", right: "$", display: false}
                  ],
                  ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code"],
                  throwOnError: false
                });
              }
            } catch (e) {}
            reportHeight();
            setTimeout(reportHeight, 50);
            setTimeout(reportHeight, 200);
            setTimeout(reportHeight, 600);
          }
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", run);
          } else {
            run();
          }
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Private

    private static func loadResource(_ name: String) -> String? {
        let base = katexBaseURL
        let url = base?.appendingPathComponent(name)
            ?? Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "katex")
        guard let url = url, let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private struct MathMask {
        let masked: String
        let map: [(String, String)]
    }

    /// Replace math spans with tokens so newline→br doesn't break KaTeX.
    private static func extractMathPlaceholders(_ text: String) -> MathMask {
        var result = text
        var map: [(String, String)] = []
        var index = 0

        func stash(_ pattern: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            // Replace from end so ranges stay valid
            for match in matches.reversed() {
                let original = ns.substring(with: match.range)
                let token = "§§MATH\(index)§§"
                index += 1
                map.append((token, original))
                result = (result as NSString).replacingCharacters(in: match.range, with: token)
            }
        }

        // Order: display first, then inline
        stash(#"\$\$[\s\S]+?\$\$"#)
        stash(#"\\\[[\s\S]+?\\\]"#)
        stash(#"\\\([\s\S]+?\\\)"#)
        stash(#"\$[^$\n]+\$"#)
        stash(#"\\begin\{[a-zA-Z*]+\}[\s\S]+?\\end\{[a-zA-Z*]+\}"#)

        return MathMask(masked: result, map: map)
    }

    private static func cssColor(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "rgba(%d,%d,%d,%.2f)", Int(r * 255), Int(g * 255), Int(b * 255), Double(a))
        }
        // Fallback for grayscale / non-RGB colors on older iOS
        var w: CGFloat = 0
        if color.getWhite(&w, alpha: &a) {
            let v = Int(w * 255)
            return String(format: "rgba(%d,%d,%d,%.2f)", v, v, v, Double(a))
        }
        return "rgba(255,255,255,1)"
    }
}
