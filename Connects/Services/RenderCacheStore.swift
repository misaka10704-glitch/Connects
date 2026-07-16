import UIKit

/// Persists rich-message heights + JPEG snapshots across launches (cold-open paint).
enum RenderCacheStore {
    private static let heightsKey = "connects_web_heights_v1"
    private static let snapDirName = "connects_web_snaps"
    /// Body snapshots for many conversations × widths — keep a generous LRU.
    private static let maxSnapFiles = 160
    private static var saveHeightsWork: DispatchWorkItem?

    // MARK: - Heights

    static func loadHeights() -> [String: [String: CGFloat]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: heightsKey) as? [String: [String: Double]] else {
            return [:]
        }
        var out: [String: [String: CGFloat]] = [:]
        for (cid, map) in raw {
            var inner: [String: CGFloat] = [:]
            for (mid, h) in map where h > 40 && h < 8000 {
                inner[mid] = CGFloat(h)
            }
            if !inner.isEmpty { out[cid] = inner }
        }
        return out
    }

    static func saveHeights(_ cache: [String: [String: CGFloat]],
                            messageOrder: [String: [String]] = [:],
                            debounce: TimeInterval = 0.6) {
        saveHeightsWork?.cancel()
        let work = DispatchWorkItem {
            var raw: [String: [String: Double]] = [:]
            for (cid, map) in cache {
                var inner: [String: Double] = [:]
                if let order = messageOrder[cid], !order.isEmpty {
                    // Keep the tail of long threads — readers open at the latest turn.
                    for mid in order.suffix(240) {
                        guard let h = map[mid], h > 40 && h < 8000 else { continue }
                        inner[mid] = Double(h)
                    }
                } else {
                    for (mid, h) in map where h > 40 && h < 8000 {
                        inner[mid] = Double(h)
                        if inner.count >= 200 { break }
                    }
                }
                if !inner.isEmpty { raw[cid] = inner }
            }
            // Cap conversations.
            if raw.count > 40 {
                let keys = Array(raw.keys.prefix(40))
                raw = Dictionary(uniqueKeysWithValues: keys.map { ($0, raw[$0]!) })
            }
            UserDefaults.standard.set(raw, forKey: heightsKey)
        }
        saveHeightsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    static func clearHeights() {
        saveHeightsWork?.cancel()
        UserDefaults.standard.removeObject(forKey: heightsKey)
    }

    // MARK: - Snapshots

    static func snapshotExists(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forKey: key).path)
    }

    static func snapshot(forKey key: String) -> UIImage? {
        let url = fileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let raw = UIImage(data: data),
              let cg = raw.cgImage else { return nil }
        // jpegData drops UIImage.scale. Prefer screen scale (retina captures); if the
        // bitmap's pixel width is already ~point-sized (older scale-1 snaps), keep scale 1.
        let screen = UIScreen.main.scale
        let px = CGFloat(cg.width)
        let scale: CGFloat
        if screen > 1, px > 120, px / screen >= 120 {
            scale = screen
        } else {
            scale = 1
        }
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return image
    }

    static func storeSnapshot(_ image: UIImage, forKey key: String) {
        // Encode off-main but at userInitiated so cold-kill shortly after open still persists.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = image.jpegData(compressionQuality: 0.78) else { return }
            let dir = snapDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = fileURL(forKey: key)
            try? data.write(to: url, options: .atomic)
            pruneSnapshotsIfNeeded()
        }
    }

    static func clearSnapshots() {
        let dir = snapDirectory()
        try? FileManager.default.removeItem(at: dir)
    }

    static func clearAll() {
        clearHeights()
        clearSnapshots()
    }

    /// Stable fingerprint — Swift's `hashValue` is not stable across launches.
    static func stamp(_ text: String) -> String {
        var h: UInt64 = 5381
        for b in text.utf8 {
            h = ((h << 5) &+ h) &+ UInt64(b)
        }
        return "\(text.count)-\(String(h, radix: 16))"
    }

    private static func snapDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(snapDirName, isDirectory: true)
    }

    private static func fileURL(forKey key: String) -> URL {
        let name = stamp(key) + ".jpg"
        return snapDirectory().appendingPathComponent(name)
    }

    private static func pruneSnapshotsIfNeeded() {
        let dir = snapDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        guard files.count > maxSnapFiles else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        for url in sorted.prefix(files.count - maxSnapFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
