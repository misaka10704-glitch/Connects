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
    private var lineBuffer = ""
    private var pendingHTTPError: Int?
    private var errorBody = Data()

    private var reasoningBuf = ""
    private var contentBuf = ""
    private var flushWork: DispatchWorkItem?
    private var ended = false
    private var startedAt: Date?
    private var reportedFirstToken = false

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
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() {
        let apiKey = SettingsManager.shared.sanitizedAPIKey(for: model.provider)
        guard !apiKey.isEmpty else {
            fail(APIClientError.missingAPIKey(model.provider.displayName))
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
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush(force: false)
        }
        flushWork = work
        // Faster UI cadence for Instant mode
        let delay = model.thinkingActive ? 0.08 : 0.03
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

    // MARK: URLSession

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            pendingHTTPError = http.statusCode
            errorBody = Data()
        } else {
            pendingHTTPError = nil
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if pendingHTTPError != nil {
            errorBody.append(data)
            return
        }
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lineBuffer += chunk
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<range.lowerBound])
            lineBuffer = String(lineBuffer[range.upperBound...])
            parseSSELine(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if pendingHTTPError == nil, !lineBuffer.isEmpty {
            parseSSELine(lineBuffer)
            lineBuffer = ""
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let code = self.pendingHTTPError {
                let detail = APIClient.parseAPIErrorBody(self.errorBody)
                self.finishLocally(error: APIClientError.httpError(code, detail))
                return
            }
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                self.finishLocally(error: APIClientError.cancelled)
            } else if let error = error {
                self.finishLocally(error: error)
            } else {
                self.finishLocally(error: nil)
            }
        }
    }

    private func parseSSELine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return }
        let dataStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if dataStr == "[DONE]" { return }
        guard let jsonData = dataStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return }

        if let reasoning = APIClient.deltaTextPublic(delta["reasoning_content"]), !reasoning.isEmpty {
            reasoningBuf += reasoning
            scheduleFlush()
        }
        if let content = APIClient.deltaTextPublic(delta["content"]), !content.isEmpty {
            contentBuf += content
            scheduleFlush()
        }
    }
}
