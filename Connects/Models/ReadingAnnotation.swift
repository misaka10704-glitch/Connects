import Foundation
import CoreGraphics
import UIKit

/// Shared reading annotation (EPUB text highlight / PDF box).
struct ReadingAnnotation: Codable, Equatable, Identifiable {
    enum ColorKind: String, Codable, Equatable {
        case blue
        case green
    }

    let id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// EPUB only — light blue / light green.
    var color: ColorKind?
    /// EPUB: serialized Readium `Locator` JSON.
    var locatorJSON: String?
    /// EPUB: selected quote for mark injection / fallback label.
    var quote: String?
    /// EPUB: character offsets of the quote inside the resource's concatenated text.
    /// Anchors highlights without re-scanning the DOM per annotation.
    var textStart: Int?
    var textEnd: Int?
    /// PDF: zero-based page index.
    var pageIndex: Int?
    /// PDF: page-space bounds.
    var boundsX: CGFloat?
    var boundsY: CGFloat?
    var boundsW: CGFloat?
    var boundsH: CGFloat?

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            return String(quote.prefix(28))
        }
        if let pageIndex {
            return "第 \(pageIndex + 1) 页"
        }
        return "标注"
    }

    var pdfBounds: CGRect? {
        guard let boundsX, let boundsY, let boundsW, let boundsH else { return nil }
        return CGRect(x: boundsX, y: boundsY, width: boundsW, height: boundsH)
    }

    static func makeEPUB(
        title: String,
        color: ColorKind,
        locatorJSON: String,
        quote: String?
    ) -> ReadingAnnotation {
        let now = Date()
        return ReadingAnnotation(
            id: UUID().uuidString,
            title: title,
            createdAt: now,
            updatedAt: now,
            color: color,
            locatorJSON: locatorJSON,
            quote: quote,
            textStart: nil,
            textEnd: nil,
            pageIndex: nil,
            boundsX: nil,
            boundsY: nil,
            boundsW: nil,
            boundsH: nil
        )
    }

    static func makePDF(title: String, pageIndex: Int, bounds: CGRect) -> ReadingAnnotation {
        let now = Date()
        return ReadingAnnotation(
            id: UUID().uuidString,
            title: title,
            createdAt: now,
            updatedAt: now,
            color: nil,
            locatorJSON: nil,
            quote: nil,
            textStart: nil,
            textEnd: nil,
            pageIndex: pageIndex,
            boundsX: bounds.origin.x,
            boundsY: bounds.origin.y,
            boundsW: bounds.size.width,
            boundsH: bounds.size.height
        )
    }
}

enum ReadingAnnotationStyle {
    /// Soft wash for color chips / PDF — not used as EPUB text fill.
    static let epubBlue = (r: 0.35, g: 0.65, b: 1.0, a: 0.22)
    static let epubGreen = (r: 0.30, g: 0.82, b: 0.45, a: 0.22)
    static let pdfBoxRed = (r: 0.90, g: 0.18, b: 0.18, a: 0.95)

    static func epubTint(_ color: ReadingAnnotation.ColorKind) -> UIColor {
        switch color {
        case .blue:
            return UIColor(red: epubBlue.r, green: epubBlue.g, blue: epubBlue.b, alpha: epubBlue.a)
        case .green:
            return UIColor(red: epubGreen.r, green: epubGreen.g, blue: epubGreen.b, alpha: epubGreen.a)
        }
    }

    static func epubDot(_ color: ReadingAnnotation.ColorKind) -> UIColor {
        switch color {
        case .blue:
            return UIColor(red: 0.28, green: 0.55, blue: 0.95, alpha: 1)
        case .green:
            return UIColor(red: 0.22, green: 0.68, blue: 0.36, alpha: 1)
        }
    }
}
