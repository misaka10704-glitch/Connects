import UIKit

/// Single authority for chat row geometry.
/// Display map is populated once per conversation / at rest — never recomputed during scroll.
/// Row height must match painted content: native layout height only when cache exists, else plain fallback.
final class ChatRowHeightResolver {
    /// Vertical inset inside the cell (column top + column bottom). Keep small so row edge ≈ bubble edge.
    static let cellVerticalMargin: CGFloat = 8
    static var cellContentInset: CGFloat { cellVerticalMargin / 2 }

    private var committedColumnHeights: [String: CGFloat] = [:]
    private var committedIDs = Set<String>()
    private var diskEstimates: [String: CGFloat] = [:]
    private var displayColumnHeights: [String: CGFloat] = [:]
    /// While set, `rowHeight` ignores display mutations (scroll geometry freeze).
    private var scrollFrozenRowHeights: [String: CGFloat]?

    // MARK: - Session lifecycle

    func clearAll() {
        committedColumnHeights.removeAll()
        committedIDs.removeAll()
        diskEstimates.removeAll()
        displayColumnHeights.removeAll()
        scrollFrozenRowHeights = nil
    }

    var isScrollHeightFrozen: Bool { scrollFrozenRowHeights != nil }

    /// Freeze row heights for the scroll gesture. Pass `rows` to avoid O(n) work on long threads;
    /// rows entering the viewport can be added via `freezeRowHeightIfNeeded` while frozen.
    func beginScrollHeightFreeze(messages: [ChatMessage],
                                 layoutWidth: CGFloat,
                                 rows: [Int]? = nil) {
        guard !messages.isEmpty else {
            scrollFrozenRowHeights = [:]
            return
        }
        let count = messages.count
        var map = [String: CGFloat]()
        let rowList = rows ?? Array(0..<count)
        map.reserveCapacity(rowList.count)
        for row in rowList where row >= 0 && row < count {
            let message = messages[row]
            map[message.id] = unfrozenRowHeight(
                for: message,
                row: row,
                messageCount: count,
                layoutWidth: layoutWidth
            )
        }
        scrollFrozenRowHeights = map
    }

    func freezeRowHeightIfNeeded(for message: ChatMessage,
                                 row: Int,
                                 messageCount: Int,
                                 layoutWidth: CGFloat) {
        guard scrollFrozenRowHeights != nil,
              scrollFrozenRowHeights?[message.id] == nil else { return }
        scrollFrozenRowHeights?[message.id] = unfrozenRowHeight(
            for: message,
            row: row,
            messageCount: messageCount,
            layoutWidth: layoutWidth
        )
    }

    func endScrollHeightFreeze() {
        scrollFrozenRowHeights = nil
    }

    /// Grow the frozen row map when painted content exceeds the snapshotted height.
    @discardableResult
    func growFrozenRowHeightIfNeeded(messageID: String, columnHeight: CGFloat) -> Bool {
        guard scrollFrozenRowHeights != nil, columnHeight > 40 else { return false }
        let required = columnHeight + Self.cellVerticalMargin
        let current = scrollFrozenRowHeights?[messageID] ?? 0
        guard required > current + 0.5 else { return false }
        scrollFrozenRowHeights?[messageID] = required
        let prior = bestKnownColumnHeight(for: messageID)
        committedColumnHeights[messageID] = max(prior, columnHeight)
        committedIDs.insert(messageID)
        return true
    }

    func resetForConversation(diskCache: [String: CGFloat],
                              messages: [ChatMessage],
                              layoutWidth: CGFloat,
                              layoutProbeTailRows: Int? = nil) {
        committedColumnHeights.removeAll()
        committedIDs.removeAll()
        scrollFrozenRowHeights = nil
        diskEstimates = diskCache
        // Pin disk first so rebuild never walks plain boundingRect / parse for known rows.
        bootstrapCommittedFromDisk(messages: messages)
        rebuildDisplayHeights(
            messages: messages,
            layoutWidth: layoutWidth,
            layoutProbeTailRows: layoutProbeTailRows
        )
    }

