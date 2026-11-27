import UIKit
import ImageIO

enum ImageAttachmentHelper {
    static let maxDimension: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.72
    static let payloadRecompressQuality: CGFloat = 0.55
    /// Base64 is ASCII, so character count is also the serialized payload byte count.
    static let maxCombinedPayloadBytes = 10 * 1024 * 1024

    /// Small bitmaps used by bubbles/composer chips. 24 MB is deliberately small:
    /// a 1280px decode is ~5 MB before scaling, and several rows can be visible.
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func prepareJPEGBase64(from image: UIImage,
                                  quality: CGFloat = jpegQuality) -> String? {
        let scaled = scale(image)
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }
        return data.base64EncodedString()
    }

    /// Full decode — retained for OCR and other non-bubble consumers. Chat cells must
    /// use `thumbnail(from:maxDimension:)` instead.
    static func image(from base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }

    /// Decode a bounded thumbnail directly through ImageIO (no retained full-size bitmap).
    static func thumbnail(from base64: String, maxDimension: CGFloat = 480) -> UIImage? {
        guard !base64.isEmpty else { return nil }
        let key = thumbnailCacheKey(for: base64, maxDimension: maxDimension)
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDimension.rounded()))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        let cost = max(1, cgImage.width * cgImage.height * 4)
        thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Small composer-chip bitmap. The caller may pass a full-resolution UIImage, but
    /// only this bounded copy is stored by the composer.
    static func composerThumbnail(from image: UIImage, maxDimension: CGFloat = 112) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension, maxSide > 0 else { return image }
        let ratio = maxDimension / maxSide
        let newSize = CGSize(
            width: max(1, floor(size.width * ratio)),
            height: max(1, floor(size.height * ratio))
        )
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }

    static func payloadByteCount(_ base64List: [String]) -> Int {
        base64List.reduce(0) { $0 + $1.utf8.count }
    }

    static func recompressJPEGBase64(_ base64: String,
                                     quality: CGFloat = payloadRecompressQuality) -> String? {
        guard let data = Data(base64Encoded: base64),
              let decoded = UIImage(data: data) else { return nil }
        // Legacy/camera payloads should also obey the normal dimension cap here.
        let scaled = scale(decoded)
        guard let recompressed = scaled.jpegData(compressionQuality: quality) else { return nil }
        return recompressed.base64EncodedString()
    }

    /// Best-effort pending-payload guard. Existing attachments are left untouched;
    /// the largest incoming images are recompressed once at `quality` until the
    /// combined serialized payload fits (or no further shrink is possible).
    static func enforceCombinedPayloadLimit(existing: [String],
                                            incoming: [String],
                                            maxBytes: Int = maxCombinedPayloadBytes,
                                            quality: CGFloat = payloadRecompressQuality) -> [String] {
        var result = incoming
        var total = payloadByteCount(existing) + payloadByteCount(result)
        guard total > maxBytes else { return result }

        var attempted = Set<Int>()
        while total > maxBytes {
            let candidates = result.indices.filter { !attempted.contains($0) }
            guard let largest = candidates.max(by: { result[$0].utf8.count < result[$1].utf8.count }) else {
                break
            }
            attempted.insert(largest)
            let before = result[largest].utf8.count
            guard let compressed = recompressJPEGBase64(result[largest], quality: quality) else {
                continue
            }
            let after = compressed.utf8.count
            guard after < before else { continue }
            result[largest] = compressed
            total += after - before
        }
        return result
    }

    private static func thumbnailCacheKey(for base64: String, maxDimension: CGFloat) -> NSString {
        // Cheap, stable key without hashing megabytes of base64 on every cell reuse.
        let prefix = base64.prefix(48)
        let suffix = base64.suffix(48)
        return "\(Int(maxDimension.rounded())):\(base64.utf8.count):\(prefix):\(suffix)" as NSString
    }

    private static func scale(_ image: UIImage) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let ratio = maxDimension / maxSide
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }
}
