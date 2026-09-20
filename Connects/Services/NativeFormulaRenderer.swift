import UIKit

final class NativeFormulaRenderer {
    static let shared = NativeFormulaRenderer()
    private static let metadataKey = "connects_native_formula_meta_v2"

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
                  scale: CGFloat = UIScreen.main.scale) -> NativeFormulaArtifact? {
        let key = cacheKey(tex: tex, fontSize: fontSize, color: color, display: display, scale: scale)
        if let hit = cache.object(forKey: key as NSString) {
            return hit.artifact
        }
        if let disk = loadFromDisk(key: key, scale: scale) {
            let cost = Int(disk.size.width * scale * disk.size.height * scale * 4)
            cache.setObject(Box(disk), forKey: key as NSString, cost: cost)
            return disk
        }
        guard Thread.isMainThread else { return nil }
        KaTeXFormulaSnapshot.shared.prepare()
        let prepared = prepareTeX(tex)
        // XITS / KaTeX default fonts have no CJK glyphs — refuse so callers expand via NativeMathProse.
        if NativeMathProse.containsCJK(prepared) {
            return nil
        }
        if !KaTeXFormulaSnapshot.shared.hasFailed(cacheKey: key) {
            KaTeXFormulaSnapshot.shared.enqueue(
                tex: prepared,
                fontSize: fontSize,
                color: color,
                display: display,
                scale: scale,
                cacheKey: key
            )
        }
        let (innerTeX, isBoxed) = unwrapLeadingBoxed(prepared)
        let renderTeX = normalizeLegacyCommands(innerTeX)
        let boxPadding: CGFloat = isBoxed ? max(5, fontSize * 0.3) : 0
        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.textColor = color
        label.fontSize = fontSize
        label.font = fontManager.xitsFont(withSize: fontSize)
        label.labelMode = display ? .display : .text
        label.textAlignment = display ? .center : .left
        // Extra bottom inset: fraction denominators / radical depth sit below the baseline.
        // Undersized canvases clip exactly the empty-denominator symptom seen in chat.
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
        if let error = label.error {
            #if DEBUG
            print("NativeFormulaRenderer iosMath error: \(error) | \(compatibleTeX)")
            #endif
            return nil
        }
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
            context.stroke(
                CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
            )
        }
        // iosMath positions glyphs in CoreText's bottom-left coordinate space.
        // A UIKit image context is top-left based, so drawing without this
        // transform vertically mirrors radicals, integrals and delimiters.
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: boxPadding, y: boxPadding)
        displayList.draw(context)
        context.restoreGState()
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else { return nil }
        let artifact = NativeFormulaArtifact(
            image: image,
            size: size,
            baseline: min(size.height, fontSize * (display ? 1.0 : 0.82))
        )
        let cost = Int(size.width * scale * size.height * scale * 4)
        cache.setObject(Box(artifact), forKey: key as NSString, cost: cost)
        storeToDisk(artifact, key: key)
        return artifact
    }

    func storeExternalArtifact(_ artifact: NativeFormulaArtifact, cacheKey: String) {
        let cost = Int(artifact.size.width * artifact.size.height * 16)
        cache.setObject(Box(artifact), forKey: cacheKey as NSString, cost: max(cost, 1))
        storeToDisk(artifact, key: cacheKey)
        NativeMessageLayouter.shared.clear()
        NotificationCenter.default.post(name: .nativeFormulaDidRender, object: nil)
    }

    /// Shared by tests: delimiter peel + equation unwrap, no iosMath-only remaps.
    func prepareTeX(_ tex: String) -> String {
        unwrapDisplayEnvironments(stripOuterMathDelimiters(tex))
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            (#"\\dfrac\{"#, #"\\frac{"#),
            (#"\\tfrac\{"#, #"\\frac{"#),
            (#"\\lvert"#, #"\\left|"#),
            (#"\\rvert"#, #"\\right|"#),
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
        let pairs = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)")]
        for (open, close) in pairs {
            if result.hasPrefix(open), result.hasSuffix(close), result.count > open.count + close.count {
                result = String(result.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    /// Strips a leading `\boxed{…}` even when the inner expression contains nested braces.
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
        let token = "\\\(command)"
        guard let range = tex.range(of: token) else { return nil }
        let symbolReplacements = ["flat": "\\flat", "sharp": "\\sharp"]
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

    func clear() {
        cache.removeAllObjects()
    }

    func hasMemoryArtifact(tex: String,
                           fontSize: CGFloat,
                           color: UIColor,
                           display: Bool,
                           scale: CGFloat = UIScreen.main.scale) -> Bool {
        let key = cacheKey(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            scale: scale
        )
        return cache.object(forKey: key as NSString) != nil
    }

    /// Memory or on-disk PNG — lets native chat skip blank preview placeholders.
    func hasCachedArtifact(tex: String,
                           fontSize: CGFloat,
                           color: UIColor,
                           display: Bool,
                           scale: CGFloat = UIScreen.main.scale) -> Bool {
        if hasMemoryArtifact(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            scale: scale
        ) {
            return true
        }
        let key = cacheKey(
            tex: tex,
            fontSize: fontSize,
            color: color,
            display: display,
            scale: scale
        )
        let stamp = RenderCacheStore.stamp(key)
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metadataKey) as? [String: [String: Double]],
              raw[stamp] != nil else { return false }
        let path = cacheDirectory().appendingPathComponent(stamp + ".png").path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Memory or on-disk metadata size — never invokes iosMath (safe for layout hot paths).
    func knownArtifactSize(tex: String,
                           fontSize: CGFloat,
                           color: UIColor,
                           display: Bool,
                           scale: CGFloat = UIScreen.main.scale) -> CGSize? {
        let key = cacheKey(tex: tex, fontSize: fontSize, color: color, display: display, scale: scale)
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

    /// Cheap formula footprint when iosMath has not run yet (iPad Air 1 / preview layout).
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
                          scale: CGFloat) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [
            "native_tex_katex_v2",
            RenderCacheStore.stamp(tex),
            String(Int((fontSize * 10).rounded())),
            display ? "d" : "i",
            String(format: "%.3f-%.3f-%.3f-%.3f", red, green, blue, alpha),
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
