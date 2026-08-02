import Foundation
import CoreGraphics

enum StudyDocumentKind: String, Codable, Equatable {
    case pdf
    case markdown
    case text
    case ebook
}

enum StudyDocumentAccessMode: String, Codable, Equatable {
    case importedCopy
    case originalBookmark
}

enum StudyTextLanguage: String, Codable, Equatable {
    case verilog
    case c
    case python
    case markdown
    case plain

    static func infer(fromExtension ext: String) -> StudyTextLanguage {
        switch ext.lowercased() {
        case "v", "vh", "sv", "svh": return .verilog
        case "c", "h", "cpp", "cc", "hpp", "m": return .c
        case "py": return .python
        case "md", "markdown": return .markdown
        default: return .plain
        }
    }

    /// Markdown fence language tag → highlighter language.
    static func infer(fromFenceLanguage raw: String?) -> StudyTextLanguage {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .plain
        }
        let key = raw.lowercased()
        switch key {
        case "v", "vh", "verilog", "systemverilog", "sv", "svh":
            return .verilog
        case "c", "h", "cpp", "cc", "hpp", "c++", "objc", "objective-c",
             "swift", "java", "js", "javascript", "ts", "typescript", "go", "rust", "kotlin":
            return .c
        case "py", "python":
            return .python
        case "md", "markdown":
            return .markdown
        default:
            return infer(fromExtension: key)
        }
    }

    var displayName: String {
        switch self {
        case .verilog: return "Verilog"
        case .c: return "C"
        case .python: return "Python"
        case .markdown: return "Markdown"
        case .plain: return "文本"
        }
    }

    var preferredFileExtension: String {
        switch self {
        case .verilog: return "v"
        case .c: return "c"
        case .python: return "py"
        case .markdown: return "md"
        case .plain: return "txt"
        }
    }
}

struct StudyDocument: Codable, Equatable {
    let id: String
    var title: String
    /// Sandbox-relative path for imported copies; empty for bookmark-only originals.
    var localRelativePath: String
    var contentFingerprint: String
    var fileSize: Int64
    var lastOpenedAt: Date
    var kind: StudyDocumentKind
    var accessMode: StudyDocumentAccessMode
    var bookmarkData: Data?
    var displayPath: String?
    var textLanguage: StudyTextLanguage?

    enum CodingKeys: String, CodingKey {
        case id, title, localRelativePath, contentFingerprint, fileSize, lastOpenedAt, kind
        case accessMode, bookmarkData, displayPath, textLanguage
    }

    init(id: String = UUID().uuidString,
         title: String,
         localRelativePath: String,
         contentFingerprint: String,
         fileSize: Int64,
         lastOpenedAt: Date = Date(),
         kind: StudyDocumentKind = .pdf,
         accessMode: StudyDocumentAccessMode = .importedCopy,
         bookmarkData: Data? = nil,
         displayPath: String? = nil,
         textLanguage: StudyTextLanguage? = nil) {
        self.id = id
        self.title = title
        self.localRelativePath = localRelativePath
        self.contentFingerprint = contentFingerprint
        self.fileSize = fileSize
        self.lastOpenedAt = lastOpenedAt
        self.kind = kind
        self.accessMode = accessMode
        self.bookmarkData = bookmarkData
        self.displayPath = displayPath
        self.textLanguage = textLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        localRelativePath = try c.decode(String.self, forKey: .localRelativePath)
        contentFingerprint = try c.decode(String.self, forKey: .contentFingerprint)
        fileSize = try c.decode(Int64.self, forKey: .fileSize)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        displayPath = try c.decodeIfPresent(String.self, forKey: .displayPath)
        textLanguage = try c.decodeIfPresent(StudyTextLanguage.self, forKey: .textLanguage)
        accessMode = try c.decodeIfPresent(StudyDocumentAccessMode.self, forKey: .accessMode)
            ?? (bookmarkData != nil ? .originalBookmark : .importedCopy)
        if let decoded = try c.decodeIfPresent(StudyDocumentKind.self, forKey: .kind) {
            kind = decoded
        } else {
            let path = (displayPath ?? localRelativePath).lowercased()
            if path.hasSuffix(".md") || path.hasSuffix(".markdown") {
                kind = .markdown
            } else if path.hasSuffix(".epub") || path.hasSuffix(".mobi")
                        || path.hasSuffix(".azw3") || path.hasSuffix(".azw") {
                kind = .ebook
            } else if Self.isTextPath(path) {
                kind = .text
            } else {
                kind = .pdf
            }
        }
        if kind == .text, textLanguage == nil {
            let ext = ((displayPath ?? localRelativePath) as NSString).pathExtension
            textLanguage = StudyTextLanguage.infer(fromExtension: ext)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(localRelativePath, forKey: .localRelativePath)
        try c.encode(contentFingerprint, forKey: .contentFingerprint)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encode(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encode(kind, forKey: .kind)
        try c.encode(accessMode, forKey: .accessMode)
        try c.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try c.encodeIfPresent(displayPath, forKey: .displayPath)
        try c.encodeIfPresent(textLanguage, forKey: .textLanguage)
    }

    var kindLabel: String {
        switch kind {
        case .pdf: return "PDF"
        case .markdown: return "Markdown"
        case .text: return textLanguage?.displayName ?? "文本"
        case .ebook: return "电子书"
        }
    }

    static func isTextPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let exts = [".v", ".vh", ".sv", ".svh", ".c", ".h", ".cpp", ".cc", ".hpp", ".py", ".txt", ".md", ".markdown"]
        return exts.contains { lower.hasSuffix($0) }
    }

    static func kind(forExtension ext: String) -> StudyDocumentKind? {
        let e = ext.lowercased()
        if e.isEmpty { return .text }
        switch e {
        case "pdf": return .pdf
        case "epub", "mobi", "azw3", "azw": return .ebook
        case "md", "markdown",
             "v", "vh", "sv", "svh", "c", "h", "cpp", "cc", "hpp", "py", "txt",
             "html", "htm", "css", "js", "ts", "json", "xml", "yaml", "yml",
             "swift", "rs", "go", "java", "kt", "rb", "sh", "toml", "ini", "cfg",
             "cmake", "makefile", "mk", "s", "asm", "r", "sql", "csv", "tsv",
             "tex", "bib", "log", "mdc", "vue", "jsx", "tsx":
            return .text
        default:
            // Any other extension opens as plain text in the code editor.
            return .text
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
    /// Readium Locator JSON or Foliate location JSON for ebook progress.
    var ebookLocatorJSON: String?
    var updatedAt: Date

    init(pageIndex: Int = 0,
         pageOffsetY: CGFloat? = nil,
         pageOffsetX: CGFloat? = nil,
         anchorX: CGFloat? = nil,
         anchorY: CGFloat? = nil,
         scaleFactor: CGFloat? = nil,
         ebookLocatorJSON: String? = nil,
         updatedAt: Date = Date()) {
        self.pageIndex = pageIndex
        self.pageOffsetY = pageOffsetY
        self.pageOffsetX = pageOffsetX
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.scaleFactor = scaleFactor
        self.ebookLocatorJSON = ebookLocatorJSON
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