    /// Trust persisted column heights so first scroll uses native geometry (no plain pass).
    func bootstrapCommittedFromDisk(messages: [ChatMessage]) {
        for message in messages {
            guard !committedIDs.contains(message.id),
                  let disk = diskEstimates[message.id], disk > 40 else { continue }
            committedColumnHeights[message.id] = disk
            committedIDs.insert(message.id)
            displayColumnHeights[message.id] = disk
        }
    }

    func rebuildDisplayHeights(messages: [ChatMessage],
                               layoutWidth: CGFloat,
                               throughRow: Int? = nil,
                               layoutProbeTailRows: Int? = nil) {
        displayColumnHeights.removeAll()
        guard !messages.isEmpty else { return }
        let count = messages.count
        // Cold long threads: only probe native layout cache near the tail — head rows use disk/cheap.
        let probeTailRows = layoutProbeTailRows.map { min(count, max(1, $0)) } ?? min(count, 36)
        let tailProbeStart = max(0, count - probeTailRows)
        let jumpProbeEnd = throughRow.map { min($0, count - 1) }
        displayColumnHeights.reserveCapacity(count)
        for (row, message) in messages.enumerated() {
            let probeFullLayout = row >= tailProbeStart
                || jumpProbeEnd.map { row <= $0 } == true
            if probeFullLayout {
                displayColumnHeights[message.id] = resolveDisplayColumnHeight(
                    for: message,
                    row: row,
                    messageCount: count,
                    layoutWidth: layoutWidth
                )
            } else {
                displayColumnHeights[message.id] = resolveFastDisplayColumnHeight(
                    for: message,
                    layoutWidth: layoutWidth
                )
            }
        }
    }

    /// Switch hot path for history rows — never walks layout cache.
    private func resolveFastDisplayColumnHeight(for message: ChatMessage,
                                                layoutWidth: CGFloat) -> CGFloat {
        if committedIDs.contains(message.id),
           let column = committedColumnHeights[message.id], column > 40 {
            return column
        }
        if let disk = diskEstimates[message.id], disk > 40 {
            return disk
        }
        if message.role == .user {
            // This path runs for every history row while switching. Exact text
            // measurement is reserved for the visible tail; a character-based
            // estimate avoids hundreds of CoreText layouts on a long thread.
            return Self.fastUserColumnEstimate(for: message, layoutWidth: layoutWidth)
        }
        return max(Self.cheapColumnEstimate(for: message, layoutWidth: layoutWidth), 44)
    }

    func exportPersistable() -> [String: CGFloat] {
        var out = diskEstimates
        for (id, h) in committedColumnHeights where h > 40 {
            out[id] = h
        }
        return out
    }

    // MARK: - Committed measure

    func isCommitted(_ messageID: String) -> Bool {
        committedIDs.contains(messageID)
    }

    func committedColumnHeight(for messageID: String) -> CGFloat? {
        committedColumnHeights[messageID]
    }

    func bestKnownColumnHeight(for messageID: String) -> CGFloat {
        if let committed = committedColumnHeights[messageID] { return committed }
        if let display = displayColumnHeights[messageID] { return display }
        return diskEstimates[messageID] ?? 0
    }

    func displayColumnHeight(for messageID: String) -> CGFloat? {
        if let display = displayColumnHeights[messageID], display > 40 { return display }
        if let committed = committedColumnHeights[messageID], committed > 40 { return committed }
        return nil
    }

    func commit(columnHeight: CGFloat, messageID: String) {
        commitMeasured(columnHeight: columnHeight, messageID: messageID, allowShrink: false)
    }

