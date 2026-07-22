import Foundation
import CoreGraphics

struct StudyDocument: Codable, Equatable {
    let id: String
    var title: String
    var localRelativePath: String
    var contentFingerprint: String
    var fileSize: Int64
    var lastOpenedAt: Date

    init(id: String = UUID().uuidString,
         title: String,
         localRelativePath: String,
         contentFingerprint: String,
         fileSize: Int64,
         lastOpenedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.localRelativePath = localRelativePath
        self.contentFingerprint = contentFingerprint
        self.fileSize = fileSize
        self.lastOpenedAt = lastOpenedAt
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

struct PDFBookmark: Codable, Equatable, Identifiable {
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
