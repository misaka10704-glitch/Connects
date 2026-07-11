import Foundation
import UIKit

/// Finished-message HTML: GFM markdown + KaTeX. Uses safe JS string escaping (iOS 12).
enum MarkdownHTMLRenderer {
    static var resourceBaseURL: URL? { Bundle.main.resourceURL }

    static func fullHTML(content: String,
                         textColor: UIColor,
                         backgroundColor: UIColor,
                         secondaryColor: UIColor,
                         fontSize: CGFloat) -> String {
        let fg = cssColor(textColor)
        let bg = cssColor(backgroundColor)
        let sec = cssColor(secondaryColor)
        let border = cssColor(textColor.withAlphaComponent(0.16))
        let normalized = normalizeMathDelimiters(content)
        let mdJSON = jsonString(normalized)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1"/>
        <link rel="stylesheet" href="katex/katex.min.css"/>
        <style>
          html, body { margin:0; padding:0; background:\(bg); color:\(fg);
            font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size:\(String(format: "%.1f", fontSize))px; line-height:1.65;
            word-wrap:break-word; overflow-wrap:break-word; -webkit-text-size-adjust:100%; }
          #c { padding: 0; }
          #c h1,#c h2,#c h3 { font-weight: 600; line-height: 1.3; margin: 0.9em 0 0.4em; }
          #c h1 { font-size: 1.35em; } #c h2 { font-size: 1.2em; } #c h3 { font-size: 1.08em; }
          #c p { margin: 0.55em 0; }
          #c ul, #c ol { margin: 0.45em 0; padding-left: 1.35em; }
          #c li { margin: 0.22em 0; }
          #c strong { font-weight: 700; }
          #c em { font-style: italic; }
          #c a { color: #4da3ff; }
          #c code { font-family: Menlo, Monaco, monospace; font-size: 0.9em;
            background: rgba(127,127,127,0.16); padding: 0.12em 0.35em; border-radius: 4px; }
          #c pre { background: rgba(127,127,127,0.12); padding: 12px 14px; border-radius: 10px;
            overflow-x: auto; margin: 0.75em 0; }
          #c pre code { background: transparent; padding: 0; }
          #c blockquote { margin: 0.65em 0; padding: 0.15em 0 0.15em 0.9em;
            border-left: 3px solid \(border); color: \(sec); }
          #c table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 0.95em;
            display: block; overflow-x: auto; -webkit-overflow-scrolling: touch; }
          #c th, #c td { border: 1px solid \(border); padding: 7px 10px; text-align: left; }
          #c th { background: rgba(127,127,127,0.1); font-weight: 600; }
          #c hr { border: none; border-top: 1px solid \(border); margin: 1em 0; }
          .katex-display { margin: 0.75em 0; overflow-x: auto; overflow-y: hidden; }
        </style>
        <script src="markdown/marked.min.js"></script>
        <script src="katex/katex.min.js"></script>
        <script src="katex/auto-render.min.js"></script>
        </head>
        <body>
        <div id="c"></div>
        <script>
          function reportHeight() {
            var el = document.getElementById("c");
            var h = Math.max(el ? el.scrollHeight : 0, document.body.scrollHeight, document.documentElement.scrollHeight);
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
              window.webkit.messageHandlers.height.postMessage(h);
            }
          }
          function protectMath(src) {
            var map = [];
            var i = 0;
            function stash(re) {
              src = src.replace(re, function(m) {
                var key = "@@MATH" + (i++) + "@@";
                map.push([key, m]);
                return key;
              });
            }
            stash(/\\$\\$[\\s\\S]+?\\$\\$/g);
            stash(/\\\\\\[[\\s\\S]+?\\\\\\]/g);
            stash(/\\\\\\([\\s\\S]+?\\\\\\)/g);
            stash(/\\$[^$\\n]+\\$/g);
            stash(/\\\\begin\\{[a-zA-Z*]+\\}[\\s\\S]+?\\\\end\\{[a-zA-Z*]+\\}/g);
            return { src: src, map: map };
          }
          function restoreMath(html, map) {
            for (var k = 0; k < map.length; k++) {
              html = html.split(map[k][0]).join(map[k][1]);
            }
            return html;
          }
          function run() {
            var md = \(mdJSON);
            var el = document.getElementById("c");
            try {
              if (typeof marked !== "undefined") {
                marked.setOptions({ gfm: true, breaks: true, headerIds: false, mangle: false });
                var packed = protectMath(md);
                var html = marked.parse(packed.src);
                html = restoreMath(html, packed.map);
                el.innerHTML = html;
              } else {
                el.textContent = md;
              }
              if (typeof renderMathInElement === "function") {
                renderMathInElement(el, {
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
            } catch (e) {
              el.textContent = md;
            }
            reportHeight();
            setTimeout(reportHeight, 80);
            setTimeout(reportHeight, 280);
            setTimeout(reportHeight, 700);
          }
          if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run);
          else run();
        </script>
        </body>
        </html>
        """
    }

    /// Normalize odd model outputs toward KaTeX-friendly delimiters.
    static func normalizeMathDelimiters(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "［", with: "[")
        s = s.replacingOccurrences(of: "］", with: "]")
        // ```math / ```latex / ```tex fences → display math
        if let re = try? NSRegularExpression(
            pattern: "```(?:math|latex|tex)\\s*\\n([\\s\\S]*?)```",
            options: [.caseInsensitive]
        ) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$$$$1$$")
        }
        return s
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x00..<0x20:
                out += String(format: "\\u%04x", ch.value)
            default:
                out.append(Character(ch))
            }
        }
        out += "\""
        return out
    }

    private static func cssColor(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "rgba(%d,%d,%d,%.2f)", Int(r * 255), Int(g * 255), Int(b * 255), Double(a))
        }
        var w: CGFloat = 0
        if color.getWhite(&w, alpha: &a) {
            let v = Int(w * 255)
            return String(format: "rgba(%d,%d,%d,%.2f)", v, v, v, Double(a))
        }
        return "rgba(255,255,255,1)"
    }
}