    func commitMeasured(columnHeight: CGFloat, messageID: String, allowShrink: Bool = true) {
        guard columnHeight > 40 else { return }
        let prior = bestKnownColumnHeight(for: messageID)
        let stored: CGFloat
        if allowShrink || prior == 0 {
            stored = columnHeight
        } else {
            stored = max(prior, columnHeight)
        }
        committedColumnHeights[messageID] = stored
        committedIDs.insert(messageID)
        diskEstimates.removeValue(forKey: messageID)
        // Do not mutate live geometry mid-gesture — freeze map owns heightForRowAt.
        if scrollFrozenRowHeights == nil {
            displayColumnHeights[messageID] = stored
        }
    }

    func recordDiskEstimate(columnHeight: CGFloat, messageID: String) {
        guard columnHeight > 40, !committedIDs.contains(messageID) else { return }
        diskEstimates[messageID] = max(diskEstimates[messageID] ?? 0, columnHeight)
    }

    func updateDisplayEstimate(columnHeight: CGFloat, messageID: String) {
        guard columnHeight > 40 else { return }
        guard scrollFrozenRowHeights == nil else { return }
        if committedIDs.contains(messageID) {
            displayColumnHeights[messageID] = committedColumnHeights[messageID] ?? columnHeight
            return
        }
        displayColumnHeights[messageID] = columnHeight
    }

    /// After scroll freeze ends, push committed heights into the display map.
    func publishCommittedToDisplay() {
        for (id, height) in committedColumnHeights where height > 40 {
            displayColumnHeights[id] = height
        }
    }

    func invalidate(messageID: String) {
        committedColumnHeights.removeValue(forKey: messageID)
        committedIDs.remove(messageID)
        diskEstimates.removeValue(forKey: messageID)
        displayColumnHeights.removeValue(forKey: messageID)
    }

    func invalidateCommittedOnly(messageID: String) {
        committedColumnHeights.removeValue(forKey: messageID)
        committedIDs.remove(messageID)
    }

    // MARK: - Row height (read display map only — stable while scrolling)

    func rowHeight(for message: ChatMessage,
                   row: Int,
                   messageCount: Int,
                   layoutWidth: CGFloat) -> CGFloat {
        if let frozenMap = scrollFrozenRowHeights,
           let frozen = frozenMap[message.id], frozen > 40 {
            return frozen
        }
        return unfrozenRowHeight(
            for: message,
            row: row,
            messageCount: messageCount,
            layoutWidth: layoutWidth
        )
    }

    private func unfrozenRowHeight(for message: ChatMessage,
                                   row: Int,
                                   messageCount: Int,
                                   layoutWidth: CGFloat) -> CGFloat {
        if let display = displayColumnHeights[message.id], display > 40 {
            return display + Self.cellVerticalMargin
        }
        let fallback = resolveDisplayColumnHeight(
            for: message,
            row: row,
            messageCount: messageCount,
            layoutWidth: layoutWidth
        )
        if scrollFrozenRowHeights == nil {
            displayColumnHeights[message.id] = fallback
        }
        return fallback + Self.cellVerticalMargin
    }

    /// Height authority: committed → layout-cache estimate → cheap char estimate.
    /// Avoid plain boundingRect / parse during full-table rebuild (open-path hot).
    private func resolveDisplayColumnHeight(for message: ChatMessage,
                                            row: Int,
                                            messageCount: Int,
                                            layoutWidth: CGFloat) -> CGFloat {
        if committedIDs.contains(message.id),
           let column = committedColumnHeights[message.id], column > 40 {
            return column
        }
        if let disk = diskEstimates[message.id], disk > 40 {
            return disk
        }
        if message.role == .user,
           let column = Self.estimatedUserColumnContentHeight(for: message, layoutWidth: layoutWidth),
           column > 40 {
            return column
        }
        if message.role == .assistant, !message.isStreaming,
           AssistantMessageLayout.hasCachedNativeLayout(for: message, layoutWidth: layoutWidth),
           let column = AssistantMessageLayout.estimatedColumnContentHeight(
               for: message,
               layoutWidth: layoutWidth,
               isLastRow: row == messageCount - 1,
               allowSyncLayout: false
           ), column > 40 {
            return column
        }
        return max(Self.cheapColumnEstimate(for: message, layoutWidth: layoutWidth), 44)
    }

