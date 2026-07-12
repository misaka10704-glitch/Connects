import Foundation

protocol ChatStreamDelegate: AnyObject {
    func streamDidReceiveReasoning(_ token: String)
    func streamDidReceiveToken(_ token: String)
    func streamDidComplete()
    func streamDidFail(_ error: Error)
}

enum APIClientError: LocalizedError, Equatable {
    case missingAPIKey(String)
    case invalidURL
    case httpError(Int, String)
    case decodeError
    case cancelled
    case visionNotSupported

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "请先在设置中填写 \(provider) 的 API Key"
        case .invalidURL:
            return "无效的 API 地址"
        case .httpError(let code, let body):
            if code == 401 {
                return "鉴权失败 (401)：API Key 无效、过期，或用错了平台 Key。请到设置核对对应厂商的 Key。\(body.isEmpty ? "" : "\n\(body)")"
            }
            return "请求失败 (\(code))：\(body.isEmpty ? "HTTP \(code)" : body)"
        case .decodeError:
            return "响应解析失败"
        case .cancelled:
            return "已取消"
        case .visionNotSupported:
            return "当前模型不支持图片，请切换到 Kimi / Qwen / 智谱视觉 / 豆包"
        }
    }
}

final class APIClient: NSObject {
    static let shared = APIClient()

    private var streamTask: URLSessionDataTask?
    private weak var streamDelegate: ChatStreamDelegate?
    private var streamBuffer = ""
    private var pendingHTTPError: Int?
    private var errorBodyData = Data()
    private var currentProviderName = ""

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        streamBuffer = ""
        pendingHTTPError = nil
        errorBodyData = Data()
    }

    func sendStreaming(messages: [ChatMessage],
                       model: AIModelOption,
                       delegate: ChatStreamDelegate) {
        cancelStream()
        streamDelegate = delegate
        streamBuffer = ""
        pendingHTTPError = nil
        errorBodyData = Data()
        currentProviderName = model.provider.displayName

        let apiKey = SettingsManager.shared.sanitizedAPIKey(for: model.provider)
        guard !apiKey.isEmpty else {
            delegate.streamDidFail(APIClientError.missingAPIKey(model.provider.displayName))
            return
        }

        if messages.contains(where: { $0.hasImage }) && !model.supportsVision {
            delegate.streamDidFail(APIClientError.visionNotSupported)
            return
        }

        guard let url = URL(string: model.chatCompletionsURL) else {
            delegate.streamDidFail(APIClientError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        Self.applyStreamRequestHeaders(&request)

        let slim = Self.slimMessagesForAPI(messages)
        let payload = Self.chatPayload(messages: slim, model: model, stream: true)
        // Note: do not set temperature/top_p for Kimi K2.6 — fixed by API.

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            delegate.streamDidFail(error)
            return
        }

        streamTask = session.dataTask(with: request)
        streamTask?.resume()
    }

    func complete(messages: [ChatMessage],
                  model: AIModelOption,
                  maxTokens: Int = 32,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let apiKey = SettingsManager.shared.sanitizedAPIKey(for: model.provider)
        guard !apiKey.isEmpty else {
            completion(.failure(APIClientError.missingAPIKey(model.provider.displayName)))
            return
        }
        guard let url = URL(string: model.chatCompletionsURL) else {
            completion(.failure(APIClientError.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Title / compaction helpers: always Instant + no reasoning history.
        var payload = Self.chatPayload(messages: messages, model: model, stream: false, maxTokens: maxTokens)
        if model.supportsThinkingToggle {
            payload["thinking"] = ["type": "disabled"]
        }
        payload["messages"] = messages.map {
            APIClient.serializeMessagePublic($0, model: model, includeReasoning: false)
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let detail = Self.parseAPIErrorBody(data)
                DispatchQueue.main.async {
                    completion(.failure(APIClientError.httpError(http.statusCode, detail)))
                }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                DispatchQueue.main.async { completion(.failure(APIClientError.decodeError)) }
                return
            }
            DispatchQueue.main.async { completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }.resume()
    }

    static func parseAPIErrorBody(_ data: Data?) -> String {
        guard let data = data, !data.isEmpty else { return "" }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? ""
                let typ = (err["type"] as? String) ?? ""
                let code = "\(err["code"] ?? "")"
                return [typ, code, msg].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if let msg = json["message"] as? String { return msg }
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func serializeMessage(_ message: ChatMessage, model: AIModelOption) -> [String: Any] {
        Self.serializeMessagePublic(message, model: model)
    }

    /// Build chat/completions JSON body shared by stream + complete.
    static func chatPayload(messages: [ChatMessage], model: AIModelOption, stream: Bool, maxTokens: Int? = nil) -> [String: Any] {
        let thinkingOn = model.thinkingActive
        // Default chat cap — Kimi's 32k default makes long runs feel endless; does not delay TTFT much
        // but keeps Instant replies bounded.
        let tokenCap = maxTokens ?? 8192
        var payload: [String: Any] = [
            "model": model.resolvedModelId,
            "messages": messages.map { serializeMessagePublic($0, model: model, includeReasoning: thinkingOn) },
            "stream": stream,
            "max_tokens": tokenCap
        ]
        switch model.thinkingStyle {
        case .none:
            break
        case .enableThinking:
            if model.supportsThinkingToggle {
                payload["enable_thinking"] = thinkingOn
            }
        case .thinkingType:
            if model.supportsThinkingToggle {
                payload["thinking"] = ["type": thinkingOn ? "enabled" : "disabled"]
            }
        }
        return payload
    }

    static func serializeMessagePublic(_ message: ChatMessage, model: AIModelOption, includeReasoning: Bool = true) -> [String: Any] {
        // Only keep the latest image in the request to avoid multi-MB re-uploads every turn.
        // (Caller may already filter; this is a safety net when message still has image.)
        if model.supportsVision, let b64 = message.imageJPEGBase64, !b64.isEmpty {
            var parts: [[String: Any]] = [
                [
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(b64)"]
                ]
            ]
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(["type": "text", "text": text])
            } else {
                parts.append(["type": "text", "text": "请描述这张图片。"])
            }
            return ["role": message.apiRole, "content": parts]
        }

        var body: [String: Any] = ["role": message.apiRole, "content": message.content]
        // Huge prior reasoning_content is a common cause of Instant-mode still being slow
        // (prefill balloons). Only send when thinking is ON.
        if includeReasoning, message.role == .assistant {
            let think = message.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !think.isEmpty {
                // Cap to avoid pathological multi-turn bloat
                body["reasoning_content"] = String(think.prefix(8000))
            }
        }
        return body
    }

    /// Drop image payloads from all but the last user message that has one.
    static func slimMessagesForAPI(_ messages: [ChatMessage]) -> [ChatMessage] {
        var lastImageIndex: Int?
        for (i, m) in messages.enumerated() where m.hasImage {
            lastImageIndex = i
        }
        guard let keep = lastImageIndex else { return messages }
        return messages.enumerated().map { i, m in
            guard m.hasImage, i != keep else { return m }
            var copy = m
            copy.imageJPEGBase64 = nil
            return copy
        }
    }

    static func applyStreamRequestHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Avoid gzip buffering of SSE on older URLSession (iOS 12) — first token can stall for ages.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    }

    static func deltaTextPublic(_ value: Any?) -> String? {
        deltaText(value)
    }

    /// OpenAI-compatible deltas may send String or (rarely) a multimodal parts array.
    fileprivate static func deltaText(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let parts = value as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined() }
        }
        return nil
    }
}

