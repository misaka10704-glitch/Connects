import UIKit

/// Paints `.backgroundColor` across the full line fragment width (Cursor-style Diff rows),
/// not only the glyph used-rect. Used by the Study code editor TextView.
final class DiffFullLineBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Skip system used-rect backgrounds — we redraw full-width below.
        guard let storage = textStorage else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }

        storage.enumerateAttribute(
            .backgroundColor,
            in: charRange,
            options: []
        ) { value, range, _ in
            guard let color = value as? UIColor, range.length > 0 else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if glyphRange.length == 0 { return }

            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, container, _, _ in
                let pad = container.lineFragmentPadding
                let width = max(0, container.size.width - pad * 2)
                guard width > 0.5, rect.height > 0.5 else { return }
                let fill = CGRect(
                    x: origin.x + pad,
                    y: origin.y + rect.origin.y,
                    width: width,
                    height: rect.height
                )
                color.setFill()
                UIBezierPath(rect: fill).fill()
            }
        }
    }
}
