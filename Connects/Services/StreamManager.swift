import Foundation

extension Notification.Name {
    /// userInfo["conversationID"] = String
    static let streamManagerDidUpdate = Notification.Name("ConnectsStreamManagerDidUpdate")
    static let streamManagerDidFinish = Notification.Name("ConnectsStreamManagerDidFinish")
}

/// Runs one or more chat completions in parallel so switching conversations does not cancel them.
final class StreamManager {
    static let shared = StreamManager()

    private let lock = NSLock()
    private var engines: [String: StreamEngine] = [:]

    func isRunning(_ conversationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return engines[conversationID] != nil
    }

    func runningIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(engines.keys)
    }

    /// Start (or replace) a stream for a conversation. Does **not** cancel other conversations.
    func start(conversationID: String,
               messages: [ChatMessage],
               model: AIModelOption,
               needsAITitle: Bool) {
        cancel(conversationID)
        let engine = StreamEngine(
            conversationID: conversationID,
            messages: messages,
            model: model,
            needsAITitle: needsAITitle
        ) { [weak self] id in
            self?.removeEngine(id)
        }
        lock.lock()
        engines[conversationID] = engine
        lock.unlock()
        engine.start()
        postUpdate(conversationID)
    }

    func cancel(_ conversationID: String) {
        lock.lock()
        let engine = engines.removeValue(forKey: conversationID)
        lock.unlock()
        engine?.cancel()
    }

    private func removeEngine(_ conversationID: String) {
        lock.lock()
        engines.removeValue(forKey: conversationID)
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .streamManagerDidFinish,
                object: nil,
                userInfo: ["conversationID": conversationID]
            )
            // Sidebar / title refresh without a second full chat reload:
            NotificationCenter.default.post(name: .conversationStoreDidUpdate, object: nil, userInfo: ["source": "streamFinish"])
        }
    }

    private func postUpdate(_ conversationID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .streamManagerDidUpdate,
                object: nil,
                userInfo: ["conversationID": conversationID]
            )
        }
    }
}

// MARK: - Per-conversation engine

private final class StreamEngine: NSObject, URLSessionDataDelegate {
    let conversationID: String
    private let messages: [ChatMessage]
    private let model: AIModelOption
    private let needsAITitle: Bool
    private let onEnded: (String) -> Void

    private var task: URLSessionDataTask?
    private var session: URLSession!
    /// Keep raw bytes until a complete SSE line arrives. URLSession callbacks
    /// may split a multi-byte UTF-8 scalar; decoding each callback separately
    /// silently dropped entire chunks of Chinese/formula output.
    private var receiveBuffer = Data()
    private var pendingHTTPError: Int?
    private var errorBody = Data()

    private var reasoningBuf = ""
    private var contentBuf = ""
    private var flushWork: DispatchWorkItem?
    private var ended = false
    private var lengthLimited = false
    private var startedAt: Date?
    private var reportedFirstToken = false
    /// One automatic follow-up when the model returns thinking but no visible body.
    private var didEmptyBodyRetry = false
    private var sawAnyContent = false
    private var sawAnyReasoning = false
    /// Auto-continue when output hits max_tokens (thinking + body share one budget).
    private var lengthContinueCount = 0
    private let maxLengthContinues = 4

