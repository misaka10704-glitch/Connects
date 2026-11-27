import UIKit

final class NativeFormulaRenderer {
    static let shared = NativeFormulaRenderer()
    private static let metadataKey = "connects_native_formula_meta_v6"

    /// Bumped every time a KaTeX bitmap replaces an iosMath preview. Layout and
    /// render-view keys fold this in: cache keys are content/style identity, so
    /// without the generation a post-KaTeX rebuild has the same key as the stale
    /// preview bitmap and NativeMessageRenderView refuses to repaint it.
    /// Guarded because layout prewarm may read it from a background queue.
    private static let artifactGenerationLock = NSLock()
    private static var artifactGenerationValue = 0
    static var artifactGeneration: Int {
        artifactGenerationLock.lock()
        defer { artifactGenerationLock.unlock() }
        return artifactGenerationValue
    }

    private static func advanceArtifactGeneration() {
        artifactGenerationLock.lock()
        artifactGenerationValue += 1
        artifactGenerationLock.unlock()
    }

    /// Never shrink a formula below this fraction of its requested font size.
    /// Display math may shrink harder (a scroll band is the last resort);
    /// inline math stops higher because bitmaps cannot wrap to the next line.
    static let displayShrinkFloor: CGFloat = 0.55
    static let inlineShrinkFloor: CGFloat = 0.7

    /// Candidate font-size factors for shrink-to-fit, descending, never below `floor`.
    static func shrinkFactors(floor: CGFloat) -> [CGFloat] {
        var factors = [0.85, 0.75, 0.65, 0.55].filter { $0 >= floor - 0.001 }
        if factors.isEmpty || abs(factors[factors.count - 1] - floor) > 0.001 {
            factors.append(floor)
        }
        return factors
    }

    static func resolvedShrinkFloor(display: Bool, override: CGFloat?) -> CGFloat {
        if let override, override > 0 { return override }
        return display ? displayShrinkFloor : inlineShrinkFloor
    }

    private final class Box: NSObject {
        let artifact: NativeFormulaArtifact
        init(_ artifact: NativeFormulaArtifact) { self.artifact = artifact }
    }

    private let cache = NSCache<NSString, Box>()
    private let fontManager = MTFontManager()

