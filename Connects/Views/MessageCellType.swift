import UIKit

/// Shared surface for user and assistant chat row cells.
protocol MessageCellType: UITableViewCell {
    var messageID: String { get }
    var cellDelegate: MessageCellDelegate? { get set }
    func configure(with message: ChatMessage, preferredHeight: CGFloat?, layoutWidth: CGFloat)
    func measuredContentHeight() -> CGFloat
    func setCachedImage(_ image: UIImage?)
    func refreshRenderDebugOverlay()
    var hasPendingDeferredNativeRender: Bool { get }
}

extension MessageCellType {
    var hasPendingDeferredNativeRender: Bool { false }
}

protocol MessageCellDelegate: AnyObject {
    func messageCell(_ cell: MessageCellType, didUpdateHeight height: CGFloat, for messageID: String)
    func messageCell(_ cell: MessageCellType, didFinishStableRender height: CGFloat, for messageID: String)
    func messageCellDidTapCopy(_ cell: MessageCellType, messageID: String)
    func messageCellDidTapRetry(_ cell: MessageCellType, messageID: String)
    func messageCellDidTapFork(_ cell: MessageCellType, messageID: String)
    func messageCellDidShiftVersion(_ cell: MessageCellType, messageID: String, delta: Int)
    /// When true, cell must not change webHeight / notify (prevents scroll flicker).
    func messageCellShouldFreezeHeight(_ cell: MessageCellType) -> Bool
    /// When true, skip uncached native layout and use a plain-text placeholder.
    func messageCellShouldDeferHeavyRender(_ cell: MessageCellType) -> Bool
    /// When true, plain scroll fallback may truncate very long bodies (drag only).
    func messageCellShouldTruncatePlainBody(_ cell: MessageCellType) -> Bool
    /// When false, defer action-row layoutIfNeeded until body paint (open critical path).
    func messageCellShouldLayoutActionChromeNow(_ cell: MessageCellType) -> Bool
    /// False while UITableView row height still clips the painted action chrome.
    func messageCellRowHasRoomForActionChrome(_ cell: MessageCellType) -> Bool
    /// First-open / uncommitted rows: keep action chrome hidden until body pixels exist.
    func messageCellShouldDeferActionChromeUntilBodyPaint(_ cell: MessageCellType) -> Bool
    /// Body (+ action chrome) finished painting — host may grow frozen row height.
    func messageCellDidPaintContent(_ cell: MessageCellType)
    /// When true, prepareForReuse keeps native paint (open height updates).
    func messageCellShouldPreserveOpenPaint(_ cell: MessageCellType) -> Bool
    /// Landscape study split: shift bubble right so action chrome clears the seam handle.
    func messageCellStudyContentLeadingGutter() -> CGFloat
    /// Thinking / search tag tapped — host presents a read-only viewer sheet.
    func messageCellDidTapChromeViewer(_ cell: MessageCellType,
                                       messageID: String,
                                       kind: MessageExpandableChromeKind)
}

enum MessageExpandableChromeKind {
    case thinking
    case search
}

extension MessageCellDelegate {
    func messageCellShouldFreezeHeight(_ cell: MessageCellType) -> Bool { false }
    func messageCellShouldDeferHeavyRender(_ cell: MessageCellType) -> Bool { false }
    func messageCellShouldTruncatePlainBody(_ cell: MessageCellType) -> Bool { false }
    func messageCellShouldLayoutActionChromeNow(_ cell: MessageCellType) -> Bool { true }
    func messageCellRowHasRoomForActionChrome(_ cell: MessageCellType) -> Bool { true }
    func messageCellShouldDeferActionChromeUntilBodyPaint(_ cell: MessageCellType) -> Bool { false }
    func messageCellDidPaintContent(_ cell: MessageCellType) {}
    func messageCellShouldPreserveOpenPaint(_ cell: MessageCellType) -> Bool { false }
    func messageCellStudyContentLeadingGutter() -> CGFloat { 0 }
    func messageCell(_ cell: MessageCellType, didFinishStableRender height: CGFloat, for messageID: String) {}
    func messageCellDidTapChromeViewer(_ cell: MessageCellType,
                                       messageID: String,
                                       kind: MessageExpandableChromeKind) {}
}

enum MessageCellReuseID {
    static let user = "UserMessageCell"
    static let assistant = "AssistantMessageCell"
}
