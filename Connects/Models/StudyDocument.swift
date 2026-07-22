import Foundation
import CoreGraphics

enum StudyDocumentKind: String, Codable, Equatable {
    case pdf
    case markdown
}

struct StudyDocument: Codable, Equatable {
    let id: String
    var title: String
    var localRelativePath: String
    var contentFingerprint: String
    var fileSize: Int64
    var lastOpenedAt: Date
    var kind: StudyDocumentKind

    enum CodingKeys: String, CodingKey {
        case id, title, localRelativePath, contentFingerprint, fileSize, lastOpenedAt, kind
    }

    init(id: String = UUID().uuidString,
         title: String,
         localRelativePath: String,
         contentFingerprint: String,
         fileSize: Int64,
         lastOpenedAt: Date = Date(),
         kind: StudyDocumentKind = .pdf) {
        self.id = id
        self.title = title
        self.localRelativePath = localRelativePath
        self.contentFingerprint = contentFingerprint
        self.fileSize = fileSize
        self.lastOpenedAt = lastOpenedAt
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        localRelativePath = try c.decode(String.self, forKey: .localRelativePath)
        contentFingerprint = try c.decode(String.self, forKey: .contentFingerprint)
        fileSize = try c.decode(Int64.self, forKey: .fileSize)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        if let decoded = try c.decodeIfPresent(StudyDocumentKind.self, forKey: .kind) {
            kind = decoded
        } else {
            let path = localRelativePath.lowercased()
            if path.hasSuffix(".md") || path.hasSuffix(".markdown") {
                kind = .markdown
            } else {
                kind = .pdf
            }
        }
    }
}

struct StudyProgress: Codable, Equatable {
    var pageIndex: Int
    var pageOffsetY: CGFloat?
    var pageOffsetX: CGFloat?
    var anchorX: CGFloat?
    var anchorY: CGFloat?
    var scaleFactor: CGFloat?
    var updatedAt: Date

    init(pageIndex: Int = 0,
         pageOffsetY: CGFloat? = nil,
         pageOffsetX: CGFloat? = nil,
         anchorX: CGFloat? = nil,
         anchorY: CGFloat? = nil,
         scaleFactor: CGFloat? = nil,
         updatedAt: Date = Date()) {
        self.pageIndex = pageIndex
        self.pageOffsetY = pageOffsetY
        self.pageOffsetX = pageOffsetX
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.scaleFactor = scaleFactor
        self.updatedAt = updatedAt
    }
}

struct PDFBookmark: Codable, Equatable {
    let id: String
    var title: String
    var pageIndex: Int
    var createdAt: Date

    init(id: String = UUID().uuidString,
         title: String,
         pageIndex: Int,
         createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.createdAt = createdAt
    }
}

extension Notification.Name {
    static let studyDocumentsDidUpdate = Notification.Name("ConnectsStudyDocumentsDidUpdate")
}
