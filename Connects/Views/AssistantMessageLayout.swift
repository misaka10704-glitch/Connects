import UIKit

/// Static layout prewarm and height estimation for assistant rows.
enum AssistantMessageLayout {
    /// Visible action row height in `AssistantMessageCell` — must match cell layout.
    static let actionRowHeight: CGFloat = 28
    static let actionRowReservedHeight: CGFloat = actionRowHeight

    private static var expandedThinkingIDs = Set<String>()
    private static var expandedSearchIDs = Set<String>()

    static func isThinkingExpanded(messageID: String) -> Bool {
        expandedThinkingIDs.contains(messageID)
    }

    static func isSearchExpanded(messageID: String) -> Bool {
        expandedSearchIDs.contains(messageID)
    }

    static func expandedChromeMessageIDs() -> Set<String> {
        expandedThinkingIDs.union(expandedSearchIDs)
    }

    static func setThinkingExpanded(_ expanded: Bool, messageID: String) {
        if expanded { expandedThinkingIDs.insert(messageID) }
        else { expandedThinkingIDs.remove(messageID) }
    }

    static func setSearchExpanded(_ expanded: Bool, messageID: String) {
        if expanded { expandedSearchIDs.insert(messageID) }
        else { expandedSearchIDs.remove(messageID) }
    }

