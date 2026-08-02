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
          \(ConnectsWebKit.scrollPerformanceCSS)
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
        let escapedDelimiters = [
            (#"\\{2,}\("#, #"\\("#),
            (#"\\{2,}\)"#, #"\\)"#),
            (#"\\{2,}\["#, #"\\["#),
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
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/>
        <link rel="stylesheet" href="katex/katex.min.css"/>
        <style>
          /* Content defines height; WKWebView.scrollView owns finger scrolling.
             Avoid height:100% + overflow:auto — that often yields a non-scrollable viewport. */
          html, body { margin:0; padding:0; background:\(bg); color:\(fg);
            font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size:\(String(format: "%.1f", fontSize))px; line-height:1.7;
            word-wrap:break-word; overflow-wrap:break-word; -webkit-text-size-adjust:100%; }
          #c { padding:18px 22px 64px; max-width:52em; margin:0 auto; display:flow-root; }
          #c h1,#c h2,#c h3,#c h4 { font-weight:600; line-height:1.3; margin:1em 0 0.4em; }
          #c h1 { font-size:1.45em; } #c h2 { font-size:1.25em; }
          #c h3 { font-size:1.1em; } #c h4 { font-size:1.02em; }
          #c p { margin:0.55em 0; }
          #c ul, #c ol { margin:0.45em 0; padding-left:1.4em; }
          #c li { margin:0.22em 0; }
          #c strong { font-weight:700; }
          #c em { font-style:italic; }
          #c a { color:#4da3ff; }
          #c code { font-family:Menlo, Monaco, monospace; font-size:0.9em;
            background:rgba(127,127,127,0.16); padding:0.12em 0.35em; border-radius:4px; }
          #c pre { background:rgba(127,127,127,0.12); padding:12px 14px; border-radius:10px;
            overflow-x:auto; margin:0.75em 0; -webkit-overflow-scrolling:touch; }
          #c pre code { background:transparent; padding:0; white-space:pre-wrap; word-break:break-word; tab-size:4; }
          #c blockquote { margin:0.65em 0; padding:0.1em 0 0.1em 0.9em;
            border-left:3px solid \(border); color:\(sec); }
          #c table { border-collapse:collapse; width:100%; margin:0.8em 0; font-size:0.95em;
            table-layout:fixed; word-break:break-word; display:block; overflow-x:auto; -webkit-overflow-scrolling:touch; }
          #c th, #c td { border:1px solid \(border); padding:7px 10px; text-align:left; }
          #c th { background:rgba(127,127,127,0.1); font-weight:600; }
          #c hr { border:none; border-top:1px solid \(border); margin:1em 0; }
          #c img { max-width:100%; height:auto; }
          #c a[href^="https://connects.local/"],
          #c a[href^="connects-asset:"],
          #c a[href$=".png"], #c a[href$=".jpg"], #c a[href$=".jpeg"],
          #c a[href$=".gif"], #c a[href$=".webp"], #c a[href$=".svg"] {
            display:inline-block; margin:0.15em 0; padding:0.12em 0.55em;
            border:1px solid \(border); border-radius:6px;
            background:rgba(127,127,127,0.10); text-decoration:none;
            font-size:0.92em; line-height:1.4;
          }
          .katex-display { margin:0.75em 0; overflow-x:auto; overflow-y:hidden; }
          img, video { max-width:100%; height:auto; }
        </style>
        <script src="markdown/marked.min.js"></script>
        <script src="katex/katex.min.js"></script>
        <script src="katex/auto-render.min.js"></script>
        </head>
        <body>
        <div id="c"></div>
        <script>
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
              // Turn leftover <img> into 〔图〕 links (no inline images).
              var imgs = el.querySelectorAll("img");
              for (var ii = 0; ii < imgs.length; ii++) {
                var img = imgs[ii];
                var src = img.getAttribute("src") || "";
                if (!src || src.indexOf("data:") === 0) continue;
                var aImg = document.createElement("a");
                aImg.setAttribute("href", src);
                var label = (img.getAttribute("alt") || "").trim();
                if (!label) {
                  var parts = src.split("/");
                  label = parts[parts.length - 1] || "图";
                }
                aImg.textContent = "〔图〕" + label;
                if (img.parentNode) img.parentNode.replaceChild(aImg, img);
              }
              if (!el.__connectsAssetClickBound) {
                el.__connectsAssetClickBound = true;
                el.addEventListener("click", function(ev) {
                  var node = ev.target;
                  while (node && node !== el && (!node.tagName || node.tagName.toUpperCase() !== "A")) {
                    node = node.parentNode;
                  }
                  if (!node || node === el) return;
                  var href = node.getAttribute("href") || "";
                  function isImageHref(h) {
                    if (!h) return false;
                    if (h.indexOf("https://connects.local/") === 0) return true;
                    if (h.indexOf("http://connects.local/") === 0) return true;
                    if (h.indexOf("connects-asset:") === 0) return true;
                    if (/^https?:\\/\\//i.test(h) && h.indexOf("connects.local") < 0) return false;
                    return /\\.(png|jpe?g|gif|webp|bmp|svg)(\\?.*)?$/i.test(h);
                  }
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