    private init() {
        cache.countLimit = 320
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func artifact(tex: String,
                  fontSize: CGFloat,
                  color: UIColor,
                  display: Bool,
                  maxWidth: CGFloat,
                  shrinkFloor: CGFloat? = nil,
                  scale: CGFloat = UIScreen.main.scale) -> NativeFormulaArtifact? {
        let floor = Self.resolvedShrinkFloor(display: display, override: shrinkFloor)
        let key = cacheKey(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth,
            shrinkFloor: floor,
            scale: scale
        )
        if let hit = cache.object(forKey: key as NSString) {
            return hit.artifact
        }
        if let disk = loadFromDisk(key: key, scale: scale) {
            let cost = Int(disk.size.width * scale * disk.size.height * scale * 4)
            cache.setObject(Box(disk), forKey: key as NSString, cost: cost)
            return disk
        }
        // KaTeX is the only bitmap source. iosMath must not occupy this cache key.
        guard Thread.isMainThread else { return nil }
        let prepared = prepareTeX(tex)
        // KaTeX renders `\text{中文}` / prose via system font fallback — enqueue everything.
        if !KaTeXFormulaSnapshot.shared.hasFailed(cacheKey: key) {
            KaTeXFormulaSnapshot.shared.enqueue(
                tex: prepared,
                fontSize: fontSize,
                color: color,
                display: display,
                maxWidth: maxWidth,
                shrinkFloor: floor,
                scale: scale,
                cacheKey: key
            )
        }
        // Immediate paint so chat is not empty while KaTeX fonts/snapshot catch up.
        // Memory-only: disk stays reserved for KaTeX so a later snapshot can replace this.
        if let preview = renderIosMath(
            prepared: prepared,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth,
            shrinkFloor: floor,
            scale: scale
        ) {
            let cost = Int(preview.size.width * scale * preview.size.height * scale * 4)
            cache.setObject(Box(preview), forKey: key as NSString, cost: cost)
            return preview
        }
        return nil
    }

    private func renderIosMath(prepared: String,
                               fontSize: CGFloat,
                               color: UIColor,
                               display: Bool,
                               maxWidth: CGFloat,
                               shrinkFloor: CGFloat,
                               scale: CGFloat) -> NativeFormulaArtifact? {
        // iosMath/XITS has no CJK glyphs and prose `\text{}` paints garbled —
        // decline those previews entirely; the KaTeX snapshot lands shortly.
        if NativeMathProse.needsExpansion(prepared) { return nil }
        guard let first = renderIosMathOnce(
            prepared: prepared,
            fontSize: fontSize,
            color: color,
            display: display,
            scale: scale
        ) else { return nil }
        guard maxWidth > 0, first.size.width > maxWidth else { return first }
        // Shrink-to-fit preview: re-render at reduced font sizes, largest fit wins.
        // If even the floor overflows, keep the smallest render (scroll band/clip as today).
        var best = first
        for factor in Self.shrinkFactors(floor: shrinkFloor) {
            guard let attempt = renderIosMathOnce(
                prepared: prepared,
                fontSize: fontSize * factor,
                color: color,
                display: display,
                scale: scale
            ) else { break }
            best = attempt
            if attempt.size.width <= maxWidth { break }
        }
        return best
    }

    private func renderIosMathOnce(prepared: String,
                                   fontSize: CGFloat,
                                   color: UIColor,
                                   display: Bool,
                                   scale: CGFloat) -> NativeFormulaArtifact? {
        let (innerTeX, isBoxed) = unwrapLeadingBoxed(prepared)
        let renderTeX = normalizeLegacyCommands(innerTeX)
        let boxPadding: CGFloat = isBoxed ? max(5, fontSize * 0.3) : 0
        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.textColor = color
        label.fontSize = fontSize
        label.font = fontManager.latinModernFont(withSize: fontSize)
        label.labelMode = display ? .display : .text
        label.textAlignment = display ? .center : .left
        label.contentInsets = UIEdgeInsets(
            top: max(3, fontSize * 0.18),
            left: 3,
            bottom: max(8, fontSize * 0.42),
            right: 3
        )
        label.displayErrorInline = false
        var compatibleTeX = renderTeX
        for _ in 0..<8 {
            label.latex = compatibleTeX
            guard let error = label.error else { break }
            guard let recovered = recoverUnsupportedCommand(
                in: compatibleTeX,
                error: error
            ), recovered != compatibleTeX else { break }
            compatibleTeX = recovered
        }
        if label.error != nil { return nil }
        var labelSize = label.sizeThatFits(CGSize(width: 10_000, height: 10_000))
        labelSize.width = ceil(max(labelSize.width, 1))
        labelSize.height = ceil(max(labelSize.height, fontSize))
        let size = CGSize(
            width: labelSize.width + boxPadding * 2,
            height: labelSize.height + boxPadding * 2
        )
        label.frame = CGRect(origin: .zero, size: labelSize)
        label.setNeedsLayout()
        label.layoutIfNeeded()
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext(),
              let displayList = label.displayList else { return nil }
        if isBoxed {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(1, 1 / scale))
            context.stroke(CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
        }
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: boxPadding, y: boxPadding)
        displayList.draw(context)
        context.restoreGState()
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else { return nil }
        return NativeFormulaArtifact(
            image: image,
            size: size,
            baseline: min(size.height, fontSize * (display ? 1.0 : 0.82))
        )
    }