    static func prewarmSnapshots(for messages: [ChatMessage],
                                 targetWidth: CGFloat? = nil,
                                 parseLimit: Int = 4) {
        let width = nativeLayoutWidth(for: max(targetWidth ?? DSTheme.bubbleMaxWidth, 120))
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: SettingsManager.shared.chatBodyFontSize,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: DSTheme.c
        )
        let limit = max(1, parseLimit)
        for message in messages.suffix(limit)
            where message.role == .assistant &&
                  !message.isStreaming {
            _ = NativeMarkdownParser.shared.parse(message.content)
        }
        _ = style
    }

    static func prewarmLayouts(for messages: [ChatMessage],
                               targetWidth: CGFloat? = nil,
                               layoutLimit: Int = 12) {
        let width = nativeLayoutWidth(for: max(targetWidth ?? DSTheme.bubbleMaxWidth, 120))
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: SettingsManager.shared.chatBodyFontSize,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: DSTheme.c
        )
        let limit = max(1, layoutLimit)
        for message in messages.suffix(limit)
            where message.role == .assistant &&
                  !message.isStreaming {
            let document = NativeMarkdownParser.shared.parse(message.content)
            if NativeMessageLayouter.shared.cachedLayout(document: document, style: style) == nil {
                _ = NativeMessageLayouter.shared.layout(document: document, style: style)
            }
        }
    }

    /// Prewarm the last N Q&A turn-pairs before painting a conversation (switch path).
    static func prewarmSwitchTail(messages: [ChatMessage],
                                  layoutWidth: CGFloat,
                                  turnPairLimit: Int = 5) {
        guard !messages.isEmpty else { return }
        var userRows: [Int] = []
        for (index, msg) in messages.enumerated() where msg.role == .user {
            userRows.append(index)
        }
        let tailUsers = userRows.suffix(max(1, turnPairLimit))
        var assistants: [ChatMessage] = []
        for userRow in tailUsers {
            let assistantRow = userRow + 1
            guard assistantRow < messages.count else { continue }
            let assistant = messages[assistantRow]
            guard assistant.role == .assistant, !assistant.isStreaming else { continue }
            assistants.append(assistant)
        }
        guard !assistants.isEmpty else { return }
        prewarmLayouts(for: assistants, targetWidth: layoutWidth, layoutLimit: assistants.count)
    }

    /// `layoutWidth` from ChatVC is already bubble/content width (`currentRenderWidth`).
    /// Clamp only — do not subtract horizontal chrome again.
    static func nativeLayoutWidth(for layoutWidth: CGFloat) -> CGFloat {
        min(DSTheme.bubbleMaxWidth, max(layoutWidth, 120))
    }

    static func hasCachedNativeLayout(for message: ChatMessage, layoutWidth: CGFloat) -> Bool {
        guard message.role == .assistant, !message.isStreaming, !message.content.isEmpty else {
            return false
        }
        let width = nativeLayoutWidth(for: max(layoutWidth, 120))
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: SettingsManager.shared.chatBodyFontSize,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: DSTheme.c
        )
        return NativeMessageLayouter.shared.hasCachedLayout(forContent: message.content, style: style)
    }

    static func prewarmTurnWindow(messages: [ChatMessage],
                                  userTurnRows: [Int],
                                  targetWidth: CGFloat) {
        var assistants: [ChatMessage] = []
        for userRow in userTurnRows {
            let assistantRow = userRow + 1
            guard assistantRow < messages.count else { continue }
            let msg = messages[assistantRow]
            guard msg.role == .assistant, !msg.isStreaming else { continue }
            assistants.append(msg)
        }
        guard !assistants.isEmpty else { return }
        prewarmLayouts(for: assistants, targetWidth: targetWidth, layoutLimit: assistants.count)
    }

    static func seedableContentHeight(for message: ChatMessage,
                                      layoutWidth: CGFloat,
                                      reserveActionRow: Bool,
                                      allowSyncLayout: Bool) -> CGFloat? {
        guard message.role == .assistant, !message.isStreaming else { return nil }

        let width = nativeLayoutWidth(for: max(layoutWidth, 120))
        let font = SettingsManager.shared.chatBodyFontSize
        let colors = DSTheme.c
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: font,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: colors
        )

        var bodyHeight: CGFloat = 0
        if message.content.isEmpty {
            return nil
        }
        let document = NativeMarkdownParser.shared.parse(message.content)
        if let cached = NativeMessageLayouter.shared.cachedLayout(document: document, style: style) {
            bodyHeight = cached.size.height
        } else if allowSyncLayout {
            let layout = NativeMessageLayouter.shared.layout(document: document, style: style)
            bodyHeight = layout.size.height
        } else {
            return nil
        }
        guard bodyHeight > 0 else { return nil }
        _ = reserveActionRow
        return bodyHeight
    }

    static func estimatedColumnContentHeight(for message: ChatMessage,
                                             layoutWidth: CGFloat,
                                             isLastRow: Bool,
                                             allowSyncLayout: Bool = false) -> CGFloat? {
        guard message.role == .assistant, !message.isStreaming else { return nil }
        var total: CGFloat = 0

        if message.hasSearchProcess || message.hasImageTranscription {
            let expanded = expandedSearchIDs.contains(message.id)
            let searchText = message.hasImageTranscription
                ? message.imageTranscriptionContent
                : message.searchProcessContent
            total += expanded
                ? 36 + CGFloat(max(1, searchText.count / 48)) * 16
                : 36
        }

        let reasoning = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reasoning.isEmpty {
            let expanded = expandedThinkingIDs.contains(message.id)
            total += expanded
                ? 28 + CGFloat(max(1, reasoning.count / 48)) * 16
                : 36
        }

        if message.hasImage {
            total += 168
        }

        if let body = seedableContentHeight(
            for: message,
            layoutWidth: layoutWidth,
            reserveActionRow: false,
            allowSyncLayout: allowSyncLayout
        ), body > 0 {
            total += body
        } else if !message.content.isEmpty {
            let lines = max(1, message.content.count / 48)
            total += CGFloat(36 + lines * 18)
        }

        let showActions = !message.content.isEmpty
            || !reasoning.isEmpty
            || message.hasSearchProcess
            || message.hasImageTranscription
        if showActions {
            total += actionRowHeight
        }

        guard total > 40 else { return nil }
        _ = isLastRow
        return total
    }

    /// Height while an assistant row shows plain `assistantLabel` fallback (no native layout cache).
    /// Must match `AssistantMessageCell.configurePlainFallback` — used during scroll so row
    /// height equals visible content (prevents scrolling through invisible padding).
    static func plainFallbackColumnContentHeight(for message: ChatMessage,
                                                 layoutWidth: CGFloat) -> CGFloat? {
        guard message.role == .assistant, !message.isStreaming else { return nil }
        var total: CGFloat = 0

        if message.hasSearchProcess || message.hasImageTranscription {
            let expanded = expandedSearchIDs.contains(message.id)
            let searchText = message.hasImageTranscription
                ? message.imageTranscriptionContent
                : message.searchProcessContent
            total += expanded
                ? 36 + CGFloat(max(1, searchText.count / 48)) * 16
                : 36
        }

        let reasoning = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reasoning.isEmpty {
            let expanded = expandedThinkingIDs.contains(message.id)
            total += expanded
                ? 28 + CGFloat(max(1, reasoning.count / 48)) * 16
                : 36
        }

        if message.hasImage {
            total += 168
        }

        let width = nativeLayoutWidth(for: max(layoutWidth, 120))
        let font = UIFont.systemFont(ofSize: SettingsManager.shared.chatBodyFontSize)
        let content = message.content
        if !content.isEmpty {
            let textHeight = ceil(
                (content as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            let bodyTop: CGFloat = (total > 0 || message.hasImage) ? 10 : 8
            total += bodyTop + textHeight
        }

        let showActions = !message.content.isEmpty
            || !reasoning.isEmpty
            || message.hasSearchProcess
            || message.hasImageTranscription
        if showActions {
            total += 4 + actionRowHeight
        }

        guard total > 40 else { return nil }
        return total
    }
}
