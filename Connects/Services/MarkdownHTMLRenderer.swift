import Foundation
import UIKit

/// Finished-message HTML: GFM markdown + KaTeX.
/// Loads a persistent shell once; content is injected via JS (avoids re-parsing katex/marked every cell).
enum MarkdownHTMLRenderer {
    static var resourceBaseURL: URL? { Bundle.main.resourceURL }

    /// Empty document with scripts + `window.__connectsRender(md)`.
    /// `includeMath: false` skips KaTeX (~270KB JS + fonts) — much faster on A7.
    static func shellHTML(textColor: UIColor,
                          backgroundColor: UIColor,
                          secondaryColor: UIColor,
                          fontSize: CGFloat,
                          includeMath: Bool = true) -> String {
        let fg = cssColor(textColor)
        let bg = cssColor(backgroundColor)
        let sec = cssColor(secondaryColor)
        let border = cssColor(textColor.withAlphaComponent(0.16))
        let katexCSS = includeMath ? #"<link rel="stylesheet" href="katex/katex.min.css"/>"# : ""
        let katexJS = includeMath
            ? #"<script src="katex/katex.min.js"></script><script src="katex/auto-render.min.js"></script>"#
            : ""
        let mathRender = includeMath
            ? """
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
              """
            : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1"/>
        \(katexCSS)
        <style>
          html, body { margin:0; padding:0; background:\(bg); color:\(fg);
            font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size:\(String(format: "%.1f", fontSize))px; line-height:1.65;
            word-wrap:break-word; overflow-wrap:break-word; -webkit-text-size-adjust:100%;
            height:auto !important; min-height:0 !important; overflow:hidden; }
          #c { padding:0; display:flow-root; }
          #c h1,#c h2,#c h3 { font-weight:600; line-height:1.3; margin:0.85em 0 0.35em; }
          #c h1 { font-size:1.35em; } #c h2 { font-size:1.2em; } #c h3 { font-size:1.08em; }
          #c p { margin:0.5em 0; }
          #c ul, #c ol { margin:0.4em 0; padding-left:1.35em; }
          #c li { margin:0.2em 0; }
          #c strong { font-weight:700; }
          #c em { font-style:italic; }
          #c a { color:#4da3ff; }
          #c code { font-family:Menlo, Monaco, monospace; font-size:0.9em;
            background:rgba(127,127,127,0.16); padding:0.12em 0.35em; border-radius:4px; }
          #c pre { background:rgba(127,127,127,0.12); padding:12px 14px; border-radius:10px;
            overflow-x:auto; margin:0.7em 0; -webkit-overflow-scrolling:touch; }
          #c pre code { background:transparent; padding:0; }
          #c blockquote { margin:0.6em 0; padding:0.1em 0 0.1em 0.9em;
            border-left:3px solid \(border); color:\(sec); }
          #c table { border-collapse:collapse; width:100%; margin:0.75em 0; font-size:0.95em;
            display:block; overflow-x:auto; -webkit-overflow-scrolling:touch; }
          #c th, #c td { border:1px solid \(border); padding:7px 10px; text-align:left; }
          #c th { background:rgba(127,127,127,0.1); font-weight:600; }
          #c hr { border:none; border-top:1px solid \(border); margin:0.9em 0; }
          .katex-display { margin:0.7em 0; overflow-x:auto; overflow-y:hidden; }
        </style>
        <script src="markdown/marked.min.js"></script>
        \(katexJS)
        </head>
        <body>
        <div id="c"></div>
        <script>
          function __measure() {
            var el = document.getElementById("c");
            if (!el) return 0;
            var bottom = 0;
            var kids = el.children;
            for (var i = 0; i < kids.length; i++) {
              var n = kids[i];
              var style = window.getComputedStyle ? window.getComputedStyle(n) : null;
              var marginBottom = style ? (parseFloat(style.marginBottom) || 0) : 0;
              bottom = Math.max(bottom, n.offsetTop + n.offsetHeight + marginBottom);
            }
            return Math.ceil(Math.max(bottom, 1)) + 2;
          }
          function __report() {
            var h = __measure();
            if (h > 0 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
              window.webkit.messageHandlers.height.postMessage(h);
            }
            return h;
          }
          function __protectMath(src) {
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
          function __restoreMath(html, map) {
            for (var k = 0; k < map.length; k++) {
              html = html.split(map[k][0]).join(map[k][1]);
            }
            return html;
          }
          window.__connectsMeasure = function() { return __measure(); };
          window.__connectsHasMath = \(includeMath ? "true" : "false");
          window.__connectsRender = function(md) {
            var el = document.getElementById("c");
            if (!el) return 0;
            try {
              if (typeof marked !== "undefined") {
                marked.setOptions({ gfm: true, breaks: true, headerIds: false, mangle: false });
                var packed = __protectMath(md);
                var html = marked.parse(packed.src);
                html = __restoreMath(html, packed.map);
                el.innerHTML = html;
              } else {
                el.textContent = md;
              }
              \(mathRender)
            } catch (e) {
              el.textContent = md;
            }
            __report();
            if (window.requestAnimationFrame) {
              requestAnimationFrame(function(){ __report(); });
            }
            setTimeout(__report, 120);
            return __measure();
          };
          window.__connectsReady = true;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
            window.webkit.messageHandlers.height.postMessage(0);
          }
        </script>
        </body>
        </html>
        """
    }

    /// JS snippet: `window.__connectsRender(<json string>)`
    static func renderJavaScript(content: String) -> String {
        let normalized = normalizeForRender(content)
        return "window.__connectsRender(\(jsonString(normalized)));"
    }

    static func measureJavaScript() -> String {
        "(window.__connectsMeasure ? window.__connectsMeasure() : 0);"
    }

    /// Only math / tables need WKWebView. Code fences use PlainMarkdown (much faster on A7).
    static func needsRichMarkdown(_ content: String) -> Bool {
        // Detect after normalization: historical turns often put TeX in
        // ```latex / ```math fences, which are rewritten to $$...$$ below.
        let normalized = normalizeForRender(content)
        if MathContentDetector.containsMath(normalized) { return true }
        if containsGFMTable(normalized) { return true }
        return false
    }

    /// Detect GFM tables, including fullwidth pipes and messy model output.
    static func containsGFMTable(_ content: String) -> Bool {
        let s = content
            .replacingOccurrences(of: "｜", with: "|")
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = s.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var pipeRun = 0
        for (i, line) in lines.enumerated() {
            let pipes = line.filter { $0 == "|" }.count
            if pipes >= 1 {
                if isTableSeparatorLine(line) { return true }
                if pipes >= 2 { pipeRun += 1 } else { pipeRun = max(pipeRun, 1) }
                if i + 1 < lines.count, isTableSeparatorLine(lines[i + 1]) { return true }
                if pipeRun >= 3 { return true }
            } else if !line.isEmpty {
                pipeRun = 0
            }
        }
        return false
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let t = line.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "｜", with: "|")
        guard t.contains("|"), t.contains("-") else { return false }
        // |---|:---:| or ---|---
        for ch in t {
            if ch != "|" && ch != "-" && ch != ":" { return false }
        }
        return t.contains("-")
    }

    /// Render-time normalize (does not mutate stored conversation text).
    static func normalizeForRender(_ raw: String) -> String {
        var s = normalizeMathDelimiters(raw)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        // Old / CN model fullwidth table punctuation → GFM
        s = s.replacingOccurrences(of: "｜", with: "|")
        s = s.replacingOccurrences(of: "－", with: "-")
        s = s.replacingOccurrences(of: "—", with: "-")
        // Collapse 3+ blank lines left by older plain renderers / copy-paste
        while s.contains("\n\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n\n", with: "\n\n\n")
        }
        return s
    }

    /// Normalize odd model outputs toward KaTeX-friendly delimiters.
    static func normalizeMathDelimiters(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "［", with: "[")
        s = s.replacingOccurrences(of: "］", with: "]")
        if let re = try? NSRegularExpression(
            pattern: "```(?:math|latex|tex)\\s*\\n([\\s\\S]*?)```",
            options: [.caseInsensitive]
        ) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$$$$1$$")
        }
        // Some providers double-escape delimiters while serialising JSON.
        // Keep ordinary backslashes untouched; only normalize actual delimiters.
        s = s.replacingOccurrences(of: "\\\\[", with: "\\[")
        s = s.replacingOccurrences(of: "\\\\]", with: "\\]")
        s = s.replacingOccurrences(of: "\\\\(", with: "\\(")
        s = s.replacingOccurrences(of: "\\\\)", with: "\\)")

        // A few model responses emit a display formula as a bare TeX line
        // (for example "\frac{a}{b}") without any delimiter. Wrap only lines
        // that clearly begin with a math command, so prose is unaffected.
        let lines = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\\"),
                  !trimmed.hasPrefix("\\["),
                  !trimmed.hasPrefix("\\("),
                  !trimmed.hasPrefix("\\begin{"),
                  trimmed.range(
                    of: #"^\\(?:frac|dfrac|tfrac|sum|prod|int|iint|iiint|lim|sqrt|left|right|mathbf|mathbb|mathrm|alpha|beta|gamma|delta|theta|lambda|mu|pi|sigma|phi|psi|omega)\b"#,
                    options: .regularExpression
                  ) != nil else { return line }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return "\(indent)$$\(trimmed)$$"
        }
        s = lines.joined(separator: "\n")
        return s
    }

    /// Legacy full document (unused by MessageCell shell path; kept for tooling).
    static func fullHTML(content: String,
                         textColor: UIColor,
                         backgroundColor: UIColor,
                         secondaryColor: UIColor,
                         fontSize: CGFloat) -> String {
        let shell = shellHTML(
            textColor: textColor,
            backgroundColor: backgroundColor,
            secondaryColor: secondaryColor,
            fontSize: fontSize
        )
        // Inject an immediate render call for one-shot loads.
        let js = renderJavaScript(content: content)
        return shell.replacingOccurrences(
            of: "window.__connectsReady = true;",
            with: "window.__connectsReady = true;\n          \(js)"
        )
    }

    static func jsonString(_ s: String) -> String {
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
