import Foundation

struct StudyPageCapture {
    let label: String
    let text: String
    let imageJPEGBase64: String

    private static let shortTextThreshold = 80

    /// Enough extractable text that OCR / vision transcription would only duplicate
    /// reading context into the chat UI (same as a normal text turn + context).
    var hasRichExtractableText: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.shortTextThreshold
    }

    /// Thin / empty page text still needs the standalone image-transcription path.
    var needsImageTranscription: Bool { !hasRichExtractableText }

    func apiContextPrefix() -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return """
            [阅读上下文 · \(label)]
            （本页为图片或乐谱，请结合附带截图理解；发送后将先 OCR、再异步转写页面内容。）
            """
        }
        let body = String(trimmed.prefix(4000))
        if trimmed.count < Self.shortTextThreshold {
            return """
            [阅读上下文 · \(label)]
            \(body)

            （可提取文字较少，请以附带页面截图为准。）
            """
        }
        return """
        [阅读上下文 · \(label)]
        \(body)

        （已附带当前页截图，请图文结合理解。）
        """
    }
}

protocol StudyReadingContextProviding: AnyObject {
    func captureCurrentStudyPage() -> StudyPageCapture?
    /// When true, ChatVC should not apply full-screen keyboard lift; the shell resizes the portrait panel.
    var managesPortraitKeyboardLayout: Bool { get }
}

extension StudyReadingContextProviding {
    var managesPortraitKeyboardLayout: Bool { false }
}