extension APIClient: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            pendingHTTPError = http.statusCode
            errorBodyData = Data()
            // Allow body so we can show API's error message
            completionHandler(.allow)
            return
        }
        pendingHTTPError = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        if pendingHTTPError != nil {
            errorBodyData.append(data)
            return
        }

        guard let chunk = String(data: data, encoding: .utf8) else { return }
        streamBuffer += chunk

        while let range = streamBuffer.range(of: "\n") {
            let line = String(streamBuffer[..<range.lowerBound])
            streamBuffer = String(streamBuffer[range.upperBound...])
            parseSSELine(line)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Flush any trailing SSE line without a final newline
        if pendingHTTPError == nil, !streamBuffer.isEmpty {
            parseSSELine(streamBuffer)
            streamBuffer = ""
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.streamTask = nil
                self.pendingHTTPError = nil
                self.errorBodyData = Data()
                self.streamBuffer = ""
            }

            if let code = self.pendingHTTPError {
                let detail = Self.parseAPIErrorBody(self.errorBodyData)
                self.streamDelegate?.streamDidFail(APIClientError.httpError(code, detail))
                return
            }

            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                self.streamDelegate?.streamDidFail(APIClientError.cancelled)
            } else if let error = error {
                self.streamDelegate?.streamDidFail(error)
            } else {
                self.streamDelegate?.streamDidComplete()
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

        let reasoning = Self.deltaText(delta["reasoning_content"]) ?? Self.deltaText(delta["reasoning"])
        let content = Self.deltaText(delta["content"])

        if let reasoning = reasoning, !reasoning.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.streamDelegate?.streamDidReceiveReasoning(reasoning)
            }
        }
        if let content = content, !content.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.streamDelegate?.streamDidReceiveToken(content)
            }
        }
    }
}