    /// Sync-layout assistant rows on open — tail first, then disk-hinted, up to `syncLimit`.
    func seedAllLayoutEstimatesIfNeeded(messages: [ChatMessage],
                                        layoutWidth: CGFloat,
                                        tailRowCount: Int = 24,
                                        syncLimit: Int = 12) {
        guard !messages.isEmpty else { return }
        let count = messages.count
        var ordered: [(row: Int, message: ChatMessage)] = []
        var seen = Set<String>()
        let tailStart = max(0, count - max(1, tailRowCount))
        for row in tailStart..<count {
            let message = messages[row]
            guard message.role == .assistant, !message.isStreaming else { continue }
            guard !committedIDs.contains(message.id), seen.insert(message.id).inserted else { continue }
            ordered.append((row, message))
        }
        for (row, message) in messages.enumerated() {
            guard message.role == .assistant, !message.isStreaming else { continue }
            guard diskEstimates[message.id] != nil else { continue }
            guard !committedIDs.contains(message.id), seen.insert(message.id).inserted else { continue }
            ordered.append((row, message))
        }
        for (row, message) in messages.enumerated() {
            guard message.role == .assistant, !message.isStreaming else { continue }
            guard !committedIDs.contains(message.id), seen.insert(message.id).inserted else { continue }
            ordered.append((row, message))
        }
        guard !ordered.isEmpty else { return }
        for entry in ordered.prefix(max(1, syncLimit)) {
            guard let column = AssistantMessageLayout.estimatedColumnContentHeight(
                for: entry.message,
                layoutWidth: layoutWidth,
                isLastRow: entry.row == count - 1,
                allowSyncLayout: true
            ), column > 40 else { continue }
            updateDisplayEstimate(columnHeight: column, messageID: entry.message.id)
        }
    }

    /// Sync-layout tail rows missing native cache (open path only).
    func seedTailLayoutEstimatesIfNeeded(messages: [ChatMessage],
                                         layoutWidth: CGFloat,
                                         tailRowCount: Int = 12,
                                         syncLimit: Int = 3) {
        guard !messages.isEmpty else { return }
        let start = max(0, messages.count - max(1, tailRowCount))
        var missing: [(row: Int, message: ChatMessage)] = []
        for row in start..<messages.count {
            let message = messages[row]
            guard message.role == .assistant, !message.isStreaming else { continue }
            if committedIDs.contains(message.id) { continue }
            if AssistantMessageLayout.hasCachedNativeLayout(for: message, layoutWidth: layoutWidth) {
                continue
            }
            missing.append((row, message))
        }
        guard !missing.isEmpty else { return }
        for entry in missing.suffix(max(1, syncLimit)) {
            guard let column = AssistantMessageLayout.estimatedColumnContentHeight(
                for: entry.message,
                layoutWidth: layoutWidth,
                isLastRow: entry.row == messages.count - 1,
                allowSyncLayout: true
            ), column > 40 else { continue }
            updateDisplayEstimate(columnHeight: column, messageID: entry.message.id)
        }
    }

    func totalRowHeight(for messages: [ChatMessage], layoutWidth: CGFloat) -> CGFloat {
        guard !messages.isEmpty else { return 0 }
        let count = messages.count
        return messages.enumerated().reduce(into: CGFloat(0)) { sum, item in
            sum += rowHeight(
                for: item.element,
                row: item.offset,
                messageCount: count,
                layoutWidth: layoutWidth
            )
        }
    }

    func scrollOffsetYToBottom(messages: [ChatMessage],
                               layoutWidth: CGFloat,
                               contentInsetTop: CGFloat,
                               contentInsetBottom: CGFloat,
                               viewportHeight: CGFloat) -> CGFloat {
        let content = totalRowHeight(for: messages, layoutWidth: layoutWidth)
        let minY = -contentInsetTop
        let maxY = max(minY, content + contentInsetBottom - viewportHeight)
        return maxY
    }

