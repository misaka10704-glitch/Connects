import Foundation

/// Debug session cecb2f — snap/open/switch runtime trace.
enum AgentDebugLog {
    private static let sessionId = "cecb2f"
    private static let ingestHosts = [
        "http://192.168.11.104:7900/ingest/4e18966b-1be5-4fb9-9e02-c5d066b5195e",
        "http://127.0.0.1:7900/ingest/4e18966b-1be5-4fb9-9e02-c5d066b5195e"
    ]
    private static let fileName = "debug-cecb2f.log"
    private static let queue = DispatchQueue(label: "com.misamisa.connects.agentdebug", qos: .utility)

    static func emit(hypothesisId: String,
                     location: String,
                     message: String,
                     data: [String: Any] = [:],
                     runId: String = "pre-fix") {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        queue.async {
            guard JSONSerialization.isValidJSONObject(payload),
                  let json = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: json, encoding: .utf8) else { return }
            let ndjson = line + "\n"
            // #region agent log
            if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent(fileName) {
                if FileManager.default.fileExists(atPath: url.path),
                   let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(ndjson.data(using: .utf8) ?? Data())
                    handle.closeFile()
                } else {
                    try? ndjson.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            for host in ingestHosts {
                guard let postURL = URL(string: host) else { continue }
                var req = URLRequest(url: postURL, timeoutInterval: 2)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(sessionId, forHTTPHeaderField: "X-Debug-Session-Id")
                req.httpBody = json
                URLSession.shared.dataTask(with: req).resume()
            }
            NSLog("DBGcecb2f %@", line)
            // #endregion
        }
    }
}