    init(conversationID: String,
         messages: [ChatMessage],
         model: AIModelOption,
         needsAITitle: Bool,
         onEnded: @escaping (String) -> Void) {
        self.conversationID = conversationID
        self.messages = messages
        self.model = model
        self.needsAITitle = needsAITitle
        self.onEnded = onEnded
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldUsePipelining = false
        // Allow several chats to stream against the same host concurrently.
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() {
        let apiKey = SettingsManager.shared.apiKey(for: model)
        guard !apiKey.isEmpty else {
            fail(APIClientError.missingAPIKey(model.providerDisplayName))
            return
        }
        if messages.contains(where: { $0.hasImage }) && !model.supportsVision {
            fail(APIClientError.visionNotSupported)
            return
        }
        guard let url = URL(string: model.chatCompletionsURL) else {
            fail(APIClientError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        APIClient.applyStreamRequestHeaders(&request)

        // Caller (ChatVC) already ran ContextBuilder; only re-slim images as a safety net.
        let slim = APIClient.slimMessagesForAPI(messages)
        let payload = APIClient.chatPayload(messages: slim, model: model, stream: true)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            fail(error)
            return
        }
        #if DEBUG
        let bytes = request.httpBody?.count ?? 0
        print("[Connects] Kimi/DS stream → \(url.absoluteString) body=\(bytes)B thinking=\(model.thinkingActive)")
        #endif
        startedAt = Date()
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        finishLocally(error: APIClientError.cancelled)
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.finishLocally(error: error)
        }
    }

    private func scheduleFlush() {
        markFirstTokenIfNeeded()
        // Throttle at a fixed cadence. Debouncing here postponed the work item
        // every time a token arrived, so a continuous stream stayed invisible
        // until the provider finished.
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flush(force: false)
        }
        flushWork = work
        // Keep both reasoning and answer close to display refresh cadence.
        // The view controller performs its own lightweight frame throttle.
        let delay: TimeInterval = 0.025
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func markFirstTokenIfNeeded() {
        guard !reportedFirstToken, let start = startedAt else { return }
        reportedFirstToken = true
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let host = URL(string: model.chatCompletionsURL)?.host ?? "?"
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("ConnectsStreamTTFT"),
                object: nil,
                userInfo: [
                    "conversationID": self.conversationID,
                    "ms": ms,
                    "host": host,
                    "thinking": self.model.thinkingActive
                ]
            )
        }
    }

    private func flush(force: Bool) {
        flushWork?.cancel()
        flushWork = nil
        let r = reasoningBuf
        let c = contentBuf
        reasoningBuf = ""
        contentBuf = ""
        guard !r.isEmpty || !c.isEmpty else { return }

        let id = conversationID
        let commit = {
            ConversationStore.shared.appendStreamTokens(
                conversationID: id,
                reasoning: r,
                content: c
            )
            NotificationCenter.default.post(
                name: .streamManagerDidUpdate,
                object: nil,
                userInfo: ["conversationID": id]
            )
        }
        /*
         * finishLocally runs on the main queue. Dispatching its final buffer
         * asynchronously used to mark the message non-streaming first, so
         * ConversationStore correctly rejected that final append. The visible
         * reply then ended mid-sentence / mid-table row.
         */
        if Thread.isMainThread {
            commit()
        } else {
            DispatchQueue.main.async(execute: commit)
        }
    }

    private func finishLocally(error: Error?) {
        guard !ended else { return }
        ended = true
        flush(force: true)

        let isCancel: Bool = {
            if let e = error as? APIClientError, e == .cancelled { return true }
            if let e = error as NSError?, e.code == NSURLErrorCancelled { return true }
            return false
        }()

        let last = ConversationStore.shared.conversation(id: conversationID)?.messages
            .last(where: { $0.isStreaming })
            ?? ConversationStore.shared.conversation(id: conversationID)?.messages.last
        let body = last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let think = last?.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bodyEmpty = body.isEmpty

        // Hit max_tokens: thinking + content share one completion budget on Kimi.
        // Keep the same assistant bubble and ask the model to resume from the cut.
        if error == nil, !isCancel, lengthLimited, lengthContinueCount < maxLengthContinues {
            lengthContinueCount += 1
            lengthLimited = false
            ended = false
            #if DEBUG
            print("[Connects] length limit — auto-continue #\(lengthContinueCount)")
            #endif
            let openEdit = CodeEditApplyTools.hasIncompleteEditBlock(last?.content ?? "")
            startContinuation(
                assistantContent: last?.content ?? "",
                assistantReasoning: last?.reasoningContent ?? "",
                userNudge: openEdit
                    ? CodeEditApplyTools.incompleteEditContinueNudge
                    : """
                    上一段因长度上限被截断了。请从中断处继续写完整正文：
                    - 不要重复已经写过的内容
                    - 不要再写开场白或目录标题（若上一段已有）
                    - 直接接着写
                    """
            )
            return
        }

        // CONNECTS_EDIT opened but never closed (common on first full-file write).
        // finish_reason may be "stop" even though the machine block is incomplete.
        if error == nil, !isCancel, lengthContinueCount < maxLengthContinues,
           CodeEditApplyTools.hasIncompleteEditBlock(body) {
            lengthContinueCount += 1
            ended = false
            #if DEBUG
            print("[Connects] incomplete CONNECTS_EDIT — auto-continue #\(lengthContinueCount)")
            #endif
            startContinuation(
                assistantContent: last?.content ?? "",
                assistantReasoning: last?.reasoningContent ?? "",
                userNudge: CodeEditApplyTools.incompleteEditContinueNudge
            )
            return
        }

        // Reasoning-only stop: ask once for the visible body.
        if error == nil, !isCancel, !didEmptyBodyRetry, bodyEmpty, !think.isEmpty {
            didEmptyBodyRetry = true
            ended = false
            #if DEBUG
            print("[Connects] empty body after thinking — requesting visible reply continuation")
            #endif
            startContinuation(
                assistantContent: "",
                assistantReasoning: think,
                userNudge: "请基于你刚才的思考，直接输出给用户的完整正文回答。不要重复思考过程，不要只写提纲，直接写正文。"
            )
            return
        }

        // Truncated-looking short body after long thinking (e.g. stops right after a heading).
        if error == nil, !isCancel, lengthContinueCount < maxLengthContinues,
           looksTruncatedBody(body), think.count >= 200 {
            lengthContinueCount += 1
            ended = false
            #if DEBUG
            print("[Connects] truncated-looking body — auto-continue #\(lengthContinueCount)")
            #endif
            startContinuation(
                assistantContent: last?.content ?? "",
                assistantReasoning: last?.reasoningContent ?? "",
                userNudge: """
                正文似乎写到一半就停了。请从中断处继续写完整回答，不要重复已有内容，直接接着写。
                """
            )
            return
        }

        if lengthLimited {
            ConversationStore.shared.appendStreamTokens(
                conversationID: conversationID,
                reasoning: "",
                content: "\n\n> 本次回复达到长度上限，已尝试自动续写仍未完成。可发送「继续」接着生成。"
            )
        }

        // A continuation can fail after a partial first response. Previously
        // ConversationStore hid errors whenever any body text existed, making an
        // API rejection look exactly like silent truncation.
        if let error = error, !isCancel,
           lengthContinueCount > 0 || didEmptyBodyRetry {
            ConversationStore.shared.appendStreamTokens(
                conversationID: conversationID,
                reasoning: "",
                content: "\n\n> 自动续写失败：\(error.localizedDescription)"
            )
        }

        ConversationStore.shared.finishStreamingMessage(
            conversationID: conversationID,
            errorText: {
                guard let error = error, !isCancel else { return nil }
                return error.localizedDescription
            }()
        )

        if needsAITitle, !isCancel {
            AITitleGenerator.generateIfNeeded(conversationID: conversationID)
        }

        session.invalidateAndCancel()
        onEnded(conversationID)
    }

    private func looksTruncatedBody(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 1_200 else { return false }
        if trimmed.hasSuffix("：") || trimmed.hasSuffix(":") || trimmed.hasSuffix("、") {
            return true
        }
        // Ends on a markdown/Chinese section heading with little or no following prose.
        if trimmed.range(
            of: #"(?:^|\n)(?:#{1,3}\s+|[一二三四五六七八九十]+[、.．]|（[一二三四五六七八九十]+）|\d+[\.、])[^\n]{1,40}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // Very short body relative to long thinking, and no sentence ender near the end.
        let tail = String(trimmed.suffix(80))
        if trimmed.count < 280, !tail.contains("。"), !tail.contains("！"), !tail.contains("？") {
            return true
        }
        return false
    }

    /// Resume generation into the same streaming assistant message.
    private func startContinuation(assistantContent: String,
                                   assistantReasoning: String,
                                   userNudge: String) {
        let apiKey = SettingsManager.shared.apiKey(for: model)
        guard !apiKey.isEmpty, let url = URL(string: model.chatCompletionsURL) else {
            ended = true
            ConversationStore.shared.finishStreamingMessage(
                conversationID: conversationID,
                errorText: nil
            )
            session.invalidateAndCancel()
            onEnded(conversationID)
            return
        }

        var continuationMessages: [ChatMessage]
        if let live = ConversationStore.shared.conversation(id: conversationID) {
            continuationMessages = ContextBuilder.messagesForAPI(
                from: live.messages,
                model: model,
                existingSummary: live.contextSummary,
                existingThroughID: live.contextSummaryThroughMessageID
            )
        } else {
            continuationMessages = APIClient.slimMessagesForAPI(messages)
        }
        continuationMessages.append(ChatMessage(
            role: .assistant,
            content: assistantContent,
            reasoningContent: assistantReasoning
        ))
        continuationMessages.append(ChatMessage(
            role: .user,
            content: userNudge
        ))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        APIClient.applyStreamRequestHeaders(&request)
        let preserveKimiThinking = model.provider == .kimi
            && (model.forcesThinking || model.thinkingActive)
            && !assistantReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let payload = APIClient.chatPayload(
            messages: continuationMessages,
            model: model,
            stream: true,
            preserveThinking: preserveKimiThinking
        )
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            ended = true
            ConversationStore.shared.finishStreamingMessage(
                conversationID: conversationID,
                errorText: error.localizedDescription
            )
            session.invalidateAndCancel()
            onEnded(conversationID)
            return
        }

        receiveBuffer.removeAll(keepingCapacity: false)
        pendingHTTPError = nil
        errorBody = Data()
        reasoningBuf = ""
        contentBuf = ""
        lengthLimited = false
        task?.cancel()
        let next = session.dataTask(with: request)
        task = next
        next.resume()
        NotificationCenter.default.post(
            name: .streamManagerDidUpdate,
            object: nil,
            userInfo: ["conversationID": conversationID]
        )
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            pendingHTTPError = http.statusCode
            errorBody = Data()
        } else {
            pendingHTTPError = nil
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Auto-continuation replaces the URLSessionDataTask. Late callbacks
        // from the cancelled task must never enter the new task's SSE buffer.
        guard dataTask === task else { return }
        if pendingHTTPError != nil {
            errorBody.append(data)
            return
        }
        receiveBuffer.append(data)
        var reasoning = ""
        var content = ""
        var finishReason: String?
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer[..<newline]
            let line = String(decoding: lineData, as: UTF8.self)
            receiveBuffer.removeSubrange(...newline)
            let delta = parseSSELine(line)
            reasoning += delta.reasoning
            content += delta.content
            finishReason = delta.finishReason ?? finishReason
        }
        enqueueDelta(reasoning: reasoning, content: content, finishReason: finishReason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A superseded task can complete successfully as well as with
        // NSURLErrorCancelled. Ignore either form while its replacement runs.
        if let current = self.task, current !== task {
            return
        }
        if pendingHTTPError == nil, !receiveBuffer.isEmpty {
            // Drain every remaining SSE line — not just the first one.
            receiveBuffer.append(0x0A)
            var reasoning = ""
            var content = ""
            var finishReason: String?
            while let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let lineData = receiveBuffer[..<newline]
                let line = String(decoding: lineData, as: UTF8.self)
                receiveBuffer.removeSubrange(...newline)
                let delta = parseSSELine(line)
                reasoning += delta.reasoning
                content += delta.content
                finishReason = delta.finishReason ?? finishReason
            }
            receiveBuffer.removeAll(keepingCapacity: false)
            enqueueDelta(reasoning: reasoning, content: content, finishReason: finishReason)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let current = self.task, current !== task {
                return
            }
            if let code = self.pendingHTTPError {
                let detail = APIClient.parseAPIErrorBody(self.errorBody)
                self.finishLocally(error: APIClientError.httpError(code, detail))
                return
            }
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                // Replaced by auto-continuation — ignore cancel from the swapped task.
                if !self.ended, self.task != nil, self.task !== task {
                    return
                }
                self.finishLocally(error: APIClientError.cancelled)
            } else if let error = error {
                self.finishLocally(error: error)
            } else {
                self.finishLocally(error: nil)
            }
        }
    }

    private func enqueueDelta(reasoning: String,
                              content: String,
                              finishReason: String?) {
        guard !reasoning.isEmpty || !content.isEmpty || finishReason != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.ended else { return }
            if finishReason == "length" {
                self.lengthLimited = true
            }
            if !reasoning.isEmpty { self.sawAnyReasoning = true }
            if !content.isEmpty { self.sawAnyContent = true }
            self.reasoningBuf += reasoning
            self.contentBuf += content
            if !reasoning.isEmpty || !content.isEmpty {
                self.scheduleFlush()
            }
        }
    }

    private func parseSSELine(_ line: String) -> (
        reasoning: String,
        content: String,
        finishReason: String?
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return ("", "", nil) }
        let dataStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if dataStr == "[DONE]" { return ("", "", nil) }
        guard let jsonData = dataStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first else { return ("", "", nil) }

        let delta = choice["delta"] as? [String: Any] ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        let reasoning = APIClient.deltaTextPublic(delta["reasoning_content"])
            ?? APIClient.deltaTextPublic(delta["reasoning"])
            ?? APIClient.deltaTextPublic(message["reasoning_content"])
            ?? APIClient.deltaTextPublic(message["reasoning"])
            ?? ""
        let content = APIClient.deltaTextPublic(delta["content"])
            ?? APIClient.deltaTextPublic(message["content"])
            ?? ""
        return (reasoning, content, choice["finish_reason"] as? String)
    }
}
