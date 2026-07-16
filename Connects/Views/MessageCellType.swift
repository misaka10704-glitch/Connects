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
    /// When true, bind a cached body snapshot before live native (fast reopen / scroll).
    func messageCellShouldPreferSnapshot(_ cell: MessageCellType) -> Bool
    /// When false, snapshot lookup stays in RAM only (open critical path).
    func messageCellShouldDecodeSnapshotFromDisk(_ cell: MessageCellType) -> Bool
}

extension MessageCellDelegate {
    func messageCellShouldFreezeHeight(_ cell: MessageCellType) -> Bool { false }
    func messageCellShouldDeferHeavyRender(_ cell: MessageCellType) -> Bool { false }
    func messageCellShouldPreferSnapshot(_ cell: MessageCellType) -> Bool { false }
    func messageCellShouldDecodeSnapshotFromDisk(_ cell: MessageCellType) -> Bool { true }
    func messageCell(_ cell: MessageCellType, didFinishStableRender height: CGFloat, for messageID: String) {}
}

enum MessageCellReuseID {
    static let user = "UserMessageCell"
    static let assistant = "AssistantMessageCell"
}
