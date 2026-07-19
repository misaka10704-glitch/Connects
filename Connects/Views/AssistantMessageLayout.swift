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

    /// Serial queue for markdown parse + layout warm (Chatto-style off-main sizing).
    static let layoutPrewarmQueue = DispatchQueue(label: "com.connects.layout.prewarm", qos: .userInitiated)
    private static let switchPrewarmGenerationLock = NSLock()
    private static var _switchPrewarmGeneration: UInt = 0

    static var switchPrewarmGeneration: UInt {
        switchPrewarmGenerationLock.lock()
        defer { switchPrewarmGenerationLock.unlock() }
        return _switchPrewarmGeneration
    }

    @discardableResult
    static func bumpSwitchPrewarmGeneration() -> UInt {
        switchPrewarmGenerationLock.lock()
        defer { switchPrewarmGenerationLock.unlock() }
        _switchPrewarmGeneration &+= 1
        return _switchPrewarmGeneration
    }

    static func isSwitchPrewarmGeneration(_ generation: UInt) -> Bool {
        switchPrewarmGenerationLock.lock()
        defer { switchPrewarmGenerationLock.unlock() }
        return generation == _switchPrewarmGeneration
    }

    /// Prewarm the last N Q&A turn-pairs before painting a conversation (switch path).
    static func prewarmSwitchTail(messages: [ChatMessage],
                                  layoutWidth: CGFloat,
                                  turnPairLimit: Int = 5) {
        let assistants = switchTailAssistants(messages: messages, turnPairLimit: turnPairLimit)
        guard !assistants.isEmpty else { return }
        prewarmLayouts(for: assistants, targetWidth: layoutWidth, layoutLimit: assistants.count)
    }

    /// Parse + layout on `layoutPrewarmQueue`. Preview layout when formulas are not cached yet.
    static func prewarmLayoutsOnBackground(for messages: [ChatMessage],
                                           targetWidth: CGFloat,
                                           layoutLimit: Int,
                                           generation: UInt? = nil,
                                           completion: (() -> Void)? = nil) {
        let batch = Array(messages.suffix(max(1, layoutLimit)))
        guard !batch.isEmpty else {
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        layoutPrewarmQueue.async {
            if let generation = generation, !isSwitchPrewarmGeneration(generation) { return }
            let width = nativeLayoutWidth(for: max(targetWidth, 120))
            let style = NativeLayoutStyle(
                width: width,
                bodyFontSize: SettingsManager.shared.chatBodyFontSize,
                appearance: SettingsManager.shared.appearanceMode.rawValue,
                colors: DSTheme.c
            )
            for message in batch where message.role == .assistant && !message.isStreaming {
                autoreleasepool {
                    let document = NativeMarkdownParser.shared.parse(message.content)
                    if NativeMessageLayouter.shared.cachedLayout(document: document, style: style) == nil {
                        if formulasReady(in: document, style: style) {
                            _ = NativeMessageLayouter.shared.layout(document: document, style: style)
                        } else {
                            _ = NativeMessageLayouter.shared.layout(
                                document: document,
                                style: style,
                                renderMissingFormulas: false
                            )
                        }
                    }
                }
            }
            if let completion = completion {
                DispatchQueue.main.async {
                    if let generation = generation, !isSwitchPrewarmGeneration(generation) { return }
                    completion()
                }
            }
        }
    }

    /// Background parse + layout for the switch tail — safe to call before `reloadChat`.
    static func prewarmSwitchTailOnBackground(messages: [ChatMessage],
                                              layoutWidth: CGFloat,
                                              turnPairLimit: Int = 4,
                                              generation: UInt? = nil,
                                              completion: (() -> Void)? = nil) {
        let assistants = switchTailAssistants(messages: messages, turnPairLimit: turnPairLimit)
        guard !assistants.isEmpty else {
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        prewarmLayoutsOnBackground(
            for: assistants,
            targetWidth: layoutWidth,
            layoutLimit: assistants.count,
            generation: generation,
            completion: completion
        )
    }

    static func switchTailAssistants(messages: [ChatMessage],
                                     turnPairLimit: Int) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        let limit = max(1, turnPairLimit)
        var assistants: [ChatMessage] = []
        assistants.reserveCapacity(limit)
        var inspectedTurns = 0

        // Switches only need the tail. Scanning backwards avoids walking every
        // row in a long transcript just to find the newest few turn pairs.
        for userRow in messages.indices.reversed() where messages[userRow].role == .user {
            inspectedTurns += 1
            let assistantRow = userRow + 1
            if assistantRow < messages.count {
                let assistant = messages[assistantRow]
                if assistant.role == .assistant, !assistant.isStreaming {
                    assistants.append(assistant)
                }
            }
            if inspectedTurns == limit { break }
        }
        return assistants.reversed()
    }

    private static func formulasReady(in document: NativeMarkdownDocument,
                                      style: NativeLayoutStyle) -> Bool {
        var formulas = [(String, Bool)]()
        func scan(_ inlines: [NativeInline]) {
            for inline in inlines {
                switch inline {
                case .inlineMath(let tex):
                    formulas.append((tex, false))
                case .bold(let children), .italic(let children), .link(let children, _):
                    scan(children)
                default:
                    break
                }
            }
        }
        for block in document.blocks {
            switch block {
            case .displayMath(let tex):
                formulas.append((tex, true))
            case .paragraph(let inlines), .heading(_, let inlines), .blockquote(let inlines):
                scan(inlines)
            case .list(_, let items):
                items.forEach(scan)
            case .table(let table):
                table.header.forEach(scan)
                table.rows.flatMap { $0 }.forEach(scan)
            default:
                break
            }
        }
        guard !formulas.isEmpty else { return true }
        return formulas.allSatisfy { tex, display in
            NativeFormulaRenderer.shared.hasMemoryArtifact(
                tex: tex,
                fontSize: style.bodyFontSize * (display ? 1.08 : 1),
                color: style.colors.textPrimary,
                display: display
            ) || NativeFormulaRenderer.shared.hasCachedArtifact(
                tex: tex,
                fontSize: style.bodyFontSize * (display ? 1.08 : 1),
                color: style.colors.textPrimary,
                display: display
            )
        }
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
        // Called from `cellForRowAt` while scrolling. Never parse here: a
        // cache miss must remain constant-time and use the plain fallback.
        guard let document = NativeMarkdownParser.shared.cachedDocument(message.content) else {
            return false
        }
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: SettingsManager.shared.chatBodyFontSize,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: DSTheme.c
        )
        return NativeMessageLayouter.shared.cachedLayout(document: document, style: style) != nil
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

    private static func resolvedSearchChromeText(for message: ChatMessage,
                                                 pairedUser: ChatMessage?) -> String {
        if message.hasImageTranscription {
            return message.imageTranscriptionDisplayText(pairedUser: pairedUser)
        }
        return message.searchProcessContent
    }

    private static func searchChromeHeight(for message: ChatMessage,
                                           layoutWidth: CGFloat,
                                           pairedUser: ChatMessage?) -> CGFloat {
        guard message.hasSearchProcess || message.hasImageTranscription else { return 0 }
        let expanded = expandedSearchIDs.contains(message.id)
        if !expanded { return 36 }
        let text = resolvedSearchChromeText(for: message, pairedUser: pairedUser)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 36 }
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        let font = UIFont.systemFont(ofSize: thinkFont)
        let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
        let bodyH = ceil(
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height
        )
        return 32 + 4 + bodyH + 10
    }

    static func estimatedColumnContentHeight(for message: ChatMessage,
                                             layoutWidth: CGFloat,
                                             isLastRow: Bool,
                                             allowSyncLayout: Bool = false,
                                             pairedUser: ChatMessage? = nil) -> CGFloat? {
        guard message.role == .assistant, !message.isStreaming else { return nil }
        var total: CGFloat = 0

        if message.hasSearchProcess || message.hasImageTranscription {
            total += searchChromeHeight(
                for: message,
                layoutWidth: layoutWidth,
                pairedUser: pairedUser
            )
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
                                                 layoutWidth: CGFloat,
                                                 pairedUser: ChatMessage? = nil) -> CGFloat? {
        guard message.role == .assistant, !message.isStreaming else { return nil }
        var total: CGFloat = 0

        if message.hasSearchProcess || message.hasImageTranscription {
            total += searchChromeHeight(
                for: message,
                layoutWidth: layoutWidth,
                pairedUser: pairedUser
            )
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
