import UIKit

/// Body snapshots for finished assistant replies — memory + disk.
/// Keyed by message + content stamp + font + appearance + layoutWidth bucket
/// so portrait/landscape and sidebar open/closed miss cleanly across widths.
/// Once a chat has been opened and captured, reopen paints from disk first.
final class AssistantBodySnapshotCache {
    static let shared = AssistantBodySnapshotCache()

    /// Snapshot every finished body that has real content (fast reopen path).
    static let minBodyHeight: CGFloat = 36

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var retainedWidthBuckets = Set<Int>()
    /// Bumped to abandon in-flight background warmTail when switching chats.
    private var warmEpoch: Int = 0

    private init() {
        memory.countLimit = 96
        memory.totalCostLimit = 48 * 1024 * 1024
    }

    @discardableResult
    func beginWarmEpoch() -> Int {
        lock.lock()
        warmEpoch &+= 1
        let epoch = warmEpoch
        lock.unlock()
        return epoch
    }

    func cancelWarm() {
        _ = beginWarmEpoch()
    }

    private func isWarmEpochCurrent(_ epoch: Int) -> Bool {
        lock.lock()
        let ok = epoch == warmEpoch
        lock.unlock()
        return ok
    }

    static func widthBucket(for layoutWidth: CGFloat) -> Int {
        guard layoutWidth > 1 else { return 0 }
        return Int((layoutWidth / 4).rounded()) * 4
    }

    static func shouldSnapshot(content: String, bodyHeight: CGFloat) -> Bool {
        !content.isEmpty && bodyHeight >= minBodyHeight
    }

    static func makeKey(messageID: String,
                        content: String,
                        fontSize: CGFloat,
                        appearance: String,
                        layoutWidth: CGFloat) -> String {
        let bucket = widthBucket(for: layoutWidth)
        let stamp = RenderCacheStore.stamp(content)
        // v8: stricter width match — portrait must not reuse landscape snaps.
        return "bodyv8|\(messageID)|\(stamp)|\(Int(fontSize * 10))|\(appearance)|\(bucket)"
    }

    /// Callers pass bubble/content width (`currentRenderWidth`), not raw table width.
    static func contentWidth(for layoutWidth: CGFloat) -> CGFloat {
        min(DSTheme.bubbleMaxWidth, max(layoutWidth, 120))
    }

    /// Soft check for capture/reject only. Lookup keys by host width; bitmaps may
    /// differ a few dozen pts (column vs table-48) and still scaleToFill cleanly.
    static let widthMatchTolerance: CGFloat = 6
    /// How far to probe / accept snaps keyed by live column width (legacy bodyv8).
    static let nearbyWidthProbe: CGFloat = 48

    static func matchesLayoutWidth(_ image: UIImage, layoutWidth: CGFloat) -> Bool {
        abs(image.size.width - layoutWidth) <= widthMatchTolerance
    }

    private func cacheKey(messageID: String,
                          content: String,
                          fontSize: CGFloat,
                          appearance: String,
                          layoutWidth: CGFloat) -> (key: String, width: CGFloat) {
        let width = Self.contentWidth(for: layoutWidth)
        let key = Self.makeKey(
            messageID: messageID,
            content: content,
            fontSize: fontSize,
            appearance: appearance,
            layoutWidth: width
        )
        return (key, width)
    }

    private func probeWidths(around width: CGFloat) -> [CGFloat] {
        var widths: [CGFloat] = [width]
        var delta: CGFloat = 4
        while delta <= Self.nearbyWidthProbe {
            widths.append(width + delta)
            widths.append(width - delta)
            delta += 4
        }
        return widths
    }

