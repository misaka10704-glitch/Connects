import UIKit

final class NativeFormulaRenderer {
    static let shared = NativeFormulaRenderer()
    private static let metadataKey = "connects_native_formula_meta_v1"

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
        if let disk = loadFromDisk(key: key) {
            let cost = Int(disk.size.width * scale * disk.size.height * scale * 4)
            cache.setObject(Box(disk), forKey: key as NSString, cost: cost)
            return disk
        }
        precondition(Thread.isMainThread, "iosMath rendering must run on the main thread")
        let normalizedTeX = normalizeLegacyCommands(tex)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let trimmedTeX = normalizedTeX.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBoxed = trimmedTeX.hasPrefix("\\boxed{") && trimmedTeX.hasSuffix("}")
        let renderTeX: String
        if isBoxed {
            renderTeX = String(trimmedTeX.dropFirst("\\boxed{".count).dropLast())
        } else {
            renderTeX = trimmedTeX
        }
        let boxPadding: CGFloat = isBoxed ? max(5, fontSize * 0.3) : 0
        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.textColor = color
        label.fontSize = fontSize
        label.font = fontManager.xitsFont(withSize: fontSize)
        label.labelMode = display ? .display : .text
        label.textAlignment = display ? .center : .left
        label.contentInsets = UIEdgeInsets(
            top: max(3, fontSize * 0.18),
            left: 3,
            bottom: max(4, fontSize * 0.26),
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

    private func normalizeLegacyCommands(_ tex: String) -> String {
        var result = tex
        let replacements: [(String, String)] = [
            (#"\\operatorname\{([^{}]*)\}"#, #"\\mathrm{$1}"#),
            (#"\\xrightarrow\{([^{}]*)\}"#, #"\\longrightarrow^{$1}"#)
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
            .replacingOccurrences(of: "\\Bigl", with: "\\left")
            .replacingOccurrences(of: "\\bigl", with: "\\left")
            .replacingOccurrences(of: "\\Bigr", with: "\\right")
            .replacingOccurrences(of: "\\bigr", with: "\\right")
            .replacingOccurrences(of: "\\dots", with: "\\cdots")
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
        let token = "\\\(command)"
        guard let range = tex.range(of: token) else { return nil }
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
            "native_tex_xits_padded_v3",
            RenderCacheStore.stamp(tex),
            String(Int((fontSize * 10).rounded())),
            display ? "d" : "i",
            String(format: "%.3f-%.3f-%.3f-%.3f", red, green, blue, alpha),
            String(Int(scale))
        ].joined(separator: "|")
    }

    private func loadFromDisk(key: String) -> NativeFormulaArtifact? {
        let stamp = RenderCacheStore.stamp(key)
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.metadataKey) as? [String: [String: Double]],
              let item = raw[stamp],
              let width = item["width"],
              let height = item["height"],
              let baseline = item["baseline"],
              let data = try? Data(contentsOf: cacheDirectory().appendingPathComponent(stamp + ".png")),
              let image = UIImage(data: data) else { return nil }
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