    func storeExternalArtifact(_ artifact: NativeFormulaArtifact, cacheKey: String) {
        Self.advanceArtifactGeneration()
        let cost = Int(artifact.size.width * artifact.size.height * 16)
        cache.setObject(Box(artifact), forKey: cacheKey as NSString, cost: max(cost, 1))
        storeToDisk(artifact, key: cacheKey)
        NativeMessageLayouter.shared.clear()
        NotificationCenter.default.post(name: .nativeFormulaDidRender, object: nil)
    }

    /// Shared by tests: delimiter peel + equation unwrap, no iosMath-only remaps.
    /// Peels iterate to a fixpoint: unwrapping `\begin{equation}` can expose a
    /// `$$`-wrapped body (the bare-line normalizer does not track env fences),
    /// and each layer is meaningless without the next.
    func prepareTeX(_ tex: String) -> String {
        var result = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            let next = unwrapDisplayEnvironments(
                rewriteUnsupportedEnvironments(stripOuterMathDelimiters(result))
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if next == result { break }
            result = next
        }
        return result
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// KaTeX lacks eqnarray/multline/subequations; map them onto `aligned` / strip.
    private func rewriteUnsupportedEnvironments(_ tex: String) -> String {
        var result = tex
        for name in ["eqnarray*", "eqnarray", "multline*", "multline"] {
            result = result
                .replacingOccurrences(of: "\\begin{\(name)}", with: "\\begin{aligned}")
                .replacingOccurrences(of: "\\end{\(name)}", with: "\\end{aligned}")
        }
        return result
            .replacingOccurrences(of: "\\begin{subequations}", with: "")
            .replacingOccurrences(of: "\\end{subequations}", with: "")
    }

    /// iosMath-only remaps. Tests can assert `\\big` never becomes `\\mathrm{big}`.
    func normalizedIosMathTeX(_ tex: String) -> String {
        normalizeLegacyCommands(prepareTeX(tex))
    }

    private func unwrapDisplayEnvironments(_ tex: String) -> String {
        var result = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = ["equation*", "equation", "gather*", "gather", "displaymath"]
        for name in names {
            let open = "\\begin{\(name)}"
            let close = "\\end{\(name)}"
            if result.hasPrefix(open), result.hasSuffix(close) {
                result = String(result.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return result
    }

    private func normalizeLegacyCommands(_ tex: String) -> String {
        var result = stripSizingDelimiters(tex)
        let replacements: [(String, String)] = [
            (#"\\operatorname\{([^{}]*)\}"#, #"\\mathrm{$1}"#),
            (#"\\xrightarrow\{([^{}]*)\}"#, #"\\longrightarrow^{$1}"#),
            (#"\\mathrm\{flat\}"#, #"\\flat"#),
            (#"\\mathrm\{sharp\}"#, #"\\sharp"#),
            (#"\\tag\{([^{}]*)\}"#, #"\\qquad\\mathrm{($1)}"#),
            // Only map short Latin `\text{label}` → `\mathrm`; prose/CJK stays for expansion.
            (#"\\text\{([A-Za-z0-9.,\-]+)\}"#, #"\\mathrm{$1}"#),
            (#"\\textbf\{([^{}]*)\}"#, #"\\mathbf{$1}"#),
            (#"\\boldsymbol\{"#, #"\\mathbf{"#),
            (#"\\bm\{"#, #"\\mathbf{"#),
            (#"\\begin\{aligned\}"#, #"\\begin{matrix}"#),
            (#"\\end\{aligned\}"#, #"\\end{matrix}"#),
            (#"\\begin\{align\*?\}"#, #"\\begin{matrix}"#),
            (#"\\end\{align\*?\}"#, #"\\end{matrix}"#),
            (#"\\begin\{pmatrix\}"#, #"\\left(\\begin{matrix}"#),
            (#"\\end\{pmatrix\}"#, #"\\end{matrix}\\right)"#),
            (#"\\begin\{bmatrix\}"#, #"\\left[\\begin{matrix}"#),
            (#"\\end\{bmatrix\}"#, #"\\end{matrix}\\right]"#),
            (#"\\begin\{cases\}"#, #"\\left\\{\\begin{matrix}"#),
            (#"\\end\{cases\}"#, #"\\end{matrix}\\right."#),
            (#"\\dfrac"#, #"\\frac"#),
            (#"\\tfrac"#, #"\\frac"#),
            (#"\\blacksquare"#, "■"),
            (#"\\limits"#, ""),
            (#"\\nolimits"#, ""),
            (#"\\lvert"#, #"\\left|"#),
            (#"\\rvert"#, #"\\right|"#),
            (#"\\longleftrightarrow"#, #"\\leftrightarrow"#),
            (#"\\longrightarrow"#, #"\\rightarrow"#),
            (#"\\colon"#, ":")
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: template
            )
        }
        return result
            .replacingOccurrences(of: "\\displaystyle", with: "")
            .replacingOccurrences(of: "\\dots", with: "\\cdots")
            // `aligned` / `align` use `&` as a tab; iosMath matrix is happier with `=`.
            .replacingOccurrences(of: "&=", with: "=")
    }

    /// Drop TeX delimiter-sizing commands. iosMath has no `\\big`; mapping them
    /// to `\\mathrm{big}` painted "Pbig" in chat.
    private func stripSizingDelimiters(_ tex: String) -> String {
        var result = tex
        let commands = [
            "\\Biggl", "\\Biggr", "\\biggl", "\\biggr",
            "\\Bigl", "\\Bigr", "\\bigl", "\\bigr",
            "\\Bigg", "\\bigg", "\\Big", "\\big"
        ]
        for command in commands {
            result = result.replacingOccurrences(of: command, with: "")
        }
        return result
    }

    /// Models / broken normalize passes sometimes leave outer `$$` / `\[\]` on the TeX body.
    private func stripOuterMathDelimiters(_ tex: String) -> String {
        var result = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        // `$$` must come before `$` so a double-dollar fence peels as one layer.
        let pairs = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        for (open, close) in pairs {
            if result.hasPrefix(open), result.hasSuffix(close), result.count > open.count + close.count {
                result = String(result.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    private func unwrapLeadingBoxed(_ tex: String) -> (String, Bool) {
        let prefix = "\\boxed{"
        guard tex.hasPrefix(prefix) else { return (tex, false) }
        var depth = 1
        var index = tex.index(tex.startIndex, offsetBy: prefix.count)
        let innerStart = index
        while index < tex.endIndex {
            switch tex[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let inner = String(tex[innerStart..<index])
                    let tail = String(tex[tex.index(after: index)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard tail.isEmpty else { return (tex, false) }
                    return (inner, true)
                }
            default:
                break
            }
            index = tex.index(after: index)
        }
        return (tex, false)
    }

    private func recoverUnsupportedCommand(in tex: String, error: Error) -> String? {
        let message = (error as NSError).localizedDescription
        guard let regex = try? NSRegularExpression(pattern: #"Invalid command \\([A-Za-z]+)"#),
              let match = regex.firstMatch(
                  in: message,
                  range: NSRange(location: 0, length: (message as NSString).length)
              ),
              match.numberOfRanges > 1 else { return nil }
        let command = (message as NSString).substring(with: match.range(at: 1))
        let sizing = Set(["big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
                          "biggl", "biggr", "Biggl", "Biggr"])
        if sizing.contains(command) {
            return stripSizingDelimiters(tex)
        }
        let nonRecoverable: Set<String> = [
            "multicolumn", "multirow", "hline", "color",
            "fbox", "boxed", "begin", "end", "array"
        ]
        if nonRecoverable.contains(command) { return nil }
        guard let range = rangeOfTeXCommand(command, in: tex) else { return nil }
        let symbolReplacements = [
            "flat": "\\flat",
            "sharp": "\\sharp",
            "blacksquare": "■",
            "limits": "",
            "nolimits": "",
            "displaystyle": ""
        ]
        if let replacement = symbolReplacements[command] {
            var recovered = tex
            recovered.replaceSubrange(range, with: replacement)
            return recovered
        }
        let followedByGroup = range.upperBound < tex.endIndex && tex[range.upperBound] == "{"
        let replacement = followedByGroup ? "\\mathrm" : "\\mathrm{\(command)}"
        var recovered = tex
        recovered.replaceSubrange(range, with: replacement)
        return recovered
    }

    /// `\in` must not match the prefix of `\int` / `\infty`.
    private func rangeOfTeXCommand(_ command: String, in tex: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: "\\\\\(NSRegularExpression.escapedPattern(for: command))(?![A-Za-z])") else {
            return nil
        }
        let ns = tex as NSString
        guard let match = regex.firstMatch(in: tex, range: NSRange(location: 0, length: ns.length)),
              let range = Range(match.range, in: tex) else { return nil }
        return range
    }

    func clear() {
        cache.removeAllObjects()
    }

    func hasMemoryArtifact(tex: String,
                           fontSize: CGFloat,
                           color: UIColor,
                           display: Bool,
                           maxWidth: CGFloat,
                           shrinkFloor: CGFloat? = nil,
                           scale: CGFloat = UIScreen.main.scale) -> Bool {
        let key = cacheKey(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth,
            shrinkFloor: Self.resolvedShrinkFloor(display: display, override: shrinkFloor),
            scale: scale
        )
        return cache.object(forKey: key as NSString) != nil
    }

    /// Memory or on-disk PNG — lets native chat skip blank preview placeholders.
    func hasCachedArtifact(tex: String,
                           fontSize: CGFloat,
                           color: UIColor,
                           display: Bool,
                           maxWidth: CGFloat,
                           shrinkFloor: CGFloat? = nil,
                           scale: CGFloat = UIScreen.main.scale) -> Bool {
        if hasMemoryArtifact(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth,
            shrinkFloor: shrinkFloor,
            scale: scale
        ) {
            return true
        }
        let key = cacheKey(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth,
            shrinkFloor: Self.resolvedShrinkFloor(display: display, override: shrinkFloor),
            scale: scale
        )
        let stamp = RenderCacheStore.stamp(key)
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metadataKey) as? [String: [String: Double]],
              raw[stamp] != nil else { return false }
        let path = cacheDirectory().appendingPathComponent(stamp + ".png").path
        return FileManager.default.fileExists(atPath: path)
    }

    /// True only when the KaTeX job for this exact key permanently failed
    /// (parse error after retries). Distinguishes "will never render" — where a
    /// prose/mono fallback is appropriate — from "snapshot still in flight".
    func hasFailedKaTeX(tex: String,
                        fontSize: CGFloat,
                        color: UIColor,
                        display: Bool,
                        maxWidth: CGFloat,
                        shrinkFloor: CGFloat? = nil,
                        scale: CGFloat = UIScreen.main.scale) -> Bool {
        let key = cacheKey(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth,
            shrinkFloor: Self.resolvedShrinkFloor(display: display, override: shrinkFloor),
            scale: scale
        )
        return KaTeXFormulaSnapshot.shared.hasFailed(cacheKey: key)
    }

    /// Memory or on-disk metadata size — never invokes iosMath (safe for layout hot paths).
    func knownArtifactSize(tex: String,
                           fontSize: CGFloat,
                           color: UIColor,
                           display: Bool,
                           maxWidth: CGFloat,
                           shrinkFloor: CGFloat? = nil,
                           scale: CGFloat = UIScreen.main.scale) -> CGSize? {
        let key = cacheKey(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth,
            shrinkFloor: Self.resolvedShrinkFloor(display: display, override: shrinkFloor),
            scale: scale
        )
        if let box = cache.object(forKey: key as NSString) {
            return box.artifact.size
        }
        let stamp = RenderCacheStore.stamp(key)
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metadataKey) as? [String: [String: Double]],
              let item = raw[stamp],
              let width = item["width"],
              let height = item["height"] else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// Cheap formula footprint while KaTeX snapshot is still queued.
    static func estimatedRenderSize(tex: String,
                                    fontSize: CGFloat,
                                    display: Bool,
                                    maxWidth: CGFloat) -> CGSize {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        if display {
            var height = fontSize * 2.1 + 18
            if trimmed.contains("\\frac") || trimmed.contains("\\dfrac") { height += fontSize * 1.0 }
            if trimmed.contains("\\sum") || trimmed.contains("\\int") || trimmed.contains("\\prod") {
                height += fontSize * 0.75
            }
            if trimmed.contains("\\begin{") { height += fontSize * 2.0 }
            if trimmed.contains("\\sqrt") { height += fontSize * 0.35 }
            let width = min(maxWidth, max(fontSize * 4, fontSize * CGFloat(max(8, min(trimmed.count, 40)))))
            return CGSize(width: width, height: height)
        }
        let width = min(maxWidth * 0.92, fontSize * CGFloat(max(4, min(trimmed.count, 22))))
        return CGSize(width: width, height: fontSize * 1.28)
    }

    func clearDisk() {
        clear()
        UserDefaults.standard.removeObject(forKey: Self.metadataKey)
        try? FileManager.default.removeItem(at: cacheDirectory())
    }

    private func cacheKey(tex: String,
                          fontSize: CGFloat,
                          color: UIColor,
                          display: Bool,
                          maxWidth: CGFloat,
                          shrinkFloor: CGFloat,
                          scale: CGFloat) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [
            "native_tex_katex_v7",
            RenderCacheStore.stamp(tex),
            String(Int((fontSize * 10).rounded())),
            display ? "d" : "i",
            String(format: "%.3f-%.3f-%.3f-%.3f", red, green, blue, alpha),
            String(Int(maxWidth.rounded())),
            String(Int((shrinkFloor * 100).rounded())),
            String(Int(scale))
        ].joined(separator: "|")
    }

    private func loadFromDisk(key: String, scale: CGFloat) -> NativeFormulaArtifact? {
        let stamp = RenderCacheStore.stamp(key)
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metadataKey) as? [String: [String: Double]],
              let item = raw[stamp],
              let width = item["width"],
              let height = item["height"],
              let baseline = item["baseline"],
              let data = try? Data(contentsOf: cacheDirectory().appendingPathComponent(stamp + ".png")),
              // PNG bytes are device-scaled; without an explicit scale, UIImage treats
              // pixels as points and mathScroll UIImageViews blow up ~3×.
              let image = UIImage(data: data, scale: max(scale, 1)) else { return nil }
        return NativeFormulaArtifact(
            image: image,
            size: CGSize(width: width, height: height),
            baseline: CGFloat(baseline)
        )
    }

    private func storeToDisk(_ artifact: NativeFormulaArtifact, key: String) {
        let stamp = RenderCacheStore.stamp(key)
        let size = artifact.size
        let baseline = artifact.baseline
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let data = artifact.image.pngData() else { return }
            let directory = self.cacheDirectory()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(stamp + ".png"), options: .atomic)
            DispatchQueue.main.async {
                var raw = UserDefaults.standard.dictionary(forKey: Self.metadataKey) as? [String: [String: Double]] ?? [:]
                raw[stamp] = [
                    "width": Double(size.width),
                    "height": Double(size.height),
                    "baseline": Double(baseline)
                ]
                if raw.count > 480 {
                    raw = Dictionary(uniqueKeysWithValues: raw.suffix(480))
                }
                UserDefaults.standard.set(raw, forKey: Self.metadataKey)
            }
        }
    }

    private func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("connects_native_formula", isDirectory: true)
    }
}