    func image(messageID: String,
               content: String,
               fontSize: CGFloat,
               appearance: String,
               layoutWidth: CGFloat,
               allowDisk: Bool = true) -> UIImage? {
        let primary = cacheKey(
            messageID: messageID,
            content: content,
            fontSize: fontSize,
            appearance: appearance,
            layoutWidth: layoutWidth
        )
        if let hit = memory.object(forKey: primary.key as NSString) {
            return hit
        }
        // Exact host key, then nearby buckets (old captures keyed by column.bounds).
        for candidate in probeWidths(around: primary.width) {
            let width = Self.contentWidth(for: candidate)
            let key = Self.makeKey(
                messageID: messageID,
                content: content,
                fontSize: fontSize,
                appearance: appearance,
                layoutWidth: width
            )
            if let hit = memory.object(forKey: key as NSString) {
                memory.setObject(hit, forKey: primary.key as NSString, cost: max(1, Int(hit.size.width * hit.size.height * 4)))
                return hit
            }
            guard allowDisk, let disk = RenderCacheStore.snapshot(forKey: key) else { continue }
            let cost = max(1, Int(disk.size.width * disk.size.height * disk.scale * disk.scale * 4))
            memory.setObject(disk, forKey: primary.key as NSString, cost: cost)
            if key != primary.key {
                // Migrate so the next open hits the host-width key directly.
                RenderCacheStore.storeSnapshot(disk, forKey: primary.key)
            }
            return disk
        }
        return nil
    }

    /// Existence check without decoding JPEG (open-path probe).
    func hasDiskOrMemoryImage(messageID: String,
                              content: String,
                              fontSize: CGFloat,
                              appearance: String,
                              layoutWidth: CGFloat) -> Bool {
        let primary = cacheKey(
            messageID: messageID,
            content: content,
            fontSize: fontSize,
            appearance: appearance,
            layoutWidth: layoutWidth
        )
        for candidate in probeWidths(around: primary.width) {
            let width = Self.contentWidth(for: candidate)
            let key = Self.makeKey(
                messageID: messageID,
                content: content,
                fontSize: fontSize,
                appearance: appearance,
                layoutWidth: width
            )
            if memory.object(forKey: key as NSString) != nil { return true }
            if RenderCacheStore.snapshotExists(forKey: key) { return true }
        }
        return false
    }

    func hasImage(messageID: String,
                  content: String,
                  fontSize: CGFloat,
                  appearance: String,
                  layoutWidth: CGFloat) -> Bool {
        hasDiskOrMemoryImage(
            messageID: messageID,
            content: content,
            fontSize: fontSize,
            appearance: appearance,
            layoutWidth: layoutWidth
        )
    }