    // MARK: - Cheap fallback (char-based; last resort)

    static func estimatedUserColumnContentHeight(for message: ChatMessage,
                                                 layoutWidth: CGFloat) -> CGFloat? {
        guard message.role == .user else { return nil }
        // layoutWidth is already bubble/content width from ChatVC.
        let columnWidth = min(DSTheme.bubbleMaxWidth, max(layoutWidth, 120))
        let labelWidth = max(columnWidth - 124, 80)
        let font = UIFont.systemFont(ofSize: SettingsManager.shared.chatBodyFontSize)
        var total: CGFloat = 0
        if message.hasImage {
            total += 8 + 160 + 10
        }
        let text = message.content.isEmpty && message.hasImage ? "" : message.content
        if !text.isEmpty {
            let textHeight = ceil(
                (text as NSString).boundingRect(
                    with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            total += 8 + 10 + textHeight + 10
        } else if message.hasImage {
            total += 8
        } else {
            total += 8 + 10 + font.lineHeight + 10
        }
        return max(total, 44)
    }

    /// Constant-time user-row estimate for offscreen conversation history.
    private static func fastUserColumnEstimate(for message: ChatMessage,
                                               layoutWidth: CGFloat) -> CGFloat {
        let columnWidth = min(DSTheme.bubbleMaxWidth, max(layoutWidth, 120))
        let labelWidth = max(columnWidth - 124, 80)
        let font = UIFont.systemFont(ofSize: SettingsManager.shared.chatBodyFontSize)
        let averageGlyphWidth = max(font.pointSize * 0.56, 6)
        let charactersPerLine = max(Int(labelWidth / averageGlyphWidth), 1)
        let text = message.content.isEmpty && message.hasImage ? "" : message.content
        var total: CGFloat = 0

        if message.hasImage {
            total += 8 + 160 + 10
        }
        if !text.isEmpty {
            let explicitLines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let wrappedLines = max(1, Int(ceil(CGFloat(text.count) / CGFloat(charactersPerLine))))
            total += 8 + 10 + CGFloat(max(explicitLines, wrappedLines)) * font.lineHeight + 10
        } else if message.hasImage {
            total += 8
        } else {
            total += 8 + 10 + font.lineHeight + 10
        }
        return max(total, 44)
    }

    static func cheapColumnEstimate(for msg: ChatMessage, layoutWidth: CGFloat) -> CGFloat {
        if msg.role == .user {
            return estimatedUserColumnContentHeight(for: msg, layoutWidth: layoutWidth) ?? 64
        }
        let reasoningExpanded = msg.hasReasoning
            && AssistantMessageLayout.isThinkingExpanded(messageID: msg.id)
        let reasoningChars = reasoningExpanded
            ? msg.reasoningContent.count
            : (msg.reasoningContent.isEmpty ? 0 : 40)
        let chars = max(msg.content.count, reasoningChars)
        let lines = max(1, chars / 48)
        var rough = CGFloat(36 + lines * 18)
        let displayMathBlocks = msg.content.components(separatedBy: "$$").count / 2
        if displayMathBlocks > 0 {
            rough += CGFloat(displayMathBlocks) * 52
        }
        if msg.hasImage { rough += 168 }
        if msg.hasReasoning {
            rough += reasoningExpanded
                ? CGFloat(28 + max(1, msg.reasoningContent.count / 48) * 16) : 36
        }
        if msg.hasSearchProcess || msg.hasImageTranscription { rough += 36 }
        if msg.role == .assistant && !msg.isStreaming {
            rough += 4 + AssistantMessageLayout.actionRowHeight
        }
        if msg.hasReasoning || msg.hasSearchProcess || msg.hasImageTranscription {
            return min(max(rough, 64), 720)
        }
        return min(max(rough, 64), 4_000)
    }
}
