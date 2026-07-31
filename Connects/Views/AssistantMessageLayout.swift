import UIKit

/// Static layout prewarm and height estimation for assistant rows.
enum AssistantMessageLayout {
    /// Visible action row height in `AssistantMessageCell` — must match cell layout.
    static let actionRowHeight: CGFloat = 28
    static let actionRowReservedHeight: CGFloat = actionRowHeight

    private static var expandedThinkingIDs = Set<String>()
    private static var expandedSearchIDs = Set<String>()
    /// `(messageID|width|utf8Count)` → measured thinking body height.
    private static var thinkingBodyHeightCache = [String: CGFloat]()
    /// `(messageID|width|utf8Count)` → measured search / transcription body height.
    private static var searchBodyHeightCache = [String: CGFloat]()
    private static let thinkingMeasureCapChars = 4_000
    private static let searchMeasureCapChars = 4_000
    private static let thinkingHeightSoftCap: CGFloat = 2_400
    private static let searchHeightSoftCap: CGFloat = 2_400

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
            _ = NativeMarkdownParser.shared.parse(message.chatDisplayBody)
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
            let document = NativeMarkdownParser.shared.parse(message.chatDisplayBody)
            if NativeMessageLayouter.shared.cachedLayout(document: document, style: style) == nil {
                _ = NativeMessageLayouter.shared.layout(document: document, style: style)
            }
        }
    }

    /// Count of ``` markers (fence-dense rows score high).
    static func codeFenceMarkerCount(in body: String) -> Int {
        guard !body.isEmpty else { return 0 }
        var count = 0
        var search = body.startIndex
        while let range = body.range(of: "```", range: search..<body.endIndex) {
            count += 1
            search = range.upperBound
        }
        return count
    }

    /// Prefer fence-heavy assistants so scroll-freeze binds from cache instead of blank shells.
    static func prewarmFenceHeavyLayouts(for messages: [ChatMessage],
                                         targetWidth: CGFloat,
                                         layoutLimit: Int = 32) {
        let assistants = messages.filter { $0.role == .assistant && !$0.isStreaming && !$0.chatDisplayBody.isEmpty }
        guard !assistants.isEmpty else { return }
        let ranked = assistants.sorted {
            codeFenceMarkerCount(in: $0.chatDisplayBody) > codeFenceMarkerCount(in: $1.chatDisplayBody)
        }
        let limit = min(max(1, layoutLimit), ranked.count)
        prewarmLayouts(for: Array(ranked.prefix(limit)), targetWidth: targetWidth, layoutLimit: limit)
    }

    /// Rematerialize one message after body rewrite (CONNECTS_EDIT strip / regen).
    static func rematerializeLayout(for message: ChatMessage, layoutWidth: CGFloat) {
        guard message.role == .assistant, !message.isStreaming else { return }
        let width = nativeLayoutWidth(for: max(layoutWidth, 120))
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: SettingsManager.shared.chatBodyFontSize,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: DSTheme.c
        )
        let document = NativeMarkdownParser.shared.parse(message.chatDisplayBody)
        _ = NativeMessageLayouter.shared.layout(document: document, style: style)
    }

    /// One sync parse + layout for the open tail — preview when formulas are still warming.
    @discardableResult
    static func prewarmOpenTailLayoutSync(for message: ChatMessage, layoutWidth: CGFloat) -> Bool {
        guard message.role == .assistant, !message.isStreaming, !message.chatDisplayBody.isEmpty else {
            return false
        }
        let width = nativeLayoutWidth(for: max(layoutWidth, 120))
        let style = NativeLayoutStyle(
            width: width,
            bodyFontSize: SettingsManager.shared.chatBodyFontSize,
            appearance: SettingsManager.shared.appearanceMode.rawValue,
            colors: DSTheme.c
        )
        let document = NativeMarkdownParser.shared.parse(message.chatDisplayBody)
        if NativeMessageLayouter.shared.cachedLayout(document: document, style: style) != nil {
            return true
        }
        let renderFormulas = formulasReady(in: document, style: style)
        _ = NativeMessageLayouter.shared.layout(
            document: document,
            style: style,
            renderMissingFormulas: renderFormulas
        )
        return NativeMessageLayouter.shared.cachedLayout(document: document, style: style) != nil
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
                    let document = NativeMarkdownParser.shared.parse(message.chatDisplayBody)
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
        guard message.role == .assistant, !message.isStreaming, !message.chatDisplayBody.isEmpty else {
            return false
        }
        let width = nativeLayoutWidth(for: max(layoutWidth, 120))
        // Called from `cellForRowAt` while scrolling. Never parse here: a
        // cache miss must remain constant-time.
        guard let document = NativeMarkdownParser.shared.cachedDocument(message.chatDisplayBody) else {
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
        if message.chatDisplayBody.isEmpty {
            return nil
        }
        let document = NativeMarkdownParser.shared.parse(message.chatDisplayBody)
        if let cached = NativeMessageLayouter.shared.cachedLayout(document: document, style: style) {
            bodyHeight = cached.size.height
        } else if allowSyncLayout {
            let renderFormulas = formulasReady(in: document, style: style)
            let layout = NativeMessageLayouter.shared.layout(
                document: document,
                style: style,
                renderMissingFormulas: renderFormulas
            )
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
        return 40
    }

    private static func chromeHeightCacheKey(messageID: String, width: CGFloat, utf8Count: Int) -> String {
        "\(messageID)|\(Int(width))|\(utf8Count)"
    }

    private static func thinkingHeightCacheKey(messageID: String, width: CGFloat, utf8Count: Int) -> String {
        chromeHeightCacheKey(messageID: messageID, width: width, utf8Count: utf8Count)
    }

    static func storeSearchBodyHeight(_ height: CGFloat,
                                      messageID: String,
                                      layoutWidth: CGFloat,
                                      utf8Count: Int) {
        guard !messageID.isEmpty, height > 0 else { return }
        let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
        searchBodyHeightCache[chromeHeightCacheKey(
            messageID: messageID,
            width: width,
            utf8Count: utf8Count
        )] = height
    }

    static func lookupSearchBodyHeight(messageID: String,
                                       layoutWidth: CGFloat,
                                       utf8Count: Int) -> CGFloat? {
        guard !messageID.isEmpty else { return nil }
        let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
        return searchBodyHeightCache[chromeHeightCacheKey(
            messageID: messageID,
            width: width,
            utf8Count: utf8Count
        )]
    }

    static func resolvedSearchBodyHeight(text: String,
                                         messageID: String,
                                         layoutWidth: CGFloat) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 16 }
        let utf8Count = trimmed.utf8.count
        if let cached = lookupSearchBodyHeight(
            messageID: messageID,
            layoutWidth: layoutWidth,
            utf8Count: utf8Count
        ), cached > 0 {
            return cached
        }
        return estimatedSearchBodyHeight(
            text: trimmed,
            layoutWidth: layoutWidth,
            messageID: messageID
        )
    }

    static func searchExpandHeightDelta(text: String,
                                        messageID: String,
                                        layoutWidth: CGFloat) -> CGFloat {
        14 + resolvedSearchBodyHeight(
            text: text,
            messageID: messageID,
            layoutWidth: layoutWidth
        )
    }

    static func measureSearchBodyHeightOnBackground(text: String,
                                                    fontSize: CGFloat,
                                                    layoutWidth: CGFloat,
                                                    messageID: String,
                                                    completion: @escaping (CGFloat) -> Void) {
        let trimmed = text
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion(16) }
            return
        }
        layoutPrewarmQueue.async {
            let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
            let font = UIFont.systemFont(ofSize: fontSize)
            let bodyH = ceil(
                (trimmed as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            storeSearchBodyHeight(
                bodyH,
                messageID: messageID,
                layoutWidth: layoutWidth,
                utf8Count: trimmed.utf8.count
            )
            DispatchQueue.main.async {
                completion(max(bodyH, 16))
            }
        }
    }

    private static func estimatedSearchBodyHeight(text: String,
                                                  layoutWidth: CGFloat,
                                                  messageID: String) -> CGFloat {
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        let font = UIFont.systemFont(ofSize: thinkFont)
        let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
        let utf8Count = text.utf8.count
        if !messageID.isEmpty,
           let cached = searchBodyHeightCache[chromeHeightCacheKey(
               messageID: messageID,
               width: width,
               utf8Count: utf8Count
           )] {
            return max(cached, 16)
        }
        let bodyH: CGFloat
        if utf8Count > searchMeasureCapChars {
            let prefix = String(text.prefix(searchMeasureCapChars))
            let prefixH = ceil(
                (prefix as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            let scaled = prefixH * CGFloat(utf8Count) / CGFloat(searchMeasureCapChars)
            bodyH = min(searchHeightSoftCap, ceil(scaled))
        } else {
            bodyH = ceil(
                (text as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            if !messageID.isEmpty {
                searchBodyHeightCache[chromeHeightCacheKey(
                    messageID: messageID,
                    width: width,
                    utf8Count: utf8Count
                )] = bodyH
            }
        }
        return max(bodyH, 16)
    }

    static func storeThinkingBodyHeight(_ height: CGFloat,
                                        messageID: String,
                                        layoutWidth: CGFloat,
                                        utf8Count: Int) {
        guard !messageID.isEmpty, height > 0 else { return }
        let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
        thinkingBodyHeightCache[thinkingHeightCacheKey(
            messageID: messageID,
            width: width,
            utf8Count: utf8Count
        )] = height
    }

    static func lookupThinkingBodyHeight(messageID: String,
                                         layoutWidth: CGFloat,
                                         utf8Count: Int) -> CGFloat? {
        guard !messageID.isEmpty else { return nil }
        let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
        return thinkingBodyHeightCache[thinkingHeightCacheKey(
            messageID: messageID,
            width: width,
            utf8Count: utf8Count
        )]
    }

    /// Body height only (excludes the 32pt tag header + chrome padding).
    static func estimatedThinkingBodyHeight(reasoning: String,
                                            layoutWidth: CGFloat,
                                            messageID: String = "") -> CGFloat {
        let chrome = estimatedThinkingChromeHeight(
            reasoning: reasoning,
            expanded: true,
            messageID: messageID,
            layoutWidth: layoutWidth
        )
        return max(chrome - 42, 16)
    }

    /// Body height for expand delta — cache first, cheap estimate fallback.
    static func resolvedThinkingBodyHeight(reasoning: String,
                                           messageID: String,
                                           layoutWidth: CGFloat) -> CGFloat {
        let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 16 }
        let utf8Count = trimmed.utf8.count
        if let cached = lookupThinkingBodyHeight(
            messageID: messageID,
            layoutWidth: layoutWidth,
            utf8Count: utf8Count
        ), cached > 0 {
            return cached
        }
        return estimatedThinkingBodyHeight(
            reasoning: trimmed,
            layoutWidth: layoutWidth,
            messageID: messageID
        )
    }

    /// Extra column height when expanding thinking (header-only → header + body).
    static func thinkingExpandHeightDelta(reasoning: String,
                                          messageID: String,
                                          layoutWidth: CGFloat) -> CGFloat {
        14 + resolvedThinkingBodyHeight(
            reasoning: reasoning,
            messageID: messageID,
            layoutWidth: layoutWidth
        )
    }

    static func measureThinkingBodyHeightOnBackground(text: String,
                                                      fontSize: CGFloat,
                                                      layoutWidth: CGFloat,
                                                      messageID: String,
                                                      completion: @escaping (CGFloat) -> Void) {
        let trimmed = text
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion(16) }
            return
        }
        layoutPrewarmQueue.async {
            let width = max(nativeLayoutWidth(for: max(layoutWidth, 120)) - 24, 80)
            let font = UIFont.systemFont(ofSize: fontSize)
            let bodyH = ceil(
                (trimmed as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            storeThinkingBodyHeight(
                bodyH,
                messageID: messageID,
                layoutWidth: layoutWidth,
                utf8Count: trimmed.utf8.count
            )
            DispatchQueue.main.async {
                completion(max(bodyH, 16))
            }
        }
    }

    /// Header + optional expanded body. Prefer real text measure — CJK `/48`
    /// estimates under-count lines and clip「已深度思考」with trailing "…".
    /// Long reasoning: capped estimate first (cache / soft-cap); precise measure stored later.
    private static func estimatedThinkingChromeHeight(reasoning: String,
                                                      expanded: Bool,
                                                      messageID: String = "",
                                                      layoutWidth: CGFloat? = nil) -> CGFloat {
        if !expanded { return 40 }
        let thinkFont = SettingsManager.shared.chatThinkingFontSize
        let font = UIFont.systemFont(ofSize: thinkFont)
        let width = max(
            (layoutWidth.map { nativeLayoutWidth(for: max($0, 120)) } ?? DSTheme.bubbleMaxWidth) - 24,
            80
        )
        let utf8Count = reasoning.utf8.count
        if !messageID.isEmpty,
           let cached = thinkingBodyHeightCache[thinkingHeightCacheKey(
               messageID: messageID,
               width: width,
               utf8Count: utf8Count
           )] {
            return 28 + max(cached, 16) + 14
        }

        let bodyH: CGFloat
        if utf8Count > thinkingMeasureCapChars {
            let prefix = String(reasoning.prefix(thinkingMeasureCapChars))
            let prefixH = ceil(
                (prefix as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            let scaled = prefixH * CGFloat(utf8Count) / CGFloat(thinkingMeasureCapChars)
            bodyH = min(thinkingHeightSoftCap, ceil(scaled))
        } else {
            bodyH = ceil(
                (reasoning as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            if !messageID.isEmpty {
                thinkingBodyHeightCache[thinkingHeightCacheKey(
                    messageID: messageID,
                    width: width,
                    utf8Count: utf8Count
                )] = bodyH
            }
        }
        return 28 + max(bodyH, 16) + 14
    }

    /// Row-height delta when toggling thinking chrome — avoids cell layout on tap.
    static func thinkingChromeHeightDelta(for message: ChatMessage,
                                          layoutWidth: CGFloat,
                                          expanded: Bool) -> CGFloat {
        let reasoning = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return 0 }
        let expandedH = estimatedThinkingChromeHeight(
            reasoning: reasoning,
            expanded: true,
            messageID: message.id,
            layoutWidth: layoutWidth
        )
        let collapsedH = estimatedThinkingChromeHeight(
            reasoning: reasoning,
            expanded: false,
            messageID: message.id,
            layoutWidth: layoutWidth
        )
        return expanded ? (expandedH - collapsedH) : (collapsedH - expandedH)
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
            total += estimatedThinkingChromeHeight(
                reasoning: reasoning,
                expanded: false,
                messageID: message.id,
                layoutWidth: layoutWidth
            )
        }

        if message.showsImageInChat {
            total += 168
        }

        let chromeBeforeBody = total
        if let body = seedableContentHeight(
            for: message,
            layoutWidth: layoutWidth,
            reserveActionRow: false,
            allowSyncLayout: allowSyncLayout
        ), body > 0 {
            if chromeBeforeBody > 0 { total += 10 }
            total += body
        } else if !message.chatDisplayBody.isEmpty {
            if chromeBeforeBody > 0 { total += 10 }
            let lines = max(1, message.chatDisplayBody.count / 48)
            total += CGFloat(36 + lines * 18)
        }

        let showActions = !message.chatDisplayBody.isEmpty
            || !reasoning.isEmpty
            || message.hasSearchProcess
            || message.hasImageTranscription
        if showActions {
            total += 4 + actionRowHeight
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
            total += estimatedThinkingChromeHeight(
                reasoning: reasoning,
                expanded: false,
                messageID: message.id,
                layoutWidth: layoutWidth
            )
        }

        if message.showsImageInChat {
            total += 168
        }

        let width = nativeLayoutWidth(for: max(layoutWidth, 120))
        let font = UIFont.systemFont(ofSize: SettingsManager.shared.chatBodyFontSize)
        let content = message.chatDisplayBody
        if !content.isEmpty {
            let textHeight = ceil(
                (content as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height
            )
            let bodyTop: CGFloat = (total > 0 || message.showsImageInChat) ? 10 : 8
            total += bodyTop + textHeight
        }

        let showActions = !message.chatDisplayBody.isEmpty
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