    func store(_ image: UIImage,
               messageID: String,
               content: String,
               fontSize: CGFloat,
               appearance: String,
               layoutWidth: CGFloat) {
        // Key by host render width (same as open lookup). Bitmap may be column-sized;
        // open path scaleToFill — do not require pixel-perfect width match.
        let expected = Self.contentWidth(for: layoutWidth)
        let bitmapW = Self.contentWidth(for: image.size.width)
        guard Self.shouldSnapshot(content: content, bodyHeight: image.size.height),
              abs(bitmapW - expected) <= Self.nearbyWidthProbe else { return }
        let key = Self.makeKey(
            messageID: messageID,
            content: content,
            fontSize: fontSize,
            appearance: appearance,
            layoutWidth: expected
        )
        let bucket = Self.widthBucket(for: expected)
        let cost = max(1, Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        lock.lock()
        retainedWidthBuckets.insert(bucket)
        if retainedWidthBuckets.count > 3 {
            retainedWidthBuckets = [bucket]
            memory.removeAllObjects()
        }
        lock.unlock()
        memory.setObject(image, forKey: key as NSString, cost: cost)
        RenderCacheStore.storeSnapshot(image, forKey: key)
    }

    /// Sync-decode the latest assistant JPEG for cold open (must run before reloadData).
    /// Purges blank / unusable bitmaps so open never paints white JPEG frames.
    @discardableResult
    func prefetchTailAssistantImage(messages: [ChatMessage], layoutWidth: CGFloat) -> UIImage? {
        let appearance = SettingsManager.shared.appearanceMode.rawValue
        let font = SettingsManager.shared.chatBodyFontSize
        let width = Self.contentWidth(for: layoutWidth)
        guard let message = messages.reversed().first(where: {
            $0.role == .assistant && !$0.isStreaming && !$0.content.isEmpty
        }) else { return nil }
        guard let image = image(
            messageID: message.id,
            content: message.content,
            fontSize: font,
            appearance: appearance,
            layoutWidth: width,
            allowDisk: true
        ) else { return nil }
        if Self.isSnapUsableForOpen(image: image, message: message) {
            return image
        }
        purgeSnapshot(
            messageID: message.id,
            content: message.content,
            fontSize: font,
            appearance: appearance,
            layoutWidth: width
        )
        return nil
    }

    /// Open paint gate — stricter than idle display (rejects white / postage-stamp snaps).
    static func isSnapUsableForOpen(image: UIImage, message: ChatMessage) -> Bool {
        if isBlankSnapshot(image) { return false }
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 40, imgH > 20, imgH < 6000 else { return false }
        let contentLen = message.content.count
        if contentLen > 160, imgH < 64 { return false }
        if contentLen > 800, imgH < 120 { return false }
        if contentLen > 2000, imgH < 200 { return false }
        return true
    }

    /// Empty / failed captures (drawHierarchy before paint) — reject for display.
    static func isBlankSnapshot(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = min(cg.width, 32)
        let h = min(cg.height, 32)
        guard w > 0, h > 0 else { return true }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bright = 0
        let total = w * h
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i + 1]) / 255
            let b = CGFloat(pixels[i + 2]) / 255
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            if luma > 0.93 { bright += 1 }
        }
        return Double(bright) / Double(total) > 0.92
    }

    func purgeSnapshot(messageID: String,
                       content: String,
                       fontSize: CGFloat,
                       appearance: String,
                       layoutWidth: CGFloat) {
        let primary = cacheKey(
            messageID: messageID,
            content: content,
            fontSize: fontSize,
            appearance: appearance,
            layoutWidth: layoutWidth
        )
        for candidate in probeWidths(around: primary.width) {
            let width = Self.contentWidth(for: candidate)
            let key = Self.makeKey(
                messageID: messageID,
                content: content,
                fontSize: fontSize,
                appearance: appearance,
                layoutWidth: width
            )
            memory.removeObject(forKey: key as NSString)
            RenderCacheStore.removeSnapshot(forKey: key)
        }
    }

    /// Prefetch tail snapshots into RAM. Decodes only the newest few (visible open);
    /// probes the rest with fileExists so open isn't blocked on JPEG decode.
    @discardableResult
    func warmTail(messages: [ChatMessage],
                  layoutWidth: CGFloat,
                  limit: Int = 16,
                  decodeLimit: Int = 6,
                  epoch: Int? = nil) -> Int {
        let appearance = SettingsManager.shared.appearanceMode.rawValue
        let font = SettingsManager.shared.chatBodyFontSize
        let width = Self.contentWidth(for: layoutWidth)
        var checked = 0
        var decoded = 0
        var hits = 0
        for message in messages.reversed() {
            if let epoch, !isWarmEpochCurrent(epoch) { return hits }
            guard checked < limit else { break }
            guard message.role == .assistant,
                  !message.isStreaming,
                  !message.content.isEmpty else { continue }
            checked += 1
            let exists = hasDiskOrMemoryImage(
                messageID: message.id,
                content: message.content,
                fontSize: font,
                appearance: appearance,
                layoutWidth: width
            )
            guard exists else { continue }
            hits += 1
            if decoded < decodeLimit {
                _ = image(
                    messageID: message.id,
                    content: message.content,
                    fontSize: font,
                    appearance: appearance,
                    layoutWidth: width
                )
                decoded += 1
            }
        }
        return hits
    }

    func removeAll() {
        lock.lock()
        retainedWidthBuckets.removeAll()
        lock.unlock()
        memory.removeAllObjects()
    }

    /// Drop RAM snaps after rotation / sidebar width change so the next paint
    /// reloads from the matching width bucket only.
    func dropMemoryCache() {
        lock.lock()
        retainedWidthBuckets.removeAll()
        lock.unlock()
        memory.removeAllObjects()
    }
}
