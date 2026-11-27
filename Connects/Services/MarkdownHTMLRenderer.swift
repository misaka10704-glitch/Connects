import Foundation
import UIKit

/// Finished-message HTML: GFM markdown + KaTeX.
/// Loads a persistent shell once; content is injected via JS (avoids re-parsing katex/marked every cell).
///
/// **Engine policy:** Chat bubbles use Native (`NativeMarkdownParser` /
/// `NativeMessageLayouter`) as the canonical renderer. Study's `studyShellHTML`
/// is a transitional WKWebView shell — do not add Study-only Markdown dialect
/// here; see `.cursor/rules/markdown-render-engine.mdc`. Prefer migrating Study
/// reading onto Native rather than deepening this fork.
enum MarkdownHTMLRenderer {
    static var resourceBaseURL: URL? { Bundle.main.resourceURL }

    /// Page stays width-locked to the viewport; overflowing math scrolls horizontally
    /// inside its own box (vertical scroll inside that box is locked).
    /// Critical: pin widths in *CSS pixels* — otherwise wide KaTeX expands the column
    /// and `overflow-x:auto` never sees an overflow (common at large font sizes).
    private static let mathContainJS = """
          function __connectsContainMath(root) {
            var scope = root || document.getElementById("c") || document.body;
            if (!scope) return;
            var vw = Math.min(
              document.documentElement.clientWidth || 0,
              window.innerWidth || 0
            );
            if (!(vw > 0)) return;
            var vwPx = Math.floor(vw) + "px";

            function lockY(scroller) {
              if (!scroller || scroller.__connectsYLock) return;
              scroller.__connectsYLock = true;
              scroller.addEventListener("scroll", function() {
                if (scroller.scrollTop) scroller.scrollTop = 0;
              }, { passive: true });
            }

            function armScroller(el, avail) {
              if (!el || !(avail > 0)) return;
              var w = Math.floor(avail);
              el.style.boxSizing = "border-box";
              el.style.minWidth = "0";
              el.style.maxWidth = w + "px";
              el.style.width = w + "px";
              el.style.overflowX = "auto";
              el.style.overflowY = "hidden";
              el.style.webkitOverflowScrolling = "touch";
              lockY(el);
            }

            function contentWidthOf(el) {
              if (!el) return 0;
              var pad = 0;
              try {
                var cs = window.getComputedStyle(el);
                pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
              } catch (eW) {}
              return Math.max(0, (el.clientWidth || 0) - pad);
            }

            // Available width for a node: nearest blockquote/td/li/#c, capped by page column.
            function availNear(node) {
              var el = node ? node.parentElement : null;
              while (el && el !== document.documentElement) {
                if (el.classList && (el.classList.contains("connects-math-x")
                    || el.classList.contains("katex-display"))) {
                  el = el.parentElement;
                  continue;
                }
                var tag = (el.tagName || "").toLowerCase();
                if (tag === "blockquote" || tag === "td" || tag === "th"
                    || tag === "li" || el.id === "c") {
                  var w = contentWidthOf(el);
                  if (w > 0) return Math.min(w, col);
                }
                el = el.parentElement;
              }
              return col;
            }

            try {
              document.documentElement.style.width = vwPx;
              document.documentElement.style.maxWidth = vwPx;
              document.documentElement.style.overflowX = "hidden";
              document.body.style.width = vwPx;
              document.body.style.maxWidth = vwPx;
              document.body.style.overflowX = "hidden";
            } catch (e0) {}

            var c = document.getElementById("c");
            var col = vw;
            var padL = 0;
            var padR = 0;
            var cRect = null;
            if (c) {
              var bodyFs = 16;
              try {
                bodyFs = parseFloat(window.getComputedStyle(document.body).fontSize) || 16;
              } catch (e1) {}
              // Match study shell intent: min(52em, viewport), never wider than screen.
              var cap = Math.min(52 * bodyFs, vw);
              c.style.boxSizing = "border-box";
              c.style.maxWidth = Math.floor(cap) + "px";
              c.style.width = "100%";
              c.style.overflowX = "hidden";
              try {
                var cs = window.getComputedStyle(c);
                padL = parseFloat(cs.paddingLeft) || 0;
                padR = parseFloat(cs.paddingRight) || 0;
                cRect = c.getBoundingClientRect();
              } catch (e2) {}
              col = Math.max(1, (c.clientWidth || cap) - padL - padR);
            }

            // Pin blockquotes before measuring math (otherwise they grow with KaTeX).
            var quotes = scope.querySelectorAll("blockquote");
            for (var qi = 0; qi < quotes.length; qi++) {
              var q = quotes[qi];
              q.style.boxSizing = "border-box";
              q.style.maxWidth = "100%";
              q.style.minWidth = "0";
              q.style.width = "auto";
              q.style.overflowX = "auto";
              q.style.overflowY = "hidden";
              lockY(q);
            }

            var edge = 6; // tiny screen gutter when formula bleeds full-width
            var blocks = scope.querySelectorAll(".katex-display");
            for (var i = 0; i < blocks.length; i++) {
              var b = blocks[i];
              var k = b.querySelector(".katex");
              if (k) {
                k.style.maxWidth = "none";
                k.style.width = "auto";
                k.style.display = "";
              }
              // Reset prior bleed so measurement is honest.
              b.style.marginLeft = "";
              b.style.marginRight = "";
              b.style.paddingLeft = "";
              b.style.paddingRight = "";
              b.style.borderRadius = "";
              b.style.textAlign = "";
              b.style.maxWidth = "none";
              b.style.width = "auto";
              b.style.overflow = "visible";
              var localCol = availNear(b);
              var need = k
                ? Math.max(k.scrollWidth || 0, k.offsetWidth || 0)
                : Math.max(b.scrollWidth || 0, b.offsetWidth || 0);
              var inQuote = false;
              var qp = b.parentElement;
              while (qp) {
                if ((qp.tagName || "").toLowerCase() === "blockquote") { inQuote = true; break; }
                qp = qp.parentElement;
              }
              if (need > localCol + 1) {
                if (inQuote) {
                  // Stay inside the quote — do not full-bleed past `>`.
                  armScroller(b, localCol);
                } else {
                  // Overflow: use nearly full viewport — don't leave a fat right gutter.
                  var contentLeft = cRect ? (cRect.left + padL) : padL;
                  var pull = contentLeft - edge;
                  b.style.marginLeft = (-pull) + "px";
                  b.style.marginRight = "0";
                  b.style.paddingLeft = edge + "px";
                  b.style.paddingRight = edge + "px";
                  b.style.borderRadius = "0";
                  b.style.textAlign = "left";
                  armScroller(b, Math.max(1, vw - 2 * edge));
                }
              } else {
                armScroller(b, localCol);
              }
            }

            var existing = scope.querySelectorAll(".connects-math-x");
            for (var e = 0; e < existing.length; e++) {
              armScroller(existing[e], availNear(existing[e]));
            }

            var inlines = scope.querySelectorAll(".katex");
            for (var j = 0; j < inlines.length; j++) {
              var node = inlines[j];
              var p = node.parentElement;
              var inDisplay = false;
              while (p) {
                if (p.classList && p.classList.contains("katex-display")) { inDisplay = true; break; }
                p = p.parentElement;
              }
              if (inDisplay) continue;

              var shell = (node.parentElement && node.parentElement.classList
                && node.parentElement.classList.contains("connects-math-x"))
                ? node.parentElement : null;

              var local = availNear(node);
              // Measure natural formula width (unwrap constraints temporarily).
              var needI = 0;
              if (shell) {
                shell.style.maxWidth = "none";
                shell.style.width = "auto";
                shell.style.overflow = "visible";
              }
              needI = Math.max(node.scrollWidth || 0, node.offsetWidth || 0);
              if (shell) {
                shell.style.overflow = "";
              }

              if (needI > local + 1) {
                if (!shell) {
                  shell = document.createElement("span");
                  shell.className = "connects-math-x";
                  if (node.parentNode) {
                    node.parentNode.insertBefore(shell, node);
                    shell.appendChild(node);
                  }
                }
                armScroller(shell, local);
              } else if (shell) {
                armScroller(shell, local);
              }
            }

            try {
              document.documentElement.scrollLeft = 0;
              document.body.scrollLeft = 0;
              if (window.scrollTo) window.scrollTo(0, window.pageYOffset || 0);
            } catch (e3) {}
          }
          window.__connectsContainMath = __connectsContainMath;
          """

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
        let chrome = readingChromeCSS(compact: true, secondary: sec, border: border)
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
              if (typeof __connectsContainMath === "function") { __connectsContainMath(el); }
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
            height:auto !important; min-height:0 !important; overflow:hidden;
            overflow-x:hidden !important; max-width:100%; width:100%; }
          #c { padding:0; display:flow-root; max-width:100%; overflow-x:hidden; box-sizing:border-box; }
          #c h1,#c h2,#c h3 { font-weight:600; line-height:1.3; margin:0.85em 0 0.35em; }
          #c h1 { font-size:1.35em; } #c h2 { font-size:1.2em; } #c h3 { font-size:1.08em; }
          #c p { margin:0.5em 0; }
          #c ul, #c ol { margin:0.4em 0; padding-left:1.35em; }
          #c li { margin:0.2em 0; }
          \(chrome)
          .katex-display { margin:0.7em 0; max-width:100%; width:100%; box-sizing:border-box;
            min-width:0; overflow-x:auto; overflow-y:hidden; -webkit-overflow-scrolling:touch;
            overscroll-behavior-x:contain; overscroll-behavior-y:none; touch-action:pan-x; }
          .katex-display > .katex { max-width:none; }
          .connects-math-x { display:inline-block; max-width:100%; vertical-align:middle;
            overflow-x:auto; overflow-y:hidden; -webkit-overflow-scrolling:touch;
            overscroll-behavior-x:contain; overscroll-behavior-y:none; touch-action:pan-x; }
          \(ConnectsWebKit.scrollPerformanceCSS)
        </style>
        <script src="markdown/marked.min.js"></script>
        \(katexJS)
        </head>
        <body>
        <div id="c"></div>
        <script>
          \(includeMath ? mathContainJS : "")
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
                // Letter-only tokens: CommonMark treats `@`/`$` as punctuation, so
                // `中文**@@MATH0@@**中文` would NOT become <strong> (same for raw `**$x$**`).
                var key = "zzMDMATH" + (i++) + "zz";
                map.push([key, m]);
                return key;
              });
            }
            stash(/\\$\\$[\\s\\S]+?\\$\\$/g);
            stash(/\\\\\\[[\\s\\S]+?\\\\\\]/g);
            stash(/\\\\\\([\\s\\S]+?\\\\\\)/g);
            stash(/\\$((?:\\\\.|[^$\\n])+)\\$/g);
            stash(/\\\\begin\\{[a-zA-Z*]+\\}[\\s\\S]+?\\\\end\\{[a-zA-Z*]+\\}/g);
            return { src: src, map: map };
          }
          function __restoreMath(html, map) {
            for (var k = 0; k < map.length; k++) {
              var math = String(map[k][1])
                .replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;");
              html = html.split(map[k][0]).join(math);
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

    /// Live font-size update for Study / markdown preview shells (pinch / ⌘±).
    static func setFontSizeJavaScript(_ fontSize: CGFloat) -> String {
        let px = String(format: "%.1f", fontSize)
        return "window.__connectsSetFontSize && window.__connectsSetFontSize(\(px));"
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
    /// WK Study / preview path: bold-wrapped math becomes `<strong>$…$</strong>` so KaTeX
    /// inherits Everforest green on `\int`, `\sum`, `\frac`, not only `\boldsymbol` atoms.
    static func normalizeForRender(_ raw: String) -> String {
        normalizeShared(raw, emphasisStyle: .htmlStrong)
    }

    /// Native chat path: keep `\boldsymbol{…}` (iosMath has no `<strong>` pass).
    static func normalizeForNative(_ raw: String) -> String {
        normalizeShared(raw, emphasisStyle: .boldsymbol)
    }

    private enum EmphasisMathStyle {
        case htmlStrong
        case boldsymbol
    }

    private static func normalizeShared(_ raw: String, emphasisStyle: EmphasisMathStyle) -> String {
        var s = normalizeMathDelimiters(raw)
        s = normalizeEmphasisWrappedMath(s, style: emphasisStyle)
        s = normalizeCJKBold(s, style: emphasisStyle)
        s = normalizeMathTypos(s)
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

    /// Inline `$…$` body: escaped token or any char except `$` / newline.
    /// Must be a regular string so `\\n` is a newline in the regex (raw `[^$\\n]` excludes the letter `n`).
    private static let inlineMathBody = "(?:\\\\.|[^$\\n])+"

    /// Replace group 1 without NSRegularExpression `$` templates (`$$` vs `$1` eats math).
    private static func replaceCaptured(
        _ source: String,
        pattern: String,
        with transform: (String) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return source }
        let ns = source as NSString
        let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var result = source
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  match.range(at: 1).location != NSNotFound,
                  let full = Range(match.range, in: result),
                  let body = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(full, with: transform(String(result[body])))
        }
        return result
    }

    /// CommonMark treats `**` next to `（` as non-flanking.
    /// WK: emit `<strong>` directly. Native: ZWSP so iosMath/markdown still sees `**`.
    private static func normalizeCJKBold(_ raw: String, style: EmphasisMathStyle) -> String {
        switch style {
        case .htmlStrong:
            return replaceCaptured(
                raw,
                pattern: #"\*\*([（【「『《〈\(][\s\S]*?[）】」』》〉\)])\*\*"#
            ) { "<strong>\($0)</strong>" }
        case .boldsymbol:
            let zwsp = "\u{200B}"
            var s = raw
            let openAfterStars = "（【「『《〈("
            let closeBeforeStars = "）】」』》〉)"
            for ch in openAfterStars {
                s = s.replacingOccurrences(of: "**\(ch)", with: "**\(zwsp)\(ch)")
            }
            for ch in closeBeforeStars {
                s = s.replacingOccurrences(of: "\(ch)**", with: "\(ch)\(zwsp)**")
            }
            return s
        }
    }

    /// Model typos + CJK prose inside math so KaTeX does not abort mid-formula.
    private static func normalizeMathTypos(_ source: String) -> String {
        var result = source
        let spanPatterns = [
            #"(?s)\\\((.*?)\\\)"#,
            #"(?s)\\\[(.*?)\\\]"#,
            #"(?s)\$\$(.*?)\$\$"#,
            "(?s)(?<!\\$)\\$(?!\\$)(" + inlineMathBody + "?)(?<!\\$)\\$(?!\\$)"
        ]
        for pattern in spanPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(location: 0, length: (result as NSString).length)
            let matches = regex.matches(in: result, options: [], range: fullRange)
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else { continue }
                let ns = result as NSString
                let bodyRange = match.range(at: 1)
                let original = ns.substring(with: bodyRange)
                let body = sanitizeMathBody(original)
                if body != original {
                    result = ns.replacingCharacters(in: bodyRange, with: body)
                }
            }
        }
        return result
    }

    private static func sanitizeMathBody(_ raw: String) -> String {
        var body = raw
        if let infin = try? NSRegularExpression(pattern: #"\\infin(?!\w)"#) {
            let nsBody = body as NSString
            let matches = infin.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: body) else { continue }
                body.replaceSubrange(range, with: "\\infty")
            }
        }
        return wrapCJKAsText(body)
    }

    /// `\quad其中c_k` → `\quad\text{其中}c_k` so KaTeX does not fail on Han inside math.
    private static func wrapCJKAsText(_ body: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\\text\{[^}]*\}|[\p{Han}]+"#) else {
            return body
        }
        let ns = body as NSString
        let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var result = body
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let piece = String(result[range])
            if piece.hasPrefix("\\text{") { continue }
            result.replaceSubrange(range, with: "\\text{\(piece)}")
        }
        return result
    }

    /// Typora-style bold/italic around a lone math span: `**$x$**`, `*$x$*`, `**\(x\)**`.
    /// CommonMark treats `$` as punctuation, so `中文**$x$**中文` never becomes <strong>;
    /// WK preview wraps `<strong>$…$</strong>`; Native keeps `\boldsymbol{…}` for iosMath.
    private static func normalizeEmphasisWrappedMath(_ raw: String, style: EmphasisMathStyle) -> String {
        var s = raw
        let body = inlineMathBody
        let specs: [(pattern: String, wrap: (String) -> String)]
        switch style {
        case .htmlStrong:
            specs = [
                (#"(?s)\*\*\$\$(.+?)\$\$\*\*"#, { "<strong>$$\($0)$$</strong>" }),
                (#"(?s)\*\$\$(.+?)\$\$\*"#, { "<strong>$$\($0)$$</strong>" }),
                (#"\*\*\\\((.+?)\\\)\*\*"#, { "<strong>\\(\($0)\\)</strong>" }),
                (#"\*\\\((.+?)\\\)\*"#, { "<em>\\(\($0)\\)</em>" }),
                ("\\*\\*\\$(" + body + ")\\$\\*\\*", { "<strong>$\($0)$</strong>" }),
                ("\\*\\$(" + body + ")\\$\\*", { "<em>$\($0)$</em>" })
            ]
        case .boldsymbol:
            specs = [
                (#"(?s)\*\*\$\$(.+?)\$\$\*\*"#, { "$$\\boldsymbol{\($0)}$$" }),
                (#"(?s)\*\$\$(.+?)\$\$\*"#, { "$$\\boldsymbol{\($0)}$$" }),
                (#"\*\*\\\((.+?)\\\)\*\*"#, { "\\(\\boldsymbol{\($0)}\\)" }),
                (#"\*\\\((.+?)\\\)\*"#, { "\\(\\boldsymbol{\($0)}\\)" }),
                ("\\*\\*\\$(" + body + ")\\$\\*\\*", { "$\\boldsymbol{\($0)}$" }),
                ("\\*\\$(" + body + ")\\$\\*", { "$\\boldsymbol{\($0)}$" })
            ]
        }
        for spec in specs {
            s = replaceCaptured(s, pattern: spec.pattern, with: spec.wrap)
        }
        return s
    }

    /// Normalize odd model outputs toward KaTeX-friendly delimiters.
    static func normalizeMathDelimiters(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "［", with: "[")
        s = s.replacingOccurrences(of: "］", with: "]")
        s = s.replacingOccurrences(of: "＄", with: "$")
        s = convertFencedMathBlocks(s)
        s = s.replacingOccurrences(of: "\\（", with: "\\(")
        s = s.replacingOccurrences(of: "\\）", with: "\\)")
        // Other chat providers use BBCode/XML-style math wrappers.
        let wrapperPatterns = [
            #"(?is)\[(?:math|latex|tex)\](.*?)\[/(?:math|latex|tex)\]"#,
            #"(?is)<math(?:\s[^>]*)?>(.*?)</math>"#
        ]
        for pattern in wrapperPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = re.stringByReplacingMatches(
                in: s,
                options: [],
                range: range,
                withTemplate: #"\$\$$1\$\$"#
            )
        }
        // Some providers double-escape delimiters while serialising JSON.
        // Keep ordinary backslashes untouched; only normalize actual delimiters.
        // `\\[<dimen>]` is never a delimiter — it is the TeX row-break-with-spacing
        // syntax (`\end{vmatrix}\\[2mm]` inside aligned). Collapsing it to `\[`
        // destroys the formula, so a leading digit/dot/sign vetoes the rewrite.
        let escapedDelimiters = [
            (#"\\{2,}\("#, #"\\("#),
            (#"\\{2,}\)"#, #"\\)"#),
            (#"\\{2,}\[(?![\d.+-])"#, #"\\["#),
            (#"\\{2,}\]"#, #"\\]"#),
            (#"\\{2,}begin\{"#, #"\\begin{"#),
            (#"\\{2,}end\{"#, #"\\end{"#)
        ]
        for (pattern, template) in escapedDelimiters {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = re.stringByReplacingMatches(
                in: s,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        s = decodeDoubleEscapedCommandsInsideMath(s)

        // A few model responses emit a display formula as a bare TeX line
        // (for example "\frac{a}{b}") without any delimiter. Wrap only lines
        // that clearly begin with a math command, so prose is unaffected.
        // Never wrap lines that already sit inside `$$` / `\[...\]` fences —
        // re-wrapping produces `$$\n$$\frac..\n$$` and the parser then sees an
        // empty display-math block plus a stray closing `$$`.
        let lines = s.components(separatedBy: "\n")
        var normalizedLines = [String]()
        var index = 0
        var displayFence: DisplayMathFence? = nil
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = displayFence {
                normalizedLines.append(line)
                if closesDisplayFence(trimmed, fence: fence) {
                    displayFence = nil
                }
                index += 1
                continue
            }

            if trimmed == "$$" {
                normalizedLines.append(line)
                displayFence = .dollars
                index += 1
                continue
            }
            if trimmed.hasPrefix("$$") {
                normalizedLines.append(line)
                // `$$...$$` on one line is a complete fence (even delimiter count).
                // `$$\frac{a}{b}` without a closer keeps the fence open.
                let delimiterCount = trimmed.components(separatedBy: "$$").count - 1
                if delimiterCount % 2 == 1 {
                    displayFence = .dollars
                }
                index += 1
                continue
            }
            if trimmed == "\\[" || (trimmed.hasPrefix("\\[") && !trimmed.contains("\\]")) {
                normalizedLines.append(line)
                displayFence = .brackets
                index += 1
                continue
            }
            if trimmed.hasPrefix("\\[") {
                normalizedLines.append(line)
                index += 1
                continue
            }
            // `\begin{equation}`-style environments are fences too: without this
            // the body line matches the bare-formula wrap and the document ends up
            // with the hybrid `\begin{equation}\n$$…$$\n\end{equation}`.
            if let env = mathEnvironmentOpener(trimmed) {
                normalizedLines.append(line)
                if !trimmed.contains("\\end{\(env)}") {
                    displayFence = .environment(env)
                }
                index += 1
                continue
            }

            guard isBareDisplayMathStart(trimmed) else {
                normalizedLines.append(line)
                index += 1
                continue
            }

            // Gateways sometimes emit a multi-line derivation without `$$`.
            // Treat adjacent equation-continuation lines as one display block;
            // otherwise each line is parsed as prose and visibly misaligned.
            var formulaLines = [trimmed]
            var next = index + 1
            while next < lines.count {
                let continuation = lines[next].trimmingCharacters(in: .whitespaces)
                guard isBareDisplayMathContinuation(continuation) else { break }
                formulaLines.append(continuation)
                next += 1
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            normalizedLines.append("\(indent)$$\(formulaLines.joined(separator: "\n"))$$")
            index = next
        }
        s = normalizedLines.joined(separator: "\n")
        return s
    }

    private enum DisplayMathFence {
        case dollars
        case brackets
        case environment(String)
    }

    /// `\begin{aligned}` at line start opens a math environment fence. Only
    /// math-layout environments count — `\begin{itemize}` in pasted LaTeX
    /// documents must not swallow following prose.
    private static func mathEnvironmentOpener(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("\\begin{") else { return nil }
        let envs = [
            "equation*", "equation", "gather*", "gather", "align*", "align",
            "alignat*", "alignat", "multline*", "multline", "eqnarray*", "eqnarray",
            "displaymath", "subequations", "flalign*", "flalign",
            "aligned", "gathered", "alignedat", "split",
            "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix", "cases"
        ]
        for env in envs {
            if trimmed.hasPrefix("\\begin{\(env)}") { return env }
        }
        return nil
    }

    private static func closesDisplayFence(_ trimmed: String, fence: DisplayMathFence) -> Bool {
        switch fence {
        case .dollars:
            if trimmed == "$$" { return true }
            // Formula line that terminates the block: `x = 1$$`
            if trimmed.hasSuffix("$$"), trimmed != "$$" { return true }
            return false
        case .brackets:
            return trimmed == "\\]" || trimmed.hasSuffix("\\]")
        case .environment(let env):
            return trimmed.contains("\\end{\(env)}")
        }
    }

    /// Only short math snippets become display math; full LaTeX documents stay fenced code.
    private static func convertFencedMathBlocks(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "```(?:math|latex|tex|katex|formula|equation)(?:[ \\t]*\\n|[ \\t]+)([\\s\\S]*?)```",
            options: [.caseInsensitive]
        ) else { return source }
        let ns = source as NSString
        var result = source
        let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let fullRange = match.range(at: 0)
            let body = ns.substring(with: match.range(at: 1))
            let replacement: String
            if shouldTreatFencedBodyAsDisplayMath(body) {
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                replacement = "$$\(trimmedBody)$$"
            } else {
                replacement = ns.substring(with: fullRange)
            }
            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
        }
        return result
    }

    private static func shouldTreatFencedBodyAsDisplayMath(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 700 { return false }
        if trimmed.components(separatedBy: "\n").count > 14 { return false }
        let lower = trimmed.lowercased()
        let documentMarkers = [
            "\\documentclass", "\\usepackage", "\\begin{document}", "\\end{document}",
            "\\begin{lilypond}", "\\begin{verse}", "\\begin{chorus}", "\\begin{song}",
            "\\newcommand", "\\chord{", "\\writechord", "\\lyluatex", "\\leadsheets",
            "\\harmony", "\\lynote", "lilypond"
        ]
        if documentMarkers.contains(where: { lower.contains($0) }) { return false }
        return true
    }

    private static func isBareDisplayMathStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("%") { return false }
        let lower = trimmed.lowercased()
        let excludedPrefixes = [
            "\\documentclass", "\\usepackage", "\\begin{", "\\end{",
            "\\newcommand", "\\chord", "\\writechord", "\\lyluatex",
            "\\mathrm{documentclass", "\\mathrm{article}", "\\mathrm{harmony}"
        ]
        if excludedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        guard trimmed.hasPrefix("\\"),
              !trimmed.hasPrefix("\\["),
              !trimmed.hasPrefix("\\("),
              !trimmed.hasPrefix("\\begin{"),
              trimmed.range(
                of: #"^\\(?:boxed|displaystyle|frac|dfrac|tfrac|sum|prod|int|iint|iiint|lim|sqrt|left|operatorname)\b"#,
                options: .regularExpression
              ) != nil else {
            return false
        }
        return trimmed.filter { $0 == "{" }.count == trimmed.filter { $0 == "}" }.count
    }

    private static func isBareDisplayMathContinuation(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.hasPrefix("=") || line.hasPrefix("+") || line.hasPrefix("-")
    }

    /// A few OpenAI-compatible gateways return already JSON-decoded text that
    /// still contains JSON-level escaping, for example:
    /// `\\(y=\\int x\\,dt\\)`. Decode one escaping layer only inside a known
    /// math span. The command check preserves legitimate `\\` row separators
    /// in matrices whose other TeX commands are already normally escaped.
    private static func decodeDoubleEscapedCommandsInsideMath(_ source: String) -> String {
        var result = source
        let spanPatterns = [
            #"(?s)\\\((.*?)\\\)"#,
            #"(?s)\\\[(.*?)\\\]"#,
            #"(?s)\$\$(.*?)\$\$"#,
            #"(?s)\\begin\{([A-Za-z*]+)\}(.*?)\\end\{\1\}"#,
            #"(?s)(?<!\\)(?<!\$)\$(?!\$)(.+?)(?<!\\)\$(?!\$)"#
        ]
        for pattern in spanPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(location: 0, length: (result as NSString).length)
            let matches = regex.matches(in: result, options: [], range: fullRange)
            for match in matches.reversed() {
                let bodyIndex = pattern.contains(#"begin\{"#) ? 2 : 1
                guard match.numberOfRanges > bodyIndex,
                      match.range(at: bodyIndex).location != NSNotFound else { continue }
                let ns = result as NSString
                let bodyRange = match.range(at: bodyIndex)
                let body = ns.substring(with: bodyRange)
                guard containsDoubleEscapedCommand(body) else { continue }
                let decoded = body.replacingOccurrences(of: "\\\\", with: "\\")
                result = ns.replacingCharacters(in: bodyRange, with: decoded)
            }
        }
        return result
    }

    private static func containsDoubleEscapedCommand(_ source: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            // A single letter after `\\` is commonly the first cell of the
            // next matrix row (`a&b\\c&d`), not a double-escaped command.
            // Requiring a multi-letter command preserves TeX row separators
            // while still repairing JSON-escaped commands such as `\\frac`.
            pattern: #"\\\\(?:[A-Za-z]{2,}|[,;:!])"#
        ) else { return false }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return regex.firstMatch(in: source, options: [], range: range) != nil
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

    /// Scrollable study-reader shell (GFM + KaTeX). Same marked/katex assets as chat.
    static func studyShellHTML(textColor: UIColor,
                               backgroundColor: UIColor,
                               secondaryColor: UIColor,
                               fontSize: CGFloat = 17) -> String {
        let fg = cssColor(textColor)
        let bg = cssColor(backgroundColor)
        let sec = cssColor(secondaryColor)
        let border = cssColor(textColor.withAlphaComponent(0.16))
        let chrome = readingChromeCSS(compact: false, secondary: sec, border: border)
        let headingRule = cssColor(DSTheme.c.mdHeadingRule)
        let markFill = cssColor(DSTheme.c.mdMarkFill)
        let mdLink = cssColor(DSTheme.c.mdLinkFg)
        let mathPanel = cssColor(DSTheme.c.mdMathDisplayFill)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/>
        <link rel="stylesheet" href="katex/katex.min.css"/>
        <style>
          /* Content defines height; WKWebView.scrollView owns finger scrolling.
             Avoid height:100% + overflow:auto — that often yields a non-scrollable viewport.
             Reading chrome: Everforest Dark (Typora). Page background stays Connects default. */
          html, body { margin:0; padding:0; background:\(bg); color:\(fg);
            font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size:\(String(format: "%.1f", fontSize))px; line-height:1.75;
            word-wrap:break-word; overflow-wrap:break-word; -webkit-text-size-adjust:100%;
            -webkit-font-smoothing:antialiased;
            overflow-x:hidden !important; max-width:100%; width:100%; }
          #c { padding:20px 24px 72px; max-width:min(52em, 100vw); width:100%;
            margin:0 auto; display:flow-root; box-sizing:border-box; overflow-x:hidden; }
          #c h1,#c h2,#c h3,#c h4,#c h5,#c h6 {
            font-weight:600; line-height:1.28; margin:1.15em 0 0.45em; letter-spacing:-0.01em;
          }
          #c h1 { font-size:1.55em; padding-bottom:0.28em;
            border-bottom:1px solid \(headingRule); }
          #c h2 { font-size:1.32em; padding-bottom:0.22em;
            border-bottom:1px solid \(headingRule); }
          #c h3 { font-size:1.14em; color:\(fg); }
          #c h4 { font-size:1.05em; } #c h5,#c h6 { font-size:1em; opacity:0.92; }
          #c h1:first-child, #c h2:first-child { margin-top:0.15em; }
          #c p { margin:0.6em 0; }
          #c ul, #c ol { margin:0.5em 0; padding-left:1.45em; }
          #c li { margin:0.28em 0; }
          #c li > p { margin:0.25em 0; }
          #c em { font-style:italic; }
          #c del { color:\(sec); text-decoration:line-through; }
          #c mark { background:\(markFill); color:inherit; padding:0.05em 0.2em; border-radius:3px; }
          #c kbd { font-family:Menlo, Monaco, monospace; font-size:0.85em;
            padding:0.1em 0.4em; border-radius:5px; border:1px solid \(border);
            background:rgba(127,127,127,0.10); box-shadow:inset 0 -1px 0 rgba(0,0,0,0.08); }
          #c input[type="checkbox"] { accent-color:\(mdLink); margin-right:0.35em; }
          \(chrome)
          #c img { max-width:100%; height:auto; border-radius:8px; margin:0.55em 0; display:block; }
          #c a[href^="https://connects.local/"],
          #c a[href^="connects-asset:"],
          #c a[href$=".png"], #c a[href$=".jpg"], #c a[href$=".jpeg"],
          #c a[href$=".gif"], #c a[href$=".webp"], #c a[href$=".svg"] {
            display:inline-block; margin:0.15em 0; padding:0.14em 0.6em;
            border:1px solid \(border); border-radius:8px;
            background:rgba(127,127,127,0.08); text-decoration:none;
            font-size:0.92em; line-height:1.4; color:\(mdLink);
          }
          .katex-display { margin:0.85em 0; padding:0.55em 0.75em; border-radius:10px;
            background:\(mathPanel); max-width:100%; width:100%; box-sizing:border-box;
            min-width:0; overflow-x:auto; overflow-y:hidden; -webkit-overflow-scrolling:touch;
            overscroll-behavior-x:contain; overscroll-behavior-y:none; touch-action:pan-x; }
          .katex-display > .katex { max-width:none; }
          .connects-math-x { display:inline-block; max-width:100%; vertical-align:middle;
            overflow-x:auto; overflow-y:hidden; -webkit-overflow-scrolling:touch;
            overscroll-behavior-x:contain; overscroll-behavior-y:none; touch-action:pan-x; }
          ::selection { background:\(mdLink); color:\(bg); }
          img, video { max-width:100%; height:auto; }
        </style>
        <script src="markdown/marked.min.js"></script>
        <script src="katex/katex.min.js"></script>
        <script src="katex/auto-render.min.js"></script>
        </head>
        <body>
        <div id="c"></div>
        <script>
          \(mathContainJS)
          function __protectMath(src) {
            var map = [];
            var i = 0;
            function stash(re) {
              src = src.replace(re, function(m) {
                // Letter-only tokens: CommonMark treats `@`/`$` as punctuation, so
                // `中文**@@MATH0@@**中文` would NOT become <strong> (same for raw `**$x$**`).
                var key = "zzMDMATH" + (i++) + "zz";
                map.push([key, m]);
                return key;
              });
            }
            stash(/\\$\\$[\\s\\S]+?\\$\\$/g);
            stash(/\\\\\\[[\\s\\S]+?\\\\\\]/g);
            stash(/\\\\\\([\\s\\S]+?\\\\\\)/g);
            stash(/\\$((?:\\\\.|[^$\\n])+)\\$/g);
            stash(/\\\\begin\\{[a-zA-Z*]+\\}[\\s\\S]+?\\\\end\\{[a-zA-Z*]+\\}/g);
            return { src: src, map: map };
          }
          function __restoreMath(html, map) {
            for (var k = 0; k < map.length; k++) {
              var math = String(map[k][1])
                .replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;");
              html = html.split(map[k][0]).join(math);
            }
            return html;
          }
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
            var pad = 0;
            try {
              var cs = window.getComputedStyle(el);
              pad = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
            } catch (e0) {}
            return Math.ceil(Math.max(bottom + pad, el.scrollHeight || 0, 1));
          }
          window.__connectsMeasure = function() { return __measure(); };
          window.__connectsRender = function(md) {
            var el = document.getElementById("c");
            if (!el) return;
            try {
              if (typeof marked !== "undefined") {
                marked.setOptions({ gfm: true, breaks: true, headerIds: true, mangle: false });
                var packed = __protectMath(md);
                var html = marked.parse(packed.src);
                html = __restoreMath(html, packed.map);
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
              if (typeof __connectsContainMath === "function") { __connectsContainMath(el); }
              function isImageHref(h) {
                if (!h) return false;
                if (h.indexOf("connects-mdasset:") === 0) return true;
                if (h.indexOf("https://connects.local/") === 0) return true;
                if (h.indexOf("http://connects.local/") === 0) return true;
                if (h.indexOf("connects-asset:") === 0) return true;
                if (h.indexOf("data:") === 0) return true;
                if (/^https?:\\/\\//i.test(h) && h.indexOf("connects.local") < 0) return false;
                return /\\.(png|jpe?g|gif|webp|bmp|svg)(\\?.*)?$/i.test(h);
              }
              if (!el.__connectsAssetClickBound) {
                el.__connectsAssetClickBound = true;
                el.addEventListener("click", function(ev) {
                  var node = ev.target;
                  if (node && node.tagName && node.tagName.toUpperCase() === "IMG") {
                    var src = node.getAttribute("src") || "";
                    if (!isImageHref(src)) return;
                    ev.preventDefault();
                    ev.stopPropagation();
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.studyAsset) {
                      window.webkit.messageHandlers.studyAsset.postMessage(String(src));
                    }
                    return;
                  }
                  while (node && node !== el && (!node.tagName || node.tagName.toUpperCase() !== "A")) {
                    node = node.parentNode;
                  }
                  if (!node || node === el) return;
                  var href = node.getAttribute("href") || "";
                  if (!isImageHref(href)) return;
                  ev.preventDefault();
                  ev.stopPropagation();
                  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.studyAsset) {
                    window.webkit.messageHandlers.studyAsset.postMessage(String(href));
                  }
                }, false);
              }
            } catch (e) {
              el.textContent = md;
            }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.studyReady) {
              requestAnimationFrame(function() {
                requestAnimationFrame(function() {
                  try { void el.offsetHeight; } catch (e2) {}
                  if (typeof __connectsContainMath === "function") { __connectsContainMath(el); }
                  window.webkit.messageHandlers.studyReady.postMessage(1);
                });
              });
            }
          };
          window.__connectsVisibleText = function(maxLen) {
            maxLen = maxLen || 4000;
            var el = document.getElementById("c");
            if (!el) return "";
            var text = (el.innerText || el.textContent || "").replace(/\\s+/g, " ").trim();
            if (text.length <= maxLen) return text;
            var start = Math.max(0, Math.floor(text.length * 0.5) - Math.floor(maxLen * 0.2));
            return text.substring(start, start + maxLen);
          };
          window.__connectsHeadingOutline = function() {
            var el = document.getElementById("c");
            if (!el) return "[]";
            var nodes = el.querySelectorAll("h1,h2,h3,h4");
            var out = [];
            for (var i = 0; i < nodes.length; i++) {
              var n = nodes[i];
              if (!n.id) n.id = "mdh-" + i;
              out.push({
                id: String(n.id),
                title: String((n.textContent || "").replace(/\\s+/g, " ").trim()),
                level: parseInt(String(n.tagName).substring(1), 10) || 1
              });
            }
            return JSON.stringify(out);
          };
          // Scroll heading into view inside the WKWebView document scroller.
          window.__connectsScrollToHeading = function(id) {
            var el = document.getElementById(id);
            if (!el) return false;
            el.scrollIntoView(true);
            return true;
          };
          // Text under the viewport top (Markdown edit ↔ preview pin).
          window.__connectsTopViewportSnippet = function(maxLen) {
            maxLen = maxLen || 80;
            var x = Math.max(12, Math.floor((window.innerWidth || 0) * 0.5));
            var y = 10;
            var text = "";
            try {
              if (document.caretRangeFromPoint) {
                var r = document.caretRangeFromPoint(x, y);
                if (r && r.startContainer) {
                  var node = r.startContainer;
                  if (node.nodeType === 3) {
                    var full = String(node.nodeValue || "");
                    var start = Math.max(0, r.startOffset || 0);
                    var lineStart = full.lastIndexOf("\\n", Math.max(0, start - 1)) + 1;
                    text = full.substring(lineStart).replace(/^\\s+/, "");
                  } else if (node.nodeType === 1) {
                    text = String(node.innerText || node.textContent || "").replace(/\\s+/g, " ").trim();
                  }
                }
              }
            } catch (e0) {}
            if (!text) {
              var hit = document.elementFromPoint(x, y);
              var root = document.getElementById("c");
              while (hit && root && !root.contains(hit)) hit = hit.parentElement;
              if (hit) text = String(hit.innerText || hit.textContent || "").replace(/\\s+/g, " ").trim();
            }
            if (text.length > maxLen) text = text.substring(0, maxLen);
            return text;
          };
          // Pin a rendered text match to the top of the viewport.
          window.__connectsScrollSnippetToTop = function(snippet) {
            if (!snippet) return false;
            var root = document.getElementById("c") || document.body;
            if (!root) return false;
            var needles = [String(snippet)];
            if (snippet.length > 24) needles.push(snippet.substring(0, 24));
            if (snippet.length > 12) needles.push(snippet.substring(0, 12));
            function scrollRangeToTop(range) {
              var rect = range.getBoundingClientRect();
              var absoluteTop = rect.top + (window.pageYOffset || document.documentElement.scrollTop || 0);
              if (window.scrollTo) window.scrollTo(0, Math.max(0, absoluteTop - 2));
              return true;
            }
            for (var n = 0; n < needles.length; n++) {
              var needle = needles[n];
              if (!needle || needle.length < 2) continue;
              var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
              var node;
              while ((node = walker.nextNode())) {
                var value = String(node.nodeValue || "");
                var idx = value.indexOf(needle);
                if (idx < 0) idx = value.toLowerCase().indexOf(needle.toLowerCase());
                if (idx < 0) continue;
                try {
                  var range = document.createRange();
                  range.setStart(node, idx);
                  range.setEnd(node, Math.min(idx + Math.max(1, Math.min(8, needle.length)), value.length));
                  return scrollRangeToTop(range);
                } catch (e1) {}
              }
            }
            return false;
          };
          window.__connectsSetFontSize = function(px) {
            var n = Number(px);
            if (!(n > 0)) return false;
            document.documentElement.style.fontSize = n + "px";
            document.body.style.fontSize = n + "px";
            var el = document.getElementById("c");
            function refit() {
              if (typeof __connectsContainMath === "function") { __connectsContainMath(el); }
            }
            refit();
            requestAnimationFrame(function(){
              refit();
              requestAnimationFrame(refit);
            });
            setTimeout(refit, 60);
            return true;
          };
          window.__connectsReady = true;
        </script>
        </body>
        </html>
        """
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

    /// Shared Typora-like chrome for chat shell + Study preview (same tokens as Native).
    private static func readingChromeCSS(compact: Bool, secondary: String, border: String) -> String {
        let c = DSTheme.c
        let link = cssColor(c.mdLinkFg)
        let codeBg = cssColor(c.mdInlineCodeFill)
        let codeFg = cssColor(c.mdInlineCodeFg)
        let preBg = cssColor(c.mdCodeBlockFill)
        let preBorder = cssColor(c.mdCodeBlockBorder)
        let quoteBg = cssColor(c.mdQuoteFill)
        let quoteBar = cssColor(c.mdQuoteBar)
        let thBg = cssColor(c.mdTableHeaderFill)
        let stripe = cssColor(c.mdTableStripeFill)
        let hrColor = cssColor(c.mdHeadingRule)
        let boldFg = cssColor(c.mdBoldFg)
        let prePad = compact ? "10px 12px" : "14px 16px"
        let quotePad = compact ? "0.35em 0.75em 0.35em 0.85em" : "0.55em 0.9em 0.55em 1em"
        let preRadius = compact ? "8px" : "10px"
        let quoteRadius = compact ? "0 6px 6px 0" : "0 8px 8px 0"
        let preWrap = compact ? "" : "white-space:pre-wrap; word-break:break-word; tab-size:4;"
        let tableLayout = compact ? "" : "table-layout:fixed; word-break:break-word;"
        return """
          #c a { color:\(link); text-decoration:none; border-bottom:1px solid transparent; }
          #c a:hover { border-bottom-color:\(link); }
          #c code { font-family:Menlo, Monaco, "SF Mono", monospace; font-size:0.88em;
            color:\(codeFg); background:\(codeBg); padding:0.12em 0.38em; border-radius:5px; }
          #c pre { background:\(preBg); border:1px solid \(preBorder); padding:\(prePad);
            border-radius:\(preRadius); overflow-x:auto; margin:0.8em 0;
            -webkit-overflow-scrolling:touch; }
          #c pre code { background:transparent; color:inherit; padding:0; \(preWrap) }
          #c blockquote { margin:0.75em 0; padding:\(quotePad);
            border-left:4px solid \(quoteBar); background:\(quoteBg);
            border-radius:\(quoteRadius); color:\(secondary);
            max-width:100%; box-sizing:border-box; min-width:0;
            overflow-x:auto; overflow-y:hidden; -webkit-overflow-scrolling:touch; }
          #c blockquote > :first-child { margin-top:0; }
          #c blockquote > :last-child { margin-bottom:0; }
          #c blockquote p, #c li > p { max-width:100%; min-width:0; overflow-wrap:anywhere; }
          #c table { border-collapse:collapse; width:100%; margin:0.85em 0; font-size:0.95em;
            \(tableLayout) display:block; overflow-x:auto; -webkit-overflow-scrolling:touch;
            border-radius:8px; }
          #c th, #c td { border:1px solid \(border); padding:8px 11px; text-align:left; }
          #c th { background:\(thBg); font-weight:600; color:inherit; }
          #c tr:nth-child(even) td { background:\(stripe); }
          #c hr { border:none; height:0; border-top:1px solid \(hrColor); margin:1.15em 0; }
          #c strong, #c b { color:\(boldFg); font-weight:650; }
          #c strong .katex, #c b .katex { color:\(boldFg); }
          #c strong .katex *, #c b .katex * { color:inherit; }
          #c .katex .mathbf, #c .katex .boldsymbol, #c .katex .bm { color:\(boldFg); }
        """
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
