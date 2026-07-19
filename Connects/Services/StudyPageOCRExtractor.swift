import UIKit
import Vision

enum ImageDurableText {
    static let ocrHeader = "【页面 OCR】"
    static let transcriptionHeader = "【图片转写】"
    static let legacyHeader = "【图片文字描述】"

    static func ocrBlock(_ text: String) -> String {
        "\(ocrHeader)\n\(text)"
    }

    static func merge(ocr: String?, transcription: String) -> String {
        let ocrPart = ocr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transPart = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if ocrPart.isEmpty {
            return "\(transcriptionHeader)\n\(transPart)"
        }
        if transPart.isEmpty {
            return ocrBlock(ocrPart)
        }
        return "\(ocrHeader)\n\(ocrPart)\n\n\(transcriptionHeader)\n\(transPart)"
    }

    static func ocrSection(from durable: String?) -> String? {
        guard let durable = durable?.trimmingCharacters(in: .whitespacesAndNewlines),
              !durable.isEmpty else { return nil }
        if durable.hasPrefix(ocrHeader) {
            let body = durable
                .dropFirst(ocrHeader.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = body.range(of: "\n\n\(transcriptionHeader)") {
                return String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return body.isEmpty ? nil : body
        }
        if durable.hasPrefix(legacyHeader) || durable.hasPrefix(transcriptionHeader) {
            return nil
        }
        return durable
    }

    static func isStatusOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("正在") { return true }
        if trimmed.contains("主回复不会等待") { return true }
        return false
    }

    /// Prefer durable assistant copy; fall back to the paired user `imageDescription`.
    static func displayBody(assistantText: String, userDescription: String?) -> String {
        let assistant = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !assistant.isEmpty, !isStatusOnly(assistant) { return assistantText }
        if !user.isEmpty { return user }
        return assistantText
    }
}

enum StudyPageOCRExtractor {
    private static let pdfTextRichThreshold = 40

    static func extract(pdfText: String?, imageBase64: String) -> String {
        let pdf = pdfText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if pdf.count >= pdfTextRichThreshold {
            return String(pdf.prefix(4_000))
        }
        let vision = recognizeTextInImage(base64: imageBase64)
        if pdf.isEmpty {
            return String(vision.prefix(4_000))
        }
        if vision.isEmpty {
            return String(pdf.prefix(4_000))
        }
        return String((pdf + "\n" + vision).prefix(4_000))
    }

    private static func recognizeTextInImage(base64: String) -> String {
        guard let image = ImageAttachmentHelper.image(from: base64) else { return "" }
        if #available(iOS 13.0, *) {
            return VisionTextRecognizer.recognize(in: image)
        }
        return ""
    }
}

@available(iOS 13.0, *)
private enum VisionTextRecognizer {
    static func recognize(in image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return lines.joined(separator: "\n")
    }
}
