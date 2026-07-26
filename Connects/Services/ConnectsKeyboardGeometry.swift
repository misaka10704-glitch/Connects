import UIKit

/// Shared iPad keyboard classification for composer lift + note sheet.
/// Distinguishes docked (bottom-spanning) vs floating/mini undocked keyboards.
enum ConnectsKeyboardGeometry {
    enum Kind: Equatable {
        case hidden
        /// Undocked / floating mini keyboard — may sit mid-screen and not span full width.
        case floatingMini
        /// Docked to the bottom edge (portrait full, or landscape half-height docked).
        case docked
    }

    struct Snapshot: Equatable {
        let kind: Kind
        /// Keyboard frame in the target view's coordinates (zero when hidden).
        let frameInView: CGRect
        /// Vertical overlap with the view's bottom (0 when hidden / non-overlapping float).
        let bottomOverlap: CGFloat
    }

    /// Classify a keyboard end-frame from `keyboardWillChangeFrame` (screen coordinates).
    static func resolve(screenFrame: CGRect, in view: UIView) -> Snapshot {
        let converted = view.convert(screenFrame, from: nil)
        let intersection = view.bounds.intersection(converted)
        let overlapH = intersection.isNull ? 0 : intersection.height
        if overlapH < 16 || screenFrame.isEmpty || screenFrame.height < 1 {
            return Snapshot(kind: .hidden, frameInView: .zero, bottomOverlap: 0)
        }

        let widthRatio = intersection.width / max(view.bounds.width, 1)
        // Docked keyboards sit flush (or nearly) with the view bottom and span most of the width.
        let nearBottom = converted.maxY >= view.bounds.maxY - 12
            || abs(converted.maxY - view.bounds.maxY) < 28
        let spansWidth = widthRatio >= 0.82

        if spansWidth && nearBottom {
            return Snapshot(kind: .docked, frameInView: converted, bottomOverlap: overlapH)
        }
        return Snapshot(kind: .floatingMini, frameInView: converted, bottomOverlap: overlapH)
    }

    /// How far the composer should lift above the safe-area / view bottom.
    /// - Docked: full bottom overlap (minus safe-area if the constraint is vs safeArea).
    /// - Floating mini: only lift when the keyboard covers the bottom composer band; otherwise 0.
    static func composerLift(
        snapshot: Snapshot,
        in view: UIView,
        safeAreaAlreadyInAnchor: Bool
    ) -> CGFloat {
        switch snapshot.kind {
        case .hidden:
            return 0
        case .docked:
            let safePad = safeAreaAlreadyInAnchor ? view.safeAreaInsets.bottom : 0
            return max(0, snapshot.bottomOverlap - safePad)
        case .floatingMini:
            let bandH: CGFloat = 140
            let band = CGRect(
                x: view.bounds.minX,
                y: view.bounds.maxY - bandH,
                width: view.bounds.width,
                height: bandH
            )
            let hit = band.intersection(snapshot.frameInView)
            guard !hit.isNull, hit.height > 12 else { return 0 }
            // Pin composer just above the floating keyboard.
            return max(0, view.bounds.maxY - snapshot.frameInView.minY)
        }
    }

    /// Center-Y constant (relative to view.midY) so a card of `cardHeight` sits above the keyboard.
    static func noteCardCenterYConstant(
        snapshot: Snapshot,
        in view: UIView,
        cardHeight: CGFloat,
        restingConstant: CGFloat = -24
    ) -> CGFloat {
        let h = max(cardHeight, 160)
        switch snapshot.kind {
        case .hidden:
            return restingConstant
        case .docked:
            let kbTop = view.bounds.maxY - snapshot.bottomOverlap
            let targetCenterY = kbTop - 14 - h * 0.5
            let minCenter = view.safeAreaInsets.top + 12 + h * 0.5
            let clamped = min(max(targetCenterY, minCenter), view.bounds.midY + restingConstant)
            return clamped - view.bounds.midY
        case .floatingMini:
            let kb = snapshot.frameInView
            let cardRect = CGRect(
                x: (view.bounds.width - 340) * 0.5,
                y: view.bounds.midY + restingConstant - h * 0.5,
                width: 340,
                height: h
            )
            // Only nudge if the floating keyboard would cover the resting card.
            guard kb.intersects(cardRect.insetBy(dx: -8, dy: -8)) else {
                return restingConstant
            }
            let targetCenterY = kb.minY - 12 - h * 0.5
            let minCenter = view.safeAreaInsets.top + 12 + h * 0.5
            let clamped = max(targetCenterY, minCenter)
            return clamped - view.bounds.midY
        }
    }
}
